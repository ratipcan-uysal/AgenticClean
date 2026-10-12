import CryptoKit
import Darwin
import Foundation

public enum CleanupProvider: String, Sendable, CaseIterable { case xcode, next, vite }
public struct CleanupExclusion: Sendable, Identifiable {
  public let path: String
  public let reason: String
  public var id: String { path }
}
/// Provider-verified generated output; never a whole project or dependency directory.
public struct CacheCleanupCandidate: Identifiable, Sendable {
  public let id: UUID
  public let path: String
  public let projectPath: String
  public let bytes: UInt64
  public let fileCount: Int
  public let blockedReason: String?
  public var provider: CleanupProvider = .xcode
  fileprivate var metadataFingerprint: String = ""
  public var projectRoot: String {
    provider == .xcode ? URL(fileURLWithPath: projectPath).deletingLastPathComponent().path : projectPath
  }
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
  public var exclusions: [CleanupExclusion] = []
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
  private var projectRoots: [URL] = []

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

  /// Metadata-only discovery; does not create a cleanup preview or measure outputs.
  public func discoveredXcodeProjects() throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    try Self.checkAncestors(root)
    let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    var paths = Set<String>()
    for entry in entries.sorted(by: { $0.path < $1.path }).prefix(200) {
      try Task.checkCancellation()
      if let project = try? verifyScope(entry.appendingPathComponent("Build")) {
        paths.insert(URL(fileURLWithPath: project).deletingLastPathComponent().path)
      }
    }
    return paths.sorted()
  }

  public func scan(projectPaths: [String] = []) throws -> CacheCleanupPlan {
    projectRoots = Array(Set(projectPaths)).sorted().map { URL(fileURLWithPath: $0) }
    currentPlan = nil
    let rootExists = FileManager.default.fileExists(atPath: root.path)
    if rootExists { try Self.checkAncestors(root) }
    let observed = try activity()
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var remaining = maximumEntries
    var candidates: [CacheCleanupCandidate] = []
    var skipped = 0
    var notices: [String] = []
    var exclusions: [CleanupExclusion] = []
    let children = rootExists ? try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) : []
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
        exclusions.append(.init(path: build.path, reason: error.localizedDescription))
      }
    }
    for project in projectRoots {
      for provider in [CleanupProvider.next, .vite] {
        try Task.checkCancellation()
        let output = project.appendingPathComponent(provider == .next ? ".next/cache" : "node_modules/.vite")
        guard FileManager.default.fileExists(atPath: output.path) else { continue }
        do {
          let proof = try verifyWeb(output, provider: provider)
          var budget = maximumEntries
          let measured = try measure(output, deadline: ProcessInfo.processInfo.systemUptime + 8, remaining: &budget)
          let blocked = Self.blockingReason(observed, project: project.path, build: output.path, web: true)
            ?? (currentDate().timeIntervalSince(measured.newestModification) < quietPeriod ? "This folder changed in the last minute. Wait and scan again." : nil)
          var candidate = CacheCleanupCandidate(id: UUID(), path: output.path, projectPath: project.path, bytes: measured.bytes, fileCount: measured.count, blockedReason: blocked, fingerprint: measured.digest, rootIdentity: measured.identity)
          candidate.provider = provider
          candidate.metadataFingerprint = proof
          candidates.append(candidate)
        } catch is CancellationError { throw CancellationError() } catch {
          skipped += 1
          exclusions.append(.init(path: output.path, reason: error.localizedDescription))
        }
      }
    }
    if skipped > 0 {
      notices.append(
        "Some folders were excluded because their identity, generated-file marker or full size could not be verified."
      )
    }
    var plan = CacheCleanupPlan(
      id: UUID(), createdAt: currentDate(), candidates: candidates, skippedCount: skipped, notices: notices)
    plan.exclusions = exclusions
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
        guard try verifyCandidate(candidate, build: build) else {
          throw CacheCleanupFailure.message("Project metadata changed. Scan again.")
        }
        if let blocked = Self.blockingReason(
          try activity(), project: candidate.projectPath, build: candidate.path, web: candidate.provider != .xcode)
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
          try activity(), project: candidate.projectPath, build: candidate.path, web: candidate.provider != .xcode)
        {
          throw CacheCleanupFailure.message(blocked)
        }
        // Activity inspection can be slow. Keep the final scope and identity checks adjacent
        // to the path-based Trash call, with no process scan between them and the move.
        guard try verifyCandidate(candidate, build: build) else {
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

  private func verifyCandidate(_ candidate: CacheCleanupCandidate, build: URL) throws -> Bool {
    if candidate.provider == .xcode { return try verifyScope(build) == candidate.projectPath }
    return try verifyWeb(build, provider: candidate.provider) == candidate.metadataFingerprint
  }

  private func verifyWeb(_ output: URL, provider: CleanupProvider) throws -> String {
    let project = output.deletingLastPathComponent().deletingLastPathComponent()
    guard projectRoots.contains(where: { $0.path == project.path }),
      output.path == project.appendingPathComponent(provider == .next ? ".next/cache" : "node_modules/.vite").path
    else { throw CacheCleanupFailure.message("Folder is outside the supported cleanup scope.") }
    try Self.checkAncestors(output)
    let info = try Self.metadata(output)
    guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
      throw CacheCleanupFailure.message("Project identity could not be verified.")
    }
    func readJSON(_ url: URL) throws -> (Data, [String: Any]) {
      try Self.checkAncestors(url.deletingLastPathComponent())
      let m = try Self.metadata(url)
      guard m.st_mode & S_IFMT == S_IFREG, m.st_uid == getuid(), m.st_size <= 1_048_576 else {
        throw CacheCleanupFailure.message("Project metadata is unsupported.")
      }
      let data = try Self.readMetadata(url, maximum: 1_048_576)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CacheCleanupFailure.message("Project metadata is unsupported.")
      }
      return (data, json)
    }
    let package = try readJSON(project.appendingPathComponent("package.json"))
    let dependency = provider == .next ? "next" : "vite"
    let dependencies = (package.1["dependencies"] as? [String: Any] ?? [:])
      .merging(package.1["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
    guard dependencies[dependency] is String else {
      throw CacheCleanupFailure.message("Supported tool dependency could not be verified.")
    }
    let marker = try readJSON(provider == .next
      ? project.appendingPathComponent(".next/build-manifest.json")
      : output.appendingPathComponent("deps/_metadata.json"))
    guard provider == .next ? marker.1["pages"] is [String: Any] : marker.1["optimized"] is [String: Any] else {
      throw CacheCleanupFailure.message("Generated output metadata could not be verified.")
    }
    var hash = SHA256()
    hash.update(data: package.0)
    hash.update(data: marker.0)
    let projectInfo = try Self.metadata(project)
    hash.update(data: Data("\(project.path)|\(projectInfo.st_dev)|\(projectInfo.st_ino)|\(projectInfo.st_birthtimespec.tv_sec)|\(projectInfo.st_birthtimespec.tv_nsec)".utf8))
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
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
    let data = try Self.readMetadata(metadataURL, maximum: 65_536)
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

  /// Open metadata without following a replaced final symlink, with a hard read limit.
  private static func readMetadata(_ url: URL, maximum: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw CacheCleanupFailure.message("Project metadata is unsupported.") }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == getuid(), before.st_size >= 0, before.st_size <= maximum else {
      throw CacheCleanupFailure.message("Project metadata is unsupported.")
    }
    var buffer = [UInt8](repeating: 0, count: maximum + 1)
    var total = 0
    while total < buffer.count {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress!.advanced(by: total), bytes.count - total)
      }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw CacheCleanupFailure.message("Project metadata is unsupported.") }
      if count == 0 { break }
      total += count
    }
    var after = stat()
    guard total <= maximum, fstat(descriptor, &after) == 0,
      CacheFileIdentity(before) == CacheFileIdentity(after), before.st_size == after.st_size,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
      throw CacheCleanupFailure.message("Project metadata changed. Scan again.")
    }
    return Data(buffer.prefix(total))
  }

  private static func buildSystemMarker(_ url: URL) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = getxattr(
      url.path, "com.apple.xcode.CreatedByBuildSystem", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
    return count > 0 && String(decoding: buffer.prefix(count), as: UTF8.self) == "true"
  }

  private static func blockingReason(_ observed: CacheActivity, project: String, build: String, web: Bool = false)
    -> String?
  {
    guard observed.complete else {
      return
        "Some of your processes could not be checked. Cleanup is unavailable until activity can be verified."
    }
    let projectFolder = web ? project : URL(fileURLWithPath: project).deletingLastPathComponent().path
    let buildTools: Set<String> = [
      "Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService", "swift-build", "swift-frontend",
      "clang", "clang++", "ld",
    ]
    for sample in observed.samples {
      if !web && (buildTools.contains(sample.name) || sample.path.contains("/Xcode.app/")) {
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
