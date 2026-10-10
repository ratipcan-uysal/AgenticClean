import Foundation

public struct ProcessScan: Sendable {
  public let samples: [ProcessSample]
  public let unreadableCount: Int
  public var unreadableUserCount: Int = 0
}
public enum MemorySource: String, Sendable { case footprint, rss, unavailable }
public struct MemoryReading: Sendable {
  public let footprint: UInt64?
  public let rss: UInt64?
  public var source: MemorySource {
    footprint != nil ? .footprint : rss != nil ? .rss : .unavailable
  }
  public var primary: UInt64? { footprint }
}
public enum SnapshotQuality: String, Sendable {
  case fresh, stale, partial, failed
  public var title: String {
    switch self {
    case .fresh: "Güncel"
    case .stale: "Eski ölçüm"
    case .partial: "Kısmi ölçüm"
    case .failed: "Tarama başarısız"
    }
  }
}
public struct Snapshot: Sendable {
  public let date: Date
  public let uptime: Double
  public let interval: Double?
  public let duration: Double
  public let system: SystemSample
  public let swap: UInt64?
  public let cpu: Double?
  public let paging: [Double]?
  public let rows: [ProcessRow]
  public let applications: [ResourceGroup]
  public let projects: [ResourceGroup]
  public let unreadableCount: Int
  public let quality: SnapshotQuality
  public let sustainedCPU: Bool
  public var unreadableUserCount: Int = 0
  public func state(now: Double, cadence: Double, paused: Bool) -> SnapshotQuality {
    if paused || now - uptime > max(cadence * 2, 10) { return .stale }
    return quality
  }
  public var macContext: MacResourceContext = .unavailable
  public var perCoreCPU: [Double?] = []
  public var pressureSource: MemoryPressureSource = .unavailable
  public var diagnosis: String {
    if system.pressure == 4 { return "Bellek baskısı kritik" }
    if system.pressure == 2 { return "Bellek baskısı yüksek" }
    if sustainedCPU { return "CPU sürekli yüksek" }
    if ![1, 2, 4].contains(system.pressure) || cpu == nil {
      return "Teşhis için yeterli ölçüm yok"
    }
    return "Bu ölçümler nedeni açıklamıyor"
  }
}
public struct SustainedCPU: Sendable {
  private var since: Double?
  public init() {}
  public mutating func observe(_ cpu: Double?, now: Double) -> Bool {
    guard let cpu, cpu >= 85 else {
      since = nil
      return false
    }
    if since == nil { since = now }
    return now - (since ?? now) >= 15
  }
  public mutating func reset() { since = nil }
}
public struct ProjectCache: Sendable {
  private struct Entry: Sendable {
    let cwd: String?
    let result: ProjectRoot?
    let at: Double
  }
  private var entries: [ProcessIdentity: Entry] = [:]
  public init() {}
  public mutating func roots(
    for samples: [ProcessSample], now: Double, resolve: (String) -> ProjectRoot?
  ) -> [String: ProjectRoot] {
    let live = Set(samples.map(\.id))
    entries = entries.filter { live.contains($0.key) }
    var results: [String: ProjectRoot] = [:]
    var resolved: [String: ProjectRoot] = [:]
    var visited = Set<String>()
    for sample in samples {
      if let old = entries[sample.id], old.cwd == sample.cwd, now - old.at < 60 {
        if let cwd = old.cwd, let result = old.result { results[cwd] = result }
        continue
      }
      guard let cwd = sample.cwd else {
        entries[sample.id] = Entry(cwd: nil, result: nil, at: now)
        continue
      }
      if visited.insert(cwd).inserted { resolved[cwd] = resolve(cwd) }
      entries[sample.id] = Entry(cwd: cwd, result: resolved[cwd], at: now)
      results[cwd] = resolved[cwd]
    }
    return results
  }
}
public actor MonitorEngine {
  private var previous: [ProcessIdentity: ProcessSample] = [:]
  private var previousSystem: SystemSample?
  private var previousTime: Double?
  private var hotCounts: [ProcessIdentity: Int] = [:]
  private var projectCache = ProjectCache()
  private var appCache: [String: (Double, ApplicationIdentity)] = [:]
  private var toolCache: [ProcessIdentity: (Double, Bool)] = [:]
  private var sustained = SustainedCPU()
  private var previousCores: CoreCPUSample?
  private let pressureEvents = MemoryPressureEvents()
  public init() {}
  public func resetBaseline() {
    previous = [:]
    previousSystem = nil
    previousTime = nil
    hotCounts = [:]
    sustained.reset()
    previousCores = nil
  }
  public func capture() throws -> Snapshot {
    assert(!Thread.isMainThread, "Filesystem and process inspection must run off the main thread")
    let start = ProcessInfo.processInfo.systemUptime
    let scan = try ProcessMonitor.scan()
    let ids = Set(scan.samples.map(\.id))
    toolCache = toolCache.filter { ids.contains($0.key) }
    let samples = scan.samples.map { sample in
      var value = sample
      if value.name == "java" {
        if let cached = toolCache[value.id], start - cached.0 < 60 {
          value.isMaestroMCP = cached.1
        } else {
          value.isMaestroMCP = ProcessMonitor.identifyMaestro(value)
          toolCache[value.id] = (start, value.isMaestroMCP)
        }
      }
      return value
    }
    var system = SystemSample.capture()
    let pressure = MemoryPressureReading.resolve(
      kernel: system.pressure, event: pressureEvents.latest)
    system.pressure = pressure.value ?? -1
    let cores = CoreCPUSample.capture()
    let measuredDate = Date()
    let now = system.measuredAt
    let elapsed = previousTime.map { now - $0 }
    let roots = projectCache.roots(for: samples, now: now) { cwd in
      ProjectResolver.root(for: cwd).map { ProjectRoot(path: $0.0, marked: $0.1) }
    }
    let paths = Set(samples.compactMap { ResourceSummary.appPath($0.path) })
    appCache = appCache.filter { paths.contains($0.key) }
    for path in paths where appCache[path] == nil || now - (appCache[path]?.0 ?? 0) >= 60 {
      appCache[path] = (now, ApplicationIdentity.read(path))
    }
    let rows = ProcessMonitor.rows(
      samples, previous: previous, elapsed: elapsed ?? 0, hotCounts: &hotCounts,
      projectRoots: roots, applications: appCache.mapValues(\.1))
    let cpu = system.cpuUsage(since: previousSystem)
    let paging = system.pagingRates(since: previousSystem)
    let swap = ProcessMonitor.swap()
    let partial =
      scan.unreadableCount > 0 || scan.unreadableUserCount > 0
      || rows.contains { $0.sample.footprint == nil || $0.cpu == nil }
      || system.memory == nil || system.ticks == nil || ![1, 2, 4].contains(system.pressure)
      || swap == nil || cpu == nil || paging == nil
    let result = Snapshot(
      date: measuredDate, uptime: now, interval: elapsed,
      duration: ProcessInfo.processInfo.systemUptime - start,
      system: system, swap: swap, cpu: cpu, paging: paging, rows: rows,
      applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
      unreadableCount: scan.unreadableCount, quality: partial ? .partial : .fresh,
      sustainedCPU: sustained.observe(cpu, now: now), unreadableUserCount: scan.unreadableUserCount,
      macContext: MacResourceContext.capture(),
      perCoreCPU: cores?.usage(since: previousCores) ?? [],
      pressureSource: pressure.source)
    previous = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
    previousSystem = system
    previousTime = now
    previousCores = cores
    return result
  }
}
public struct HistoryPoint: Identifiable, Sendable {
  public let id: UUID
  public let date: Date
  public let segment: Int
  public let cpu: Double?
  public let pressure: Double?
  public let swapIn: Double?
  public let swapOut: Double?
}
public struct HistoryBuffer: Sendable {
  public private(set) var points: [HistoryPoint] = []
  private var segment = 0
  public init() {}
  public mutating func gap(at date: Date = Date()) {
    segment += 1
    append(
      HistoryPoint(
        id: UUID(), date: date, segment: segment, cpu: nil, pressure: nil, swapIn: nil, swapOut: nil
      ))
  }
  public mutating func record(_ snapshot: Snapshot) {
    if snapshot.cpu == nil || snapshot.paging == nil
      || ![1, 2, 4].contains(snapshot.system.pressure)
    {
      segment += 1
    }
    append(
      HistoryPoint(
        id: UUID(), date: snapshot.date, segment: segment, cpu: snapshot.cpu,
        pressure: [1, 2, 4].contains(snapshot.system.pressure)
          ? Double(snapshot.system.pressure) : nil,
        swapIn: snapshot.paging?.first, swapOut: snapshot.paging?[1]))
  }
  public mutating func append(_ point: HistoryPoint) {
    points.append(point)
    points.removeAll { $0.date < point.date.addingTimeInterval(-1800) }
    if points.count > 1800 { points.removeFirst(points.count - 1800) }
  }
}
public enum ProcessPresence: Sendable { case sameIdentity, differentIdentity, absent, unreadable }
public enum StopState: Equatable, Sendable {
  case requested, closed, stillRunning, unverified, modelUnloaded, modelStillLoaded
  case failed(String)
  public var title: String {
    switch self {
    case .requested: "Kapanma istendi"
    case .closed: "Kapandı"
    case .modelUnloaded: "Model bellekten çıkarıldı"
    case .modelStillLoaded: "Model hâlâ bellekte"
    case .stillRunning: "Hâlâ çalışıyor · 15 saniyede kapanmadı"
    case .unverified: "Kapanma doğrulanamadı"
    case .failed(let message): "İşlem başarısız: " + message
    }
  }
  public static func resolve(_ presence: ProcessPresence, elapsed: Double) -> StopState {
    switch presence {
    case .absent, .differentIdentity: .closed
    case .sameIdentity: elapsed >= 15 ? .stillRunning : .requested
    case .unreadable: elapsed >= 15 ? .unverified : .requested
    }
  }
}
public struct OperationEvent: Identifiable, Sendable {
  public let id: UUID
  public let process: ProcessIdentity?
  public let name: String
  public let date: Date
  public var state: StopState
  public let simulatorID: String?
  public let projectBatchID: UUID?
}
public enum MonitorActions {
  @concurrent public static func stop(_ sample: ProcessSample) async throws {
    try ProcessMonitor.stop(sample)
  }
  @concurrent public static func presence(_ identity: ProcessIdentity) async -> ProcessPresence {
    ProcessMonitor.presence(identity)
  }
}
public struct SamplingSchedule: Equatable, Sendable {
  public var interval: Int
  public var paused: Bool
  public var epoch: UInt64
  public init(interval: Int = 5, paused: Bool = false, epoch: UInt64 = 0) {
    self.interval = interval
    self.paused = paused
    self.epoch = epoch
  }
  public mutating func configure(interval: Int, paused: Bool) -> Bool {
    guard self.interval != interval || self.paused != paused else { return false }
    self.interval = interval
    self.paused = paused
    epoch &+= 1
    return true
  }
  public mutating func wake() { epoch &+= 1 }
}

/// Observed intervals only: never bridge pauses, missing readings, or sampling segments.
public struct PressureTimeline: Sendable {
  public struct Interval: Sendable {
    public let start: Date
    public let end: Date
    public let level: Int
  }
  public let intervals: [Interval]
  public let currentDuration: TimeInterval?
  public let hasMissingReadings: Bool

  public init(points: [HistoryPoint]) {
    var result: [Interval] = []
    for (previous, next) in zip(points, points.dropFirst()) {
      guard previous.segment == next.segment, next.date > previous.date,
        let level = previous.pressure, [1, 2, 4].contains(level),
        let nextLevel = next.pressure, [1, 2, 4].contains(nextLevel)
      else { continue }
      result.append(Interval(start: previous.date, end: next.date, level: Int(level)))
    }
    intervals = result
    // The sampler inserts a reset marker before its first reading. That is startup,
    // not an interruption in an already observed history.
    let observed = points.drop { point in
      guard let pressure = point.pressure else { return true }
      return ![1, 2, 4].contains(pressure)
    }
    hasMissingReadings = observed.contains { point in
      guard let pressure = point.pressure else { return true }
      return ![1, 2, 4].contains(pressure)
    } || zip(observed, observed.dropFirst()).contains { previous, next in
      previous.segment != next.segment || next.date <= previous.date
    }
    guard let last = points.last, let level = last.pressure, [1, 2, 4].contains(level) else {
      currentDuration = nil
      return
    }
    var start = last.date
    for interval in result.reversed() {
      guard interval.end == start, interval.level == Int(level) else { break }
      start = interval.start
    }
    currentDuration = last.date.timeIntervalSince(start)
  }
}
