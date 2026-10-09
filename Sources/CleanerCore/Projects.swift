import Foundation

public struct ProjectHint: Sendable {
  public let path: String
  public let sourcePID: Int32
  public let inherited: Bool
  public let hasProjectMarker: Bool
  public var name: String { String(path.split(separator: "/").last ?? "") }
  public var label: String {
    (hasProjectMarker ? "Proje: " : "Klasör: ") + name + (inherited ? " · üst süreçten" : "")
  }
  public var evidence: String {
    let source =
      inherited
      ? "Üst süreç PID \(sourcePID) çalışma klasöründen çıkarıldı; bu sürece ait kesin proje bilgisi değildir."
      : "Sürecin doğrudan çalışma klasöründen bulundu."
    return source
      + (hasProjectMarker
        ? " Proje işaretçisi bulundu."
        : " Proje işaretçisi bulunamadı; yalnızca klasör adı gösteriliyor.")
      + " Sohbet kimliği bilinmiyor."
  }
}
public struct ProjectAttribution: Sendable {
  public enum Evidence: String, Sendable { case directDirectory, ancestorDirectory, unknown }
  public let evidence: Evidence
  public let path: String?
  public let sourcePID: Int32?
  public init(hint: ProjectHint?) {
    path = hint?.path
    sourcePID = hint?.sourcePID
    evidence = hint.map { $0.inherited ? .ancestorDirectory : .directDirectory } ?? .unknown
  }
}
public enum ProjectResolver {
  public static func usable(_ path: String, home: String = NSHomeDirectory()) -> Bool {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    guard path.hasPrefix("/"),
      ![
        "/", "/Users", home, home + "/Documents", home + "/Desktop", home + "/Downloads", "/tmp",
        "/private/tmp", "/Volumes",
      ].contains(path)
    else { return false }
    let worktreePrefix = home + "/.codex/worktrees/"
    if path.hasPrefix(worktreePrefix) {
      return path.dropFirst(worktreePrefix.count).split(separator: "/").count >= 2
    }
    let excluded = [
      "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/dev",
      "/opt/homebrew", home + "/Library", home + "/.codex", home + "/.claude", home + "/.maestro",
      home + "/.cache", home + "/.npm", home + "/.nvm", home + "/.local",
    ]
    return !path.contains(".app/") && !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
  }
  public static func root(for cwd: String, isUsable: (String) -> Bool = { usable($0) }) -> (
    String, Bool
  )? {
    guard isUsable(cwd) else { return nil }
    let directory = URL(fileURLWithPath: cwd).standardizedFileURL
    var current = directory
    var manifestRoot: URL?
    for _ in 0..<24 {
      guard isUsable(current.path) else { break }
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
        return (current.path, true)
      }
      if manifestRoot == nil
        && ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod"].contains(
          where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }
        )
      {
        manifestRoot = current
      }
      let parent = current.deletingLastPathComponent()
      if parent == current { break }
      current = parent
    }
    if let manifestRoot { return (manifestRoot.path, true) }
    return (directory.path, false)
  }
  public static func hint(
    for sample: ProcessSample, samples: [Int32: ProcessSample], roots: [String: ProjectRoot]
  ) -> ProjectHint? {
    var candidate: ProcessSample? = sample
    var visited = Set<Int32>()
    for _ in 0..<32 {
      guard let current = candidate, visited.insert(current.id.pid).inserted else { break }
      if let cwd = current.cwd, let root = roots[cwd] {
        return ProjectHint(
          path: root.path, sourcePID: current.id.pid, inherited: current.id != sample.id,
          hasProjectMarker: root.marked)
      }
      // Shared desktop processes are not evidence of a child's project.
      if ResourceSummary.appPath(current.path) != nil && current.name != "claude"
        && current.name != "codex"
      {
        break
      }
      candidate = samples[current.parent]
    }
    return nil
  }
}
public struct ProjectRoot: Sendable {
  public let path: String
  public let marked: Bool
  public init(path: String, marked: Bool) {
    self.path = path
    self.marked = marked
  }
}
