import Foundation

/// Explanations never grant stop permission or infer a framework from its runtime.
public enum WorkRole: Sendable {
  case localAI, simulator, agent, testBridge, build, runtime, sharedHelper, unknown
  public static func identify(_ row: ProcessRow) -> Self {
    let sample = row.sample
    if sample.isMaestroMCP { return .testBridge }
    if LocalAIProvider.recognize(executablePath: sample.path) != nil { return .localAI }
    if sample.agentSession != nil { return .agent }
    if ["Simulator", "emulator", "qemu-system-aarch64"].contains(sample.name) { return .simulator }
    if ["xcodebuild", "swift-build", "swift-frontend", "clang", "cargo", "gradle"].contains(sample.name) { return .build }
    if sample.isDevelopment { return .runtime }
    if sample.path.contains(".app/"), sample.name.contains("Helper") || sample.name.contains("Renderer") || sample.name.contains("Service") { return .sharedHelper }
    return .unknown
  }
}

public struct PressureEpisode: Identifiable, Sendable {
  public enum Kind: String, Sendable { case memory, cpu }
  public var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)" }
  public let kind: Kind
  public let start: Date
  public let end: Date
  public let peak: Double
  public let applications: [GroupUsage]
  public let evidenceDate: Date?
  public static func collect(points: [HistoryPoint], frames: [GroupHistoryFrame]) -> [Self] {
    var episodes: [Self] = []
    for kind in [Kind.memory, .cpu] {
      var run: [HistoryPoint] = []
      func finish() {
        guard let first = run.first, let last = run.last else { return }
        if kind == .cpu && last.date.timeIntervalSince(first.date) < 15 { run = []; return }
        let peakPoint = run.max { a, b in
          (kind == .cpu ? a.cpu ?? 0 : a.pressure ?? 0) < (kind == .cpu ? b.cpu ?? 0 : b.pressure ?? 0)
        }!
        // Only actual frames inside the observed episode, never current usage as past evidence.
        let frame = frames.filter { $0.date >= first.date && $0.date <= last.date && !$0.applications.isEmpty }
          .min { abs($0.date.timeIntervalSince(peakPoint.date)) < abs($1.date.timeIntervalSince(peakPoint.date)) }
        let ranked = frame?.applications.sorted {
          kind == .cpu ? ($0.cpu ?? -1) > ($1.cpu ?? -1) : ($0.memory ?? 0) > ($1.memory ?? 0)
        } ?? []
        episodes.append(Self(kind: kind, start: first.date, end: last.date,
          peak: kind == .cpu ? peakPoint.cpu ?? 0 : peakPoint.pressure ?? 0,
          applications: Array(ranked.prefix(3)), evidenceDate: frame?.date))
        run = []
      }
      for point in points {
        if let prior = run.last, prior.segment != point.segment { finish() }
        let matches = kind == .cpu ? (point.cpu ?? -1) >= 85 : [2.0, 4.0].contains(point.pressure ?? -1)
        if matches { run.append(point) } else { finish() }
      }
      finish()
    }
    return episodes.sorted { $0.end > $1.end }
  }
}
