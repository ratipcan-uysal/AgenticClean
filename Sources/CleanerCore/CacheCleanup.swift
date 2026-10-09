import CryptoKit
import Darwin
import Foundation

/// A deliberately narrow allowlist: only Xcode's generated Build directory, never all DerivedData.
public struct CacheCleanupCandidate: Identifiable, Sendable {
  public let id: UUID
  public let path: String
  public let projectPath: String
  public let bytes: UInt64
  public let fileCount: Int
  public let blockedReason: String?
  public var name: String {
    URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent
  }
  fileprivate let fingerprint: String
  fileprivate let rootIdentity: CacheFileIdentity
}

public struct CacheCleanupPlan: Sendable {
  public let id: UUID
  public let createdAt: Date
  public let candidates: [CacheCleanupCandidate]
  public let skippedCount: Int
  public let notices: [String]
}

public struct CacheCleanupResult: Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let path: String
  public let bytes: UInt64
  public let trashPath: String?
  public let error: String?
  public var moved: Bool { trashPath != nil }
}

public protocol CacheTrashService: Sendable {
  /// Must move this exact item to Trash; permanently deleting it is never an allowed fallback.
  func moveToTrash(_ url: URL) throws -> URL
}

public struct SystemCacheTrashService: CacheTrashService {
  public init() {}
  public func moveToTrash(_ url: URL) throws -> URL {
    var destination: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
    guard let destination else {
      throw CacheCleanupFailure.message("Trash destination was not returned.")
    }
    return destination as URL
  }
}

struct CacheFileIdentity: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let createdSeconds: Int
  let createdNanos: Int
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
    createdSeconds = info.st_birthtimespec.tv_sec
    createdNanos = info.st_birthtimespec.tv_nsec
  }
}

enum CacheCleanupFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

struct CacheActivity: Sendable {
  let samples: [ProcessSample]
  let complete: Bool
}

/// All directory walking and mutation stays off the main actor. Plans are held in this actor,
/// so callers cannot forge a path or reuse an already submitted preview.
public actor CacheCleanupEngine {
  private let root: URL
  private let trash: any CacheTrashService
  private let activity: @Sendable () throws -> CacheActivity
  private let maximumEntries: Int
  private let quietPeriod: TimeInterval
  private let currentDate: @Sendable () -> Date
  private var currentPlan: CacheCleanupPlan?

  public init() {
    root =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    trash = SystemCacheTrashService()
    activity = Self.nativeActivity
    maximumEntries = 100_000
    quietPeriod = 60
    currentDate = { Date() }
  }

  init(
    root: URL, trash: any CacheTrashService, maximumEntries: Int = 100_000,
    quietPeriod: TimeInterval = 0, currentDate: @escaping @Sendable () -> Date = { Date() },
    activity: @escaping @Sendable () throws -> CacheActivity = {
      .init(samples: [], complete: true)
    }
  ) {
    self.root = root
    self.trash = trash
    self.maximumEntries = maximumEntries
    self.quietPeriod = quietPeriod
    self.currentDate = currentDate
    self.activity = activity
  }

  public func scan() throws -> CacheCleanupPlan {
    currentPlan = nil
    let now = currentDate()
    guard FileManager.default.fileExists(atPath: root.path) else {
      let plan = CacheCleanupPlan(
        id: UUID(), createdAt: now, candidates: [], skippedCount: 0, notices: [])
      currentPlan = plan
      return plan
    }
    try Self.checkAncestors(root)
    let observed = try activity()
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var remaining = maximumEntries
    var candidates: [CacheCleanupCandidate] = []
    var skipped = 0
    var notices: [String] = []
    let children = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    if children.count > 200 {
      notices.append("Only the first 200 DerivedData folders were checked.")
    }
    for folder in children.sorted(by: { $0.path < $1.path }).prefix(200) {
      try Task.checkCancellation()
      if ProcessInfo.processInfo.systemUptime > deadline || remaining <= 0 {
        notices.append("The scan limit was reached. Unmeasured folders were excluded.")
        break
      }
      let build = folder.appendingPathComponent("Build")
      guard FileManager.default.fileExists(atPath: build.path) else { continue }
      do {
        let project = try verifyScope(build)
        let measured = try measure(build, deadline: deadline, remaining: &remaining)
        let blocked =
          Self.blockingReason(observed, project: project, build: build.path)
          ?? (currentDate().timeIntervalSince(measured.newestModification) < quietPeriod
            ? "This folder changed in the last minute. Wait and scan again." : nil)
        candidates.append(
          CacheCleanupCandidate(
            id: UUID(), path: build.path, projectPath: project, bytes: measured.bytes,
            fileCount: measured.count, blockedReason: blocked, fingerprint: measured.digest,
            rootIdentity: measured.identity))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        skipped += 1
      }
    }
    if skipped > 0 {
      notices.append(
        "Some folders were excluded because their identity, generated-file marker or full size could not be verified."
      )
    }
    let plan = CacheCleanupPlan(
      id: UUID(), createdAt: now, candidates: candidates, skippedCount: skipped, notices: notices)
    currentPlan = plan
    return plan
  }

  public func moveToTrash(planID: UUID, selectedIDs: Set<UUID>) throws -> [CacheCleanupResult] {
    guard let plan = currentPlan, plan.id == planID,
      currentDate().timeIntervalSince(plan.createdAt) >= 0,
      currentDate().timeIntervalSince(plan.createdAt) <= 120
    else { throw CacheCleanupFailure.message("Preview expired. Scan again before confirming.") }
    guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(plan.candidates.map(\.id))) else {
      throw CacheCleanupFailure.message("Select items from the current preview.")
    }
    // Consume the plan before any side effect. Retry always starts with a fresh preview.
    currentPlan = nil
    var results: [CacheCleanupResult] = []
    for candidate in plan.candidates where selectedIDs.contains(candidate.id) {
      do {
        try Task.checkCancellation()
        guard candidate.blockedReason == nil else {
          throw CacheCleanupFailure.message(
            candidate.blockedReason ?? "This item cannot be cleaned.")
        }
        let build = URL(fileURLWithPath: candidate.path)
        guard try verifyScope(build) == candidate.projectPath else {
          throw CacheCleanupFailure.message("Project metadata changed. Scan again.")
        }
        if let blocked = Self.blockingReason(
          try activity(), project: candidate.projectPath, build: candidate.path)
        {
          throw CacheCleanupFailure.message(blocked)
        }
        var remaining = maximumEntries
        let measured = try measure(
          build, deadline: ProcessInfo.processInfo.systemUptime + 8, remaining: &remaining)
        guard measured.identity == candidate.rootIdentity, measured.digest == candidate.fingerprint
        else {
          throw CacheCleanupFailure.message(
            "Folder contents changed after preview. Nothing was moved; scan again.")
        }
        if let blocked = Self.blockingReason(
          try activity(), project: candidate.projectPath, build: candidate.path)
        {
          throw CacheCleanupFailure.message(blocked)
        }
        // Activity inspection can be slow. Keep the final scope and identity checks adjacent
        // to the path-based Trash call, with no process scan between them and the move.
        guard try verifyScope(build) == candidate.projectPath else {
          throw CacheCleanupFailure.message("Project metadata changed. Scan again.")
        }
        guard CacheFileIdentity(try Self.metadata(build)) == candidate.rootIdentity else {
          throw CacheCleanupFailure.message("Folder identity changed. Scan again.")
        }
        let destination = try trash.moveToTrash(build)
        results.append(
          .init(
            id: candidate.id, name: candidate.name, path: candidate.path,
            bytes: candidate.bytes, trashPath: destination.path, error: nil))
      } catch {
        results.append(
          .init(
            id: candidate.id, name: candidate.name, path: candidate.path,
            bytes: candidate.bytes, trashPath: nil, error: error.localizedDescription))
      }
    }
    return results
  }

  private func verifyScope(_ build: URL) throws -> String {
    guard build.lastPathComponent == "Build",
      build.deletingLastPathComponent().deletingLastPathComponent().path == root.path
    else { throw CacheCleanupFailure.message("Folder is outside the supported cleanup scope.") }
    try Self.checkAncestors(build)
    let info = try Self.metadata(build)
    guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
      Self.buildSystemMarker(build)
    else {
      throw CacheCleanupFailure.message(
        "Xcode's generated build-folder marker could not be verified.")
    }
    let metadataURL = build.deletingLastPathComponent().appendingPathComponent("info.plist")
    let metadataInfo = try Self.metadata(metadataURL)
    guard metadataInfo.st_mode & S_IFMT == S_IFREG, metadataInfo.st_size <= 65_536 else {
      throw CacheCleanupFailure.message("Project metadata is unsupported.")
    }
    let data = try Data(contentsOf: metadataURL)
    guard
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let project = plist["WorkspacePath"] as? String,
      project.hasPrefix("/"),
      ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: project).pathExtension)
    else { throw CacheCleanupFailure.message("Project identity could not be verified.") }
    return URL(fileURLWithPath: project).standardizedFileURL.path
  }

  private struct Measurement {
    let bytes: UInt64
    let count: Int
    let digest: String
    let identity: CacheFileIdentity
    let newestModification: Date
  }

  private func measure(_ build: URL, deadline: Double, remaining: inout Int) throws -> Measurement {
    let base = try Self.metadata(build)
    var digest = SHA256()
    var bytes: UInt64 = 0
    var count = 0
    var newest = Date(timeIntervalSince1970: Double(base.st_mtimespec.tv_sec))
    var pending = [build]
    while let directory = pending.popLast() {
      try Task.checkCancellation()
      try Self.checkAncestors(directory)
      guard remaining > 0, ProcessInfo.processInfo.systemUptime <= deadline else {
        throw CacheCleanupFailure.message("Folder exceeds the bounded scan limit.")
      }
      let entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).sorted { $0.path < $1.path }
      guard entries.count <= remaining else {
        throw CacheCleanupFailure.message("Folder exceeds the bounded scan limit.")
      }
      for item in entries {
        remaining -= 1
        count += 1
        guard ProcessInfo.processInfo.systemUptime <= deadline else {
          throw CacheCleanupFailure.message("Folder exceeds the bounded scan limit.")
        }
        let info = try Self.metadata(item)
        guard info.st_uid == getuid(), info.st_dev == base.st_dev else {
          throw CacheCleanupFailure.message(
            "Folder includes another owner's files or a mounted volume.")
        }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else {
          throw CacheCleanupFailure.message("Folder includes an unsupported file type.")
        }
        // Hash metadata without reading file contents or following descendant symlinks.
        let record =
          "\(item.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_mode)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)\n"
        digest.update(data: Data(record.utf8))
        newest = max(newest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
        if kind == S_IFDIR {
          // Reject symlink ancestors again before descending.
          try Self.checkAncestors(item)
          pending.append(item)
        } else if kind == S_IFREG {
          let (nextBytes, overflow) = bytes.addingReportingOverflow(UInt64(max(0, info.st_size)))
          guard !overflow else {
            throw CacheCleanupFailure.message("Folder size cannot be represented safely.")
          }
          bytes = nextBytes
        }
      }
    }
    let after = try Self.metadata(build)
    guard CacheFileIdentity(base) == CacheFileIdentity(after),
      base.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      base.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else { throw CacheCleanupFailure.message("Folder changed while being measured.") }
    return Measurement(
      bytes: bytes, count: count,
      digest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
      identity: CacheFileIdentity(base), newestModification: newest)
  }

  private static func checkAncestors(_ url: URL) throws {
    // Foundation's standardizedFileURL can rewrite existing /private/tmp paths to
    // the /tmp symlink alias. Inspect the supplied absolute path without following
    // or introducing aliases; dot components are not accepted in cleanup scopes.
    guard url.isFileURL, url.path.hasPrefix("/"),
      !url.pathComponents.contains("."), !url.pathComponents.contains("..")
    else { throw CacheCleanupFailure.message("Folder is outside the supported cleanup scope.") }
    var path = url
    while path.path != "/" {
      let info = try metadata(path)
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw CacheCleanupFailure.message(
          "Symbolic links and non-directory ancestors are excluded.")
      }
      path.deleteLastPathComponent()
    }
  }

  private static func metadata(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw CacheCleanupFailure.message("Folder could not be read: \(url.lastPathComponent).")
    }
    return info
  }

  private static func buildSystemMarker(_ url: URL) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = getxattr(
      url.path, "com.apple.xcode.CreatedByBuildSystem", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
    return count > 0 && String(decoding: buffer.prefix(count), as: UTF8.self) == "true"
  }

  private static func blockingReason(_ observed: CacheActivity, project: String, build: String)
    -> String?
  {
    guard observed.complete else {
      return
        "Some of your processes could not be checked. Cleanup is unavailable until activity can be verified."
    }
    let projectFolder = URL(fileURLWithPath: project).deletingLastPathComponent().path
    let buildTools: Set<String> = [
      "Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService", "swift-build", "swift-frontend",
      "clang", "clang++", "ld",
    ]
    for sample in observed.samples {
      if buildTools.contains(sample.name) || sample.path.contains("/Xcode.app/") {
        return "Quit Xcode and finish running builds before cleaning build outputs."
      }
      if sample.path == build || sample.path.hasPrefix(build + "/") {
        return "A program is running from this build folder. Close it and scan again."
      }
      if let cwd = sample.cwd,
        cwd == projectFolder || cwd.hasPrefix(projectFolder + "/") || cwd == build
          || cwd.hasPrefix(build + "/")
      {
        return "This project has an active process or terminal. Close it and scan again."
      }
    }
    return nil
  }

  private static func nativeActivity() throws -> CacheActivity {
    // The common scanner re-enumerates current-user PIDs after reading identities, so
    // unreadable/replaced identities and processes born during the scan fail closed.
    let scan = try ProcessMonitor.scan()
    let samples = scan.samples.filter { $0.uid == getuid() }
    let unknownWorkingDirectory = samples.contains { sample in
      (sample.cwd == nil || sample.cwd?.isEmpty == true)
        && (sample.isDevelopment || sample.agentSession != nil
          || ["cursor", "swift", "zsh", "bash"].contains(sample.name))
    }
    return CacheActivity(
      samples: samples,
      complete: scan.unreadableUserCount == 0 && !unknownWorkingDirectory)
  }
}
