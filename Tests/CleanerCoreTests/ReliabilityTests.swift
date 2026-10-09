import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func fixture(
  _ pid: Int32 = 900000, seconds: UInt64 = 1, cwd: String? = nil,
  path: String = "/opt/homebrew/bin/node", footprint: UInt64? = 100
) -> ProcessSample {
  var sample = ProcessSample(
    id: .init(pid: pid, seconds: seconds), parent: 1, uid: getuid(), path: path, memory: 50)
  sample.cwd = cwd
  sample.footprint = footprint
  return sample
}
private func snapshot(
  _ samples: [ProcessSample] = [fixture()], cpu: Double? = 10, quality: SnapshotQuality = .fresh,
  uptime: Double = ProcessInfo.processInfo.systemUptime
) -> Snapshot {
  var system = SystemSample(ticks: [1, 2, 3, 4], memory: [])
  system.pressure = 1
  var hot: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows(samples, previous: [:], elapsed: 0, hotCounts: &hot)
  return Snapshot(
    date: Date(), uptime: uptime, interval: 5, duration: 0.01, system: system, swap: 0, cpu: cpu,
    paging: [0, 0, 0, 0], rows: rows,
    applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: quality, sustainedCPU: false)
}
private actor FakeSource: SnapshotSource {
  var value: Snapshot
  var fail = false
  private(set) var resets = 0
  private(set) var captures = 0
  init(_ value: Snapshot = snapshot()) { self.value = value }
  func capture() async throws -> Snapshot {
    captures += 1
    if fail { throw MonitorError.message("fixture scan failure") }
    return value
  }
  func resetBaseline() { resets += 1 }
  func set(_ value: Snapshot) { self.value = value }
  func failNext(_ flag: Bool) { fail = flag }
}
@MainActor private func dashboard(_ source: FakeSource) -> Dashboard {
  Dashboard(source: source, defaults: UserDefaults(suiteName: "CleanerTests." + UUID().uuidString)!)
}
@Test @MainActor func hiddenSelectionCannotActAndSortRetainsIdentity() async {
  let source = FakeSource()
  let model = dashboard(source)
  await model.refresh()
  let row = model.presentation.rows[0]
  model.selection = .process(row.id)
  #expect(model.canStop(row))
  model.request.sort = .age
  #expect(model.selection == .process(row.id))
  model.request.query = "no-such-process"
  #expect(model.selection == nil)
  #expect(!model.canStop(row))
  await model.stop(row)  // Even a stale confirmation callback must not act.
  #expect(model.events.isEmpty)
  model.stopMonitoring()
}
@Test @MainActor func stopFailureSurvivesSuccessfulScanAndDismissesExplicitly() async {
  let model = dashboard(FakeSource())
  await model.refresh()
  let row = model.presentation.rows[0]
  model.selection = .process(row.id)
  await model.stop(row)  // PID 900000 is deliberately nonexistent; no signal is sent.
  #expect(model.events.count == 1)
  guard case .failed = model.events.first?.state else {
    Issue.record("Expected stop failure")
    return
  }
  await model.refresh()
  #expect(model.scanError == nil)
  #expect(model.events.count == 1)
  model.dismissEvent(model.events[0].id)
  #expect(model.events.isEmpty)
}
@Test @MainActor func failedScanDoesNotReplaceOrZeroSnapshot() async {
  let source = FakeSource()
  let model = dashboard(source)
  await model.refresh()
  let date = model.snapshot?.date
  await source.failNext(true)
  await model.refresh()
  #expect(model.quality == .failed)
  #expect(model.snapshot?.date == date)
  #expect(model.snapshot?.cpu == 10)
  #expect(model.history.points.last?.cpu == nil)
}
@Test @MainActor func disappearedSelectionDoesNotJumpToReusedPID() async {
  let source = FakeSource()
  let model = dashboard(source)
  await model.refresh()
  let row = model.presentation.rows[0]
  model.selection = .process(row.id)
  await source.set(snapshot([fixture(seconds: 2)]))
  await model.refresh()
  #expect(model.selection == .process(row.id))
  #expect(model.selectedRow?.id == row.id)
  #expect(!model.canStop(row))
}
@Test @MainActor func cadencePauseResumeAndWakeRestartSamplingImmediately() async throws {
  let source = FakeSource()
  let model = dashboard(source)
  model.start()
  try await Task.sleep(for: .milliseconds(1100))
  let before = await source.captures
  #expect(before >= 2)
  model.interval = 300
  try await Task.sleep(for: .milliseconds(100))
  #expect(await source.captures > before)
  model.paused = true
  let paused = await source.captures
  try await Task.sleep(for: .milliseconds(100))
  #expect(await source.captures == paused)
  model.paused = false
  try await Task.sleep(for: .milliseconds(100))
  let resumed = await source.resets
  #expect(resumed >= 3)
  model.sleep()
  model.wake()
  try await Task.sleep(for: .milliseconds(100))
  #expect(await source.resets > resumed)
  model.stopMonitoring()
}
@Test @MainActor func preferencesPersistButSelectionDoesNot() async {
  let defaults = UserDefaults(suiteName: "CleanerTests." + UUID().uuidString)!
  let model = Dashboard(source: FakeSource(), defaults: defaults)
  model.interval = 30
  model.request.mode = .projects
  model.request.sort = .age
  model.selection = .process(fixture().id)
  let restored = Dashboard(source: FakeSource(), defaults: defaults)
  #expect(
    restored.interval == 30 && restored.request.mode == .projects && restored.request.sort == .age)
  #expect(restored.selection == nil)
}
@Test func stopResolutionDoesNotConfuseUnreadableWithClosed() {
  #expect(StopState.resolve(.unreadable, elapsed: 1) == .requested)
  #expect(StopState.resolve(.unreadable, elapsed: 15) == .unverified)
  #expect(StopState.resolve(.sameIdentity, elapsed: 15) == .stillRunning)
  #expect(StopState.resolve(.absent, elapsed: 0) == .closed)
  #expect(StopState.resolve(.differentIdentity, elapsed: 0) == .closed)
}
@Test func snapshotAgesAndPausedMeasurementsAreNotFresh() {
  let value = snapshot(uptime: 100)
  #expect(value.state(now: 101, cadence: 5, paused: false) == .fresh)
  #expect(value.state(now: 111, cadence: 5, paused: false) == .stale)
  #expect(value.state(now: 101, cadence: 5, paused: true) == .stale)
  #expect(
    snapshot(quality: .partial, uptime: 100).state(now: 101, cadence: 5, paused: false) == .partial)
}
@Test func groupMemoryNeverMixesRSSAndFootprint() {
  let value = snapshot([fixture(900001, footprint: 500), fixture(900002, footprint: nil)])
  #expect(value.applications[0].memory == 500)
  #expect(value.applications[0].missingMemoryCount == 1)
  let unavailable = snapshot([fixture(footprint: nil)])
  #expect(unavailable.applications[0].memory == nil)
  #expect(MemoryReading(footprint: nil, rss: nil).source == .unavailable)
}
@Test func countersResetWithoutInventingCPU() {
  let old = SystemSample(ticks: [100, 200, 0, 300], memory: nil)
  let new = SystemSample(ticks: [0, 0, 0, 0], memory: nil)
  #expect(new.cpuUsage(since: old) == nil)
  var first = fixture()
  var next = first
  var counts: [ProcessIdentity: Int] = [:]
  first.cpuTime = 100
  next.cpuTime = 1
  #expect(
    ProcessMonitor.rows([next], previous: [first.id: first], elapsed: 5, hotCounts: &counts)[0].cpu
      == nil)
  #expect(
    ProcessMonitor.rows([first], previous: [first.id: first], elapsed: 0, hotCounts: &counts)[0].cpu
      == nil)
}
@Test func sustainedCPUNeedsContinuousFifteenSecondsAndResetsOnGap() {
  var state = SustainedCPU()
  let results = [
    state.observe(85, now: 0), state.observe(90, now: 14), state.observe(85, now: 15),
    state.observe(nil, now: 16), state.observe(99, now: 17), state.observe(84.9, now: 33),
  ]
  #expect(results == [false, false, true, false, false, false])
  state.reset()
  let afterReset = state.observe(100, now: 100)
  #expect(!afterReset)
}
@Test func historyExpiresAndGapsBreakLines() {
  var history = HistoryBuffer()
  history.record(snapshot())
  let first = history.points.last!.segment
  history.gap()
  history.record(snapshot())
  #expect(history.points.last!.segment != first)
  history.record(snapshot(cpu: nil))
  #expect(history.points.last?.cpu == nil)
  let future = Date().addingTimeInterval(1801)
  history.append(
    HistoryPoint(id: UUID(), date: future, segment: 10, cpu: 0, pressure: 1, swapIn: 0, swapOut: 0))
  #expect(history.points.count == 1)
}
@Test func metadataCacheExpiresAndInvalidatesDirectoryAndPIDIdentity() {
  var cache = ProjectCache()
  var calls = 0
  var sample = fixture(cwd: "/Users/test/a")
  func resolve(_ path: String) -> ProjectRoot? {
    calls += 1
    return ProjectRoot(path: path, marked: true)
  }
  _ = cache.roots(for: [sample], now: 0, resolve: resolve)
  _ = cache.roots(for: [sample], now: 59, resolve: resolve)
  #expect(calls == 1)
  _ = cache.roots(for: [sample], now: 60, resolve: resolve)
  #expect(calls == 2)
  sample.cwd = "/Users/test/b"
  _ = cache.roots(for: [sample], now: 61, resolve: resolve)
  #expect(calls == 3)
  sample.id = .init(pid: sample.id.pid, seconds: 2)
  _ = cache.roots(for: [sample], now: 62, resolve: resolve)
  #expect(calls == 4)
}
@Test func claudeBundleFamiliesMergeWithoutSwallowingIndependentApps() {
  let desktop = "/Applications/Claude.app"
  let cli = "/Users/test/Library/Application Support/Claude/claude.app"
  let other = "/Applications/Editor.app"
  let desktopID = ApplicationIdentity(bundleID: "com.anthropic.claudefordesktop", path: desktop)
  let cliID = ApplicationIdentity(bundleID: "com.anthropic.claude-code", path: cli)
  #expect(desktopID.familyID == cliID.familyID)
  #expect(desktopID.component != cliID.component)
  let first = fixture(900001, path: desktop + "/Contents/MacOS/Claude")
  var second = fixture(900002, path: cli + "/Contents/MacOS/claude")
  second.parent = first.id.pid
  var third = fixture(900003, path: other + "/Contents/MacOS/Editor")
  third.parent = first.id.pid
  var counts: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows(
    [first, second, third], previous: [:], elapsed: 0, hotCounts: &counts,
    applications: [
      desktop: desktopID, cli: cliID,
      other: ApplicationIdentity(bundleID: "test.editor", path: other),
    ])
  #expect(ResourceSummary.groups(rows).count == 2)
  #expect(rows[2].applicationName == "Editor")
}
@Test func sameBasenameProjectsStaySeparateAndUnknownIsNotDistributed() async {
  var a = ProcessRow(sample: fixture(900001), cpu: 10, reasons: [], owner: "—")
  var b = ProcessRow(sample: fixture(900002), cpu: 20, reasons: [], owner: "—")
  a.project = ProjectHint(
    path: "/Users/a/project", sourcePID: a.id.pid, inherited: false, hasProjectMarker: true)
  b.project = ProjectHint(
    path: "/Users/b/project", sourcePID: b.id.pid, inherited: true, hasProjectMarker: true)
  let unknown = ProcessRow(sample: fixture(900003), cpu: 30, reasons: [], owner: "—")
  let groups = ResourceSummary.projectGroups([a, b, unknown])
  #expect(groups.count == 3)
  #expect(groups.first { $0.id == "project:unknown" }?.cpu == 30)
  #expect(
    a.attribution.evidence == .directDirectory && b.attribution.evidence == .ancestorDirectory)
  #expect(unknown.attribution.evidence == .unknown)
}
@Test func gitWorktreeMarkerIsAFileAndKeepsWorktreePath() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cleaner-worktree-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: base.appendingPathComponent("child", isDirectory: true), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  try Data("gitdir: /not-read/by/cleaner".utf8).write(to: base.appendingPathComponent(".git"))
  // root resolution accepts an injected safe temporary root for this fixture.
  let root = ProjectResolver.root(
    for: base.appendingPathComponent("child").path, isUsable: { $0.hasPrefix(base.path) })
  #expect(root?.0 == base.path && root?.1 == true)
  #expect(ProjectResolver.usable("/Users/test/.codex/worktrees/a/repo", home: "/Users/test"))
}
@Test func fiveHundredRowsPrepareAndSortWithoutFilesystemWork() async {
  var samples: [ProcessSample] = []
  for index in 0..<500 {
    samples.append(
      fixture(Int32(900000 + index), seconds: UInt64(index + 1), footprint: UInt64(500 - index)))
  }
  var request = PresentationRequest()
  request.sort = .age
  let result = await Presentation.prepare(snapshot(samples), request: request)
  #expect(result.rows.count == 500)
  #expect(result.rows.first?.id.seconds == 1 && result.rows.last?.id.seconds == 500)
  request.sort = .memory
  let memory = await Presentation.prepare(snapshot(samples), request: request)
  #expect(memory.rows.first?.sample.footprint == 500)
}

@Test func directoryNameAloneDoesNotAttributeAProcessToClaude() {
  let parent = fixture(900001, path: "/Users/test/ClaudeTools/python")
  var child = fixture(900002)
  child.parent = parent.id.pid
  var counts: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows([parent, child], previous: [:], elapsed: 0, hotCounts: &counts)
  #expect(rows[1].owner == "python")
}
@Test func displayedAgeBelongsToMeasurementAndDoesNotGrowAfterExit() {
  var sample = fixture(seconds: 10)
  sample.observedAt = Date(timeIntervalSince1970: 100)
  let row = ProcessRow(sample: sample, cpu: 0, reasons: [], owner: "—")
  #expect(row.sample.age == 90)
  #expect(ResourceSummary.groups([row])[0].age == 90)
}

@Test @MainActor func sameNameSimulatorResultsKeepDeviceIdentity() {
  let model = dashboard(FakeSource())
  let first = model.record(process: nil, name: "iPhone", state: .requested, simulatorID: "device-a")
  _ = model.record(process: nil, name: "iPhone", state: .requested, simulatorID: "device-b")
  model.setEvent(first, state: .closed)
  #expect(model.events.first { $0.simulatorID == "device-a" }?.state == .closed)
  #expect(model.events.first { $0.simulatorID == "device-b" }?.state == .requested)
}

@Test func hierarchyKeepsApplicationProjectBoundariesAndPartialTotals() async {
  var first = ProcessRow(
    sample: fixture(910001, footprint: 300), cpu: 30, reasons: [], owner: "Codex")
  first.applicationKey = "codex"
  first.applicationName = "Codex"
  first.project = ProjectHint(
    path: "/Users/a/mobile", sourcePID: first.id.pid, inherited: false, hasProjectMarker: true)
  var second = ProcessRow(
    sample: fixture(910002, footprint: 200), cpu: 20, reasons: [], owner: "Codex")
  second.applicationKey = "codex"
  second.applicationName = "Codex"
  second.project = ProjectHint(
    path: "/Users/b/mobile", sourcePID: second.id.pid, inherited: true, hasProjectMarker: true)
  var shared = ProcessRow(
    sample: fixture(910003, footprint: nil), cpu: nil, reasons: [], owner: "Codex")
  shared.applicationKey = "codex"
  shared.applicationName = "Codex"
  var other = first
  other.applicationKey = "claude"
  other.applicationName = "Claude"
  // The same project can contain work from different applications without merging their totals.
  let rows = [first, second, shared, other]
  let baseline = snapshot()
  let value = Snapshot(
    date: baseline.date, uptime: baseline.uptime, interval: 5, duration: 0,
    system: baseline.system, swap: 0, cpu: 10, paging: [0, 0, 0, 0], rows: rows,
    applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: .partial, sustainedCPU: false)
  let result = await Presentation.prepare(value, request: PresentationRequest())
  let app = result.applications.first!
  #expect(app.id == "codex")
  #expect(app.group.memory == 500 && app.group.missingMemoryCount == 1)
  #expect(app.projects.map(\.id) == ["/Users/a/mobile", "/Users/b/mobile", "project:unknown"])
  #expect(app.projects.last?.memory == nil)
  #expect(
    app.projectKey(app.projects[0])
      != result.applications[1].projectKey(result.applications[1].projects[0]))
  var request = PresentationRequest()
  request.query = "/Users/b/mobile"
  let filtered = await Presentation.prepare(value, request: request)
  #expect(filtered.applications.count == 1)
  #expect(filtered.applications[0].projects.count == 1)
  #expect(filtered.applications[0].group.memory == 200)
  #expect(filtered.rows.map(\.id) == [second.id])
}

@Test @MainActor func nestedProjectSelectionSurvivesRefreshWithoutEnablingStop() async {
  let model = dashboard(FakeSource())
  await model.refresh()
  let app = model.presentation.applications[0]
  let key = app.projectKey(app.projects[0])
  model.selection = .group(key)
  await model.refresh()
  #expect(model.selection == .group(key))
  #expect(model.selectedRow == nil)
  #expect(!model.canStop(model.presentation.rows[0]))
  model.request.query = "no-match"
  #expect(model.selection == nil)
  model.stopMonitoring()
}
