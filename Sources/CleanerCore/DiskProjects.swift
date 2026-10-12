import Darwin
import Foundation

public enum DiskCategory: String, CaseIterable, Sendable { case source, dependencies, outputs, other }
public enum DiskScanState: String, Sendable { case complete, partial, inaccessible, cancelled }
public struct DiskProject: Identifiable, Sendable, Hashable {
  public let path: String
  public var id: String { path }
  public var name: String { URL(fileURLWithPath: path).lastPathComponent }
  public init(path: String) { self.path = path }
}
public struct DiskArtifact: Identifiable, Sendable {
  public let path: String
  public let category: DiskCategory
  public let bytes: UInt64
  public var id: String { path }
}
public struct DiskScanResult: Identifiable, Sendable {
  public let project: DiskProject
  public let rootIdentity: String?
  public let date: Date
  public let state: DiskScanState
  public let bytes: UInt64?
  public let artifacts: [DiskArtifact]
  public let notice: String?
  public var id: String { project.id }
  public init(project: DiskProject, rootIdentity: String?, date: Date, state: DiskScanState, bytes: UInt64?, artifacts: [DiskArtifact], notice: String?) {
    self.project = project; self.rootIdentity = rootIdentity; self.date = date
    self.state = state; self.bytes = bytes; self.artifacts = artifacts; self.notice = notice
  }
  public func bytes(in category: DiskCategory) -> UInt64 {
    artifacts.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
  }
}

/// Logical bytes only. No content reads, link following, or cleanup eligibility decisions.
public actor DiskProjectScanner {
  private let maximumEntries: Int
  private let seconds: Double
  public init(maximumEntries: Int = 100_000, seconds: Double = 10) {
    self.maximumEntries = maximumEntries
    self.seconds = seconds
  }
  public func scan(_ project: DiskProject, excluding roots: [String]) -> DiskScanResult {
    let date = Date()
    var totals: [DiskCategory: UInt64] = [:]
    var state = DiskScanState.complete
    var notice: String?
    var identity: String?
    var count = 0
    var totalBytes: UInt64 = 0
    let root = URL(fileURLWithPath: project.path)
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    func metadata(_ url: URL) throws -> stat {
      var info = stat()
      guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoPermission) }
      return info
    }
    func result(_ measured: Bool) -> DiskScanResult {
      let artifacts = DiskCategory.allCases.map {
        DiskArtifact(path: project.path + "/" + $0.rawValue, category: $0, bytes: totals[$0] ?? 0)
      }
      return DiskScanResult(project: project, rootIdentity: identity, date: date, state: state,
        bytes: measured ? totalBytes : nil, artifacts: artifacts, notice: notice)
    }
    do {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let privateRoots = [".codex", ".claude", ".cursor", "Library/Application Support/Codex", "Library/Application Support/Claude", "Library/Application Support/Cursor", "Library/Developer/CoreSimulator"]
        .map { home.appendingPathComponent($0).path }
      guard !privateRoots.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }),
        ![".codex", ".claude", ".cursor", "CoreSimulator"].contains(root.lastPathComponent) else {
        state = .inaccessible; notice = "excluded"; return result(false)
      }
      var ancestor = root
      while ancestor.path != "/" {
        guard try metadata(ancestor).st_mode & S_IFMT == S_IFDIR else {
          throw CocoaError(.fileReadUnsupportedScheme)
        }
        ancestor.deleteLastPathComponent()
      }
      let base = try metadata(root)
      identity = "\(base.st_dev):\(base.st_ino):\(base.st_birthtimespec.tv_sec):\(base.st_birthtimespec.tv_nsec)"
      let excluded = Set(roots.filter { $0 != root.path && $0.hasPrefix(root.path + "/") })
      let privateNames: Set<String> = [".codex", ".claude", ".cursor", "CoreSimulator"]
      let dependencyNames: Set<String> = ["node_modules", "vendor", ".venv", "venv", "Pods", "Carthage"]
      let outputNames: Set<String> = [".next", ".vite", ".build", "dist", "build", "target", "DerivedData"]
      let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cpp", "js", "jsx", "ts", "tsx", "vue", "svelte", "py", "rs", "go", "java", "kt", "html", "css", "scss", "json", "yaml", "yml", "toml", "md"]
      var pending: [(URL, DiskCategory?)] = [(root, nil)]
      while let (directory, inherited) = pending.popLast() {
        if Task.isCancelled { state = .cancelled; notice = "cancelled"; return result(true) }
        if count >= maximumEntries || ProcessInfo.processInfo.systemUptime > deadline {
          state = .partial; notice = "limit"; return result(true)
        }
        // Recheck every ancestor immediately before descending; never traverse a replaced link.
        var check = directory
        while check.path != "/" {
          guard try metadata(check).st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
          check.deleteLastPathComponent()
        }
        let directoryInfo = try metadata(directory)
        guard directoryInfo.st_dev == base.st_dev else { state = .partial; notice = "volume"; continue }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard let handle = fdopendir(descriptor) else { close(descriptor); throw CocoaError(.fileReadNoPermission) }
        defer { closedir(handle) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, CacheFileIdentity(opened) == CacheFileIdentity(directoryInfo) else {
          throw CocoaError(.fileReadNoPermission)
        }
        while true {
          errno = 0
          guard let entry = readdir(handle) else {
            if errno != 0 { state = .partial; notice = "access" }
            break
          }
          let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
          }
          if name == "." || name == ".." { continue }
          let item = directory.appendingPathComponent(name)
          if Task.isCancelled { state = .cancelled; notice = "cancelled"; return result(true) }
          if count >= maximumEntries || ProcessInfo.processInfo.systemUptime > deadline {
            state = .partial; notice = "limit"; return result(true)
          }
          count += 1
          if excluded.contains(item.path) { continue }
          if privateNames.contains(item.lastPathComponent) || privateRoots.contains(item.path) { state = .partial; notice = "excluded"; continue }
          let info: stat
          do { info = try metadata(item) } catch { state = .partial; notice = "access"; continue }
          guard info.st_dev == base.st_dev else { state = .partial; notice = "volume"; continue }
          let kind = info.st_mode & S_IFMT
          if kind == S_IFLNK { state = .partial; notice = "links"; continue }
          let category: DiskCategory = item.lastPathComponent == ".git" ? .other
            : dependencyNames.contains(item.lastPathComponent) ? .dependencies
            : outputNames.contains(item.lastPathComponent) ? .outputs
            : inherited ?? (sourceExtensions.contains(item.pathExtension.lowercased()) ? .source : .other)
          if kind == S_IFDIR {
            pending.append((item, category == .other && inherited == nil && item.lastPathComponent != ".git" ? nil : category))
          } else if kind == S_IFREG {
            let (next, overflow) = (totals[category] ?? 0).addingReportingOverflow(UInt64(max(0, info.st_size)))
            let (total, totalOverflow) = totalBytes.addingReportingOverflow(UInt64(max(0, info.st_size)))
            if overflow || totalOverflow { state = .partial; notice = "overflow"; return result(true) }
            totals[category] = next; totalBytes = total
          } else { state = .partial; notice = "unsupported" }
        }
      }
      let end = try metadata(root)
      if CacheFileIdentity(base) != CacheFileIdentity(end) { state = .partial; notice = "changed" }
      return result(true)
    } catch {
      state = identity == nil || count == 0 ? .inaccessible : .partial
      notice = "access"
      return result(state != .inaccessible)
    }
  }
}
