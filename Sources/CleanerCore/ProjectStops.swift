import Darwin
import Foundation

public struct ProjectStopEntry: Identifiable, Sendable {
  public let row: ProcessRow
  public let exclusion: String?
  public var id: ProcessIdentity { row.id }
}
public struct ProjectStopPlan: Identifiable, Sendable {
  public let id = UUID()
  public let groupKey: String
  public let application: String
  public let applicationKey: String
  public let path: String
  public let name: String
  public let request: PresentationRequest
  public let entries: [ProjectStopEntry]
  public var targets: [ProcessRow] { entries.filter { $0.exclusion == nil }.map(\.row) }
  public var agentSessionCount: Int { targets.filter { $0.sample.agentSession != nil }.count }
  public var excludedCount: Int { entries.filter { $0.exclusion != nil }.count }
  fileprivate static func sharedAIProtection(_ sample: ProcessSample) -> String? {
    LocalAIProvider.recognize(executablePath: sample.path) == nil
      ? nil
      : "Yerel AI servisi başka projelerle paylaşılabilir; ayrı inceleyip durdur."
  }
  fileprivate static let sharedAIParentProtection =
    "Bu AI oturumu paylaşılan bir yerel AI servisinin üst süreci; ayrı inceleyip durdur."
  public static func exclusion(for row: ProcessRow, pending: Bool) -> String? {
    if let protection = sharedAIProtection(row.sample) { return protection }
    if let protection = row.sample.projectStopProtection { return protection }
    if !row.sample.isDevelopment && row.sample.agentSession == nil {
      return "Bu süreç türü için kapatma desteklenmiyor"
    }
    if row.attribution.evidence != .directDirectory || row.sample.cwd == nil {
      return "Proje bağlantısı doğrudan doğrulanamadı; toplu işleme alınmadı"
    }
    if row.sample.agentSession != nil && row.project?.hasProjectMarker != true {
      return "AI oturumu için doğrulanmış proje kökü gerekli; yalnızca klasör bilgisi yeterli değil"
    }
    if pending { return "Bu süreç için zaten kapanma bekleniyor" }
    return nil
  }
  /// Must receive the full readable snapshot, not the search-filtered project rows.
  /// A session may own jobs outside its current working directory.
  public static func sessionExclusion(for row: ProcessRow, among rows: [ProcessRow]) -> String? {
    guard row.sample.agentSession != nil else { return nil }
    let children = Dictionary(grouping: rows, by: { $0.sample.parent })
    var queue = [row.id.pid]
    var visited: Set<Int32> = [row.id.pid]
    var index = 0
    while index < queue.count {
      let parent = queue[index]
      index += 1
      for child in children[parent] ?? [] {
        guard visited.insert(child.id.pid).inserted else { continue }
        if sharedAIProtection(child.sample) != nil { return sharedAIParentProtection }
        guard child.project?.path == row.project?.path,
          child.attribution.evidence == .directDirectory
        else {
          return
            "Bu AI oturumunun başka projeye bağlı veya proje bağlantısı bilinmeyen alt süreci var"
        }
        queue.append(child.id.pid)
      }
    }
    return nil
  }

}
public protocol ProjectProcessActions: Sendable {
  func stop(_ sample: ProcessSample) async throws
  func stop(_ sample: ProcessSample, projectPath: String) async throws
  func presence(_ identity: ProcessIdentity) async -> ProcessPresence
}
extension ProjectProcessActions {
  public func stop(_ sample: ProcessSample, projectPath: String) async throws {
    try await stop(sample)
  }
}
public struct NativeProjectProcessActions: ProjectProcessActions {
  public init() {}
  @concurrent public func stop(_ sample: ProcessSample) async throws {
    guard sample.agentSession == nil else {
      throw MonitorError.message("AI oturumunu durdurmak için onaylanan proje kökü gerekli.")
    }
    try performStop(sample, projectPath: nil)
  }
  @concurrent public func stop(_ sample: ProcessSample, projectPath: String) async throws {
    try performStop(sample, projectPath: projectPath)
  }
  private func performStop(_ sample: ProcessSample, projectPath: String?) throws {
    // A process may have moved to another directory since the confirmation was prepared.
    guard let expected = sample.cwd, ProcessMonitor.workingDirectory(sample) == expected else {
      throw MonitorError.message("Çalışma klasörü değişti veya okunamadı; durdurulmadı.")
    }
    if let projectPath, ProjectResolver.root(for: expected)?.0 != projectPath {
      throw MonitorError.message("Proje kökü onaydan sonra değişti veya okunamadı; durdurulmadı.")
    }
    if sample.agentSession != nil {
      try Self.validateSession(sample, scan: ProcessMonitor.scan(), projectPath: projectPath)
    }
    // Repeat the identity and cwd check after potentially expensive project inspection.
    guard ProcessMonitor.workingDirectory(sample) == sample.cwd else {
      throw MonitorError.message("Çalışma klasörü değişti veya okunamadı; durdurulmadı.")
    }
    try Self.validateStop(sample, current: ProcessMonitor.read(sample.id.pid))
    guard kill(sample.id.pid, SIGTERM) == 0 else {
      throw MonitorError.message(String(cString: strerror(errno)))
    }
  }
  /// Recheck the entire live descendant tree immediately before an AI session signal.
  /// No filtered UI rows or cached project metadata are used for this authorization.
  public static func validateSession(
    _ expected: ProcessSample, scan: ProcessScan, projectPath: String? = nil,
    resolveRoot: (String) -> ProjectRoot? = {
      ProjectResolver.root(for: $0).map { ProjectRoot(path: $0.0, marked: $0.1) }
    }
  ) throws {
    guard expected.agentSession != nil else { return }
    guard scan.unreadableUserCount == 0 else {
      throw MonitorError.message(
        "Bazı kullanıcı süreçleri okunamadı; AI oturumunun tüm alt işleri doğrulanamadığı için durdurulmadı."
      )
    }
    let current = scan.samples.first { $0.id == expected.id }
    try validateStop(expected, current: current)
    guard let cwd = expected.cwd, current?.cwd == cwd,
      let project = resolveRoot(cwd), project.marked,
      projectPath == nil || project.path == projectPath
    else {
      throw MonitorError.message(
        "AI oturumunun proje kökü değişti veya doğrulanamadı; durdurulmadı.")
    }
    let children = Dictionary(grouping: scan.samples, by: \.parent)
    var queue = [expected.id.pid]
    var visited: Set<Int32> = [expected.id.pid]
    var index = 0
    var roots: [String: ProjectRoot] = [cwd: project]
    while index < queue.count {
      let parent = queue[index]
      index += 1
      for child in children[parent] ?? [] {
        guard visited.insert(child.id.pid).inserted else { continue }
        if ProjectStopPlan.sharedAIProtection(child) != nil {
          throw MonitorError.message(ProjectStopPlan.sharedAIParentProtection)
        }
        guard child.uid == expected.uid, let childCWD = child.cwd else {
          throw MonitorError.message(
            "AI oturumunun bir alt işinin çalışma klasörü veya kullanıcısı doğrulanamadı; durdurulmadı."
          )
        }
        let root = roots[childCWD] ?? resolveRoot(childCWD)
        guard let root, root.marked, root.path == project.path else {
          throw MonitorError.message(
            "AI oturumunun başka projeye bağlı veya projesi bilinmeyen alt işi var; durdurulmadı.")
        }
        roots[childCWD] = root
        queue.append(child.id.pid)
      }
    }
  }
  /// Project-only policy. Single-process Stop keeps the stricter session protection.
  public static func validateStop(_ expected: ProcessSample, current: ProcessSample?) throws {
    guard let current, current.id == expected.id, current.path == expected.path,
      current.uid == expected.uid, expected.cwd != nil
    else {
      throw MonitorError.message("Süreç kapanmış veya kimliği değişmiş; durdurulmadı.")
    }
    if let protection = ProjectStopPlan.sharedAIProtection(current) {
      throw MonitorError.message(protection)
    }
    guard current.projectStopProtection == nil,
      current.isDevelopment || current.agentSession != nil
    else {
      throw MonitorError.message(current.projectStopProtection ?? "Bu süreç türü desteklenmiyor.")
    }
  }
  public func presence(_ identity: ProcessIdentity) async -> ProcessPresence {
    await MonitorActions.presence(identity)
  }
}
