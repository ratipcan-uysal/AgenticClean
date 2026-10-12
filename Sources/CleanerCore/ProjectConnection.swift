import Foundation
import Darwin
import ProcessKit

/// Classification is explanatory only; it never grants project-stop authority.
public enum ProjectConnectionKind: Sendable {
  case direct, inherited, application, service, system, unknown
  public static func identify(_ row: ProcessRow) -> Self {
    if let project = row.project { return project.inherited ? .inherited : .direct }
    if isSystem(row.sample.path) { return .system }
    if LocalAIProvider.recognize(executablePath: row.sample.path) != nil { return .service }
    if ResourceSummary.appPath(row.sample.path) != nil { return .application }
    return .unknown
  }
  public static func isSystem(_ path: String) -> Bool {
    ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/Developer/"].contains(where: path.hasPrefix)
  }
}

public struct ProjectClue: Identifiable, Sendable {
  public enum Source: Sendable { case directory, ancestor, argument }
  public let path: String
  public let source: Source
  public let pid: Int32
  public let marked: Bool
  public var id: String { "\(pid):\(source):\(path)" }
}
public struct ProjectInvestigation: Sendable {
  public let clues: [ProjectClue]
  public let partial: Bool
  public var conflicting: Bool { Set(clues.map(\.path)).count > 1 }

  /// Resolve only existing, absolute paths. No shell expansion or guessed commands.
  public static func argumentRoot(_ path: String) -> (String, Bool)? {
    guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
    return ProjectResolver.root(for: directory.boolValue ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path)
  }

  @concurrent public static func inspect(_ expected: ProcessSample) async throws -> Self {
    guard expected.uid == getuid(), let first = ProcessMonitor.read(expected.id.pid),
      first.id == expected.id, first.path == expected.path else {
      throw MonitorError.message("Süreç kapanmış veya kimliği değişmiş. Listeyi yenile.")
    }
    let initialDirectory = ProcessMonitor.workingDirectory(first)
    var clues: [ProjectClue] = []
    var partial = false
    var current: ProcessSample? = first
    var visited = Set<Int32>()
    for _ in 0..<16 {
      try Task.checkCancellation()
      guard let sample = current, sample.uid == getuid(), visited.insert(sample.id.pid).inserted else { break }
      if sample.id != first.id && ResourceSummary.appPath(sample.path) != nil { break }
      let cwd = ProcessMonitor.workingDirectory(sample)
      if let cwd, let root = ProjectResolver.root(for: cwd) {
        clues.append(.init(path: root.0, source: sample.id == first.id ? .directory : .ancestor, pid: sample.id.pid, marked: root.1))
      } else if cwd == nil { partial = true }
      if sample.id == first.id && (sample.isDevelopment || sample.agentSession != nil) {
        var bytes = [CChar](repeating: 0, count: 32768)
        let count = bytes.withUnsafeMutableBufferPointer { cleaner_project_paths(sample.id.pid, $0.baseAddress, Int32($0.count)) }
        if count < 0 { partial = true }
        if count > 0 {
          let data = bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }
          for part in data.split(separator: 0) {
            if let path = String(bytes: part, encoding: .utf8), let root = argumentRoot(path) {
              clues.append(.init(path: root.0, source: .argument, pid: sample.id.pid, marked: root.1))
            }
          }
        }
      }
      guard ProcessMonitor.presence(sample.id) == .sameIdentity else {
        throw MonitorError.message("Süreç kapanmış veya kimliği değişmiş. Listeyi yenile.")
      }
      if ResourceSummary.appPath(sample.path) != nil { break }
      let parent = ProcessMonitor.read(sample.parent)
      if let parent, parent.id.seconds > sample.id.seconds { partial = true; break }
      current = parent
      if current == nil && sample.parent > 1 { partial = true }
    }
    if visited.count == 16 { partial = true }
    guard ProcessMonitor.presence(expected.id) == .sameIdentity,
      ProcessMonitor.workingDirectory(first) == initialDirectory else {
      throw MonitorError.message("Süreç kapanmış veya kimliği değişmiş. Listeyi yenile.")
    }
    var seen = Set<String>()
    return Self(clues: clues.filter { seen.insert($0.id).inserted }, partial: partial)
  }
}
