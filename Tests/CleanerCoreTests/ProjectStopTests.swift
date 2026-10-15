import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func projectRow(
  _ pid: Int32, app: String = "codex", path: String = "/work/project", inherited: Bool = false,
  executable: String = "/opt/homebrew/bin/node", seconds: UInt64 = 1, cwd: String? = nil,
  parent: Int32 = 1, uid: UInt32 = getuid()
) -> ProcessRow {
  var sample = ProcessSample(
    id: .init(pid: pid, seconds: seconds), parent: parent, uid: uid, path: executable)
  // Synthetic verified identity: no installed vendor application is needed for policy tests.
  if ["/Applications/Codex.app/Contents/Resources/", "/Applications/ChatGPT.app/Contents/Resources/"]
    .contains(where: executable.hasPrefix) {
    sample.managedHelperIdentity = ManagedHelperIdentity.candidate(for: executable)
  }
  sample.cwd = cwd ?? path
  var row = ProcessRow(
    sample: sample, cpu: 0, reasons: [], owner: app,
    project: ProjectHint(path: path, sourcePID: pid, inherited: inherited, hasProjectMarker: true))
  row.applicationKey = app
  row.applicationName = app
  return row
}
private func projectSnapshot(_ rows: [ProcessRow]) -> Snapshot {
  Snapshot(
    date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interval: 5, duration: 0,
    system: SystemSample(ticks: nil, memory: nil), swap: nil, cpu: nil, paging: nil, rows: rows,
    applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: .partial, sustainedCPU: false)
}
private actor ProjectSource: SnapshotSource {
  var rows: [ProcessRow]
  init(_ rows: [ProcessRow]) { self.rows = rows }
  func capture() -> Snapshot { projectSnapshot(rows) }
  func resetBaseline() {}
  func set(_ rows: [ProcessRow]) { self.rows = rows }
}
private actor FakeProjectActions: ProjectProcessActions {
  var calls: [ProcessIdentity] = []
  var helperCalls: [ProcessIdentity] = []
  let fail: Int32?
  init(fail: Int32? = nil) { self.fail = fail }
  func stop(_ sample: ProcessSample) throws {
    calls.append(sample.id)
    if sample.id.pid == fail { throw MonitorError.message("fixture failure") }
  }
  func stopManagedHelper(_ sample: ProcessSample, projectPath: String) {
    helperCalls.append(sample.id)
  }
  func presence(_ identity: ProcessIdentity) -> ProcessPresence {
    identity.pid == fail || (!calls.contains(identity) && !helperCalls.contains(identity))
      ? .sameIdentity : .absent
  }
}
@MainActor private func projectModel(_ source: ProjectSource, _ actions: FakeProjectActions)
  -> Dashboard
{
  Dashboard(
    source: source, defaults: UserDefaults(suiteName: "ProjectStopTests." + UUID().uuidString)!,
    projectActions: actions)
}
@MainActor private func selectedPlan(_ model: Dashboard) throws -> ProjectStopPlan {
  let app = try #require(model.presentation.applications.first { $0.id == "codex" })
  let project = try #require(app.projects.first { $0.id == "/work/project" })
  model.selection = .group(app.projectKey(project))
  return try #require(model.projectStopPlan(for: app.projectKey(project)))
}
@Test @MainActor func projectStopScopesApplicationFullPathAndDirectEvidence() async throws {
  let actions = FakeProjectActions()
  let source = ProjectSource([
    projectRow(900001), projectRow(900002, inherited: true),
    projectRow(900003, executable: "/Applications/Codex.app/Contents/node"),
    projectRow(900004, app: "claude"), projectRow(900005, path: "/other/project"),
  ])
  let model = projectModel(source, actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  #expect(plan.entries.count == 3 && plan.excludedCount == 2)
  try await model.stopProject(plan)
  #expect(await actions.calls.map(\.pid) == [900001])
  #expect(model.events.count == 1 && model.events[0].state == .closed)
  #expect(model.events[0].projectBatchID == plan.id)
  #expect(!model.canConfirmProjectStop(plan))
}

private let bundledNode = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node"
private let installedBundledNode = [
  bundledNode, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
].first { FileManager.default.isExecutableFile(atPath: $0) }

@Test @MainActor func projectStopNeverImplicitlyIncludesManagedHelpers() async throws {
  let actions = FakeProjectActions()
  let model = projectModel(ProjectSource([
    projectRow(900001), projectRow(900002, executable: bundledNode),
    projectRow(900003, executable: bundledNode),
  ]), actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  #expect(plan.targets.map(\.id.pid) == [900001])
  #expect(Set(plan.helperEntries.map(\.id.pid)) == [900002, 900003])
  #expect(plan.selectingHelpers([]) == nil)
  #expect(plan.selectingHelpers([plan.targets[0].id]) == nil)
  try await model.stopProject(plan)
  #expect(await actions.calls.map(\.pid) == [900001])
  #expect(await actions.helperCalls.isEmpty)
}

@Test @MainActor func separateHelperApprovalOnlySignalsSelectedHelper() async throws {
  let actions = FakeProjectActions()
  let selected = projectRow(900002, executable: bundledNode)
  let model = projectModel(ProjectSource([
    projectRow(900001), selected, projectRow(900003, executable: bundledNode),
  ]), actions)
  await model.refresh()
  let plan = try #require(try selectedPlan(model).selectingHelpers([selected.id]))
  #expect(plan.mode == .managedHelpers && plan.targets.map(\.id) == [selected.id])
  #expect(plan.selectingHelpers([selected.id]) == nil)
  try await model.stopProject(plan)
  #expect(await actions.calls.isEmpty)
  #expect(await actions.helperCalls == [selected.id])
  #expect(model.events.count == 1 && model.events.first?.state == .closed)
  #expect(!model.canConfirmProjectStop(plan))
}

@Test @MainActor func separateHelperApprovalRejectsReusedIdentityMovedDirectoryAndChangedUser()
  async throws
{
  let actions = FakeProjectActions()
  let old = (1...3).map { projectRow(Int32(900000 + $0), executable: bundledNode) }
  let source = ProjectSource(old)
  let model = projectModel(source, actions)
  await model.refresh()
  let plan = try #require(try selectedPlan(model).selectingHelpers(Set(old.map(\.id))))
  let foreign = projectRow(900003, executable: bundledNode, uid: getuid() &+ 1)
  await source.set([
    projectRow(900001, executable: bundledNode, seconds: 2),
    projectRow(900002, executable: bundledNode, cwd: "/work/project/moved"), foreign,
  ])
  await model.refresh()
  try await model.stopProject(plan)
  #expect(await actions.calls.isEmpty)
  #expect(await actions.helperCalls.isEmpty)
  #expect(model.events.count == 3)
  #expect(model.events.allSatisfy { if case .failed = $0.state { true } else { false } })
}

@Test @MainActor func pendingAndIndirectHelpersCannotBeSelected() async throws {
  let pending = projectRow(900001, executable: bundledNode)
  let indirect = projectRow(900002, inherited: true, executable: bundledNode)
  let model = projectModel(ProjectSource([pending, indirect]), FakeProjectActions())
  await model.refresh()
  _ = model.record(process: pending.id, name: "Pending fixture", state: .requested)
  let plan = try selectedPlan(model)
  #expect(plan.helperEntries.isEmpty)
  #expect(plan.selectingHelpers([pending.id, indirect.id]) == nil)
}

@Test @MainActor func singleProcessHelperReviewPreservesSelectionAndScopesOnlyThatHelper() async throws {
  let actions = FakeProjectActions()
  let first = projectRow(900001, executable: bundledNode)
  let model = projectModel(ProjectSource([first, projectRow(900002, executable: bundledNode)]), actions)
  await model.refresh()
  model.selection = .process(first.id)
  let review = try #require(model.helperStopPlan(for: first))
  #expect(review.helperEntries.map(\.id) == [first.id])
  #expect(review.originSelection == .process(first.id))
  let selected = try #require(review.selectingHelpers([first.id]))
  #expect(model.canConfirmProjectStop(selected))
  try await model.stopProject(selected)
  #expect(await actions.helperCalls == [first.id])
}

@Test @MainActor func helperBlockReasonsExplainPausedFailedAndChangedSelection() async throws {
  let row = projectRow(900001, executable: bundledNode)
  let model = projectModel(ProjectSource([row]), FakeProjectActions())
  await model.refresh()
  let plan = try #require(try selectedPlan(model).selectingHelpers([row.id]))
  #expect(model.projectStopBlockReason(plan) == nil)
  model.paused = true
  #expect(model.projectStopBlockReason(plan) == "Ölçüm duraklatıldı; devam ettir.")
  model.paused = false
  model.selection = nil
  #expect(model.projectStopBlockReason(plan)?.contains("seçim değişti") == true)
  #expect(!model.canConfirmProjectStop(plan))
}

@Test @MainActor func sessionHistoryBoundsCompletedRecordsAndRetainsPendingOperations() async {
  let defaults = UserDefaults(suiteName: "SessionHistory." + UUID().uuidString)!
  let model = Dashboard(source: ProjectSource([]), defaults: defaults)
  let pending = model.record(process: nil, name: "pending", state: .requested)
  var latest = pending
  for number in 0..<(Dashboard.completedEventLimit + 50) {
    latest = model.record(process: nil, name: "done \(number)", state: .closed)
  }
  #expect(model.events.count == Dashboard.completedEventLimit + 1)
  #expect(model.events.contains { $0.id == pending && $0.state == .requested })
  #expect(model.events.first?.id == latest)
  model.setEvent(pending, state: .closed)
  #expect(model.events.count == Dashboard.completedEventLimit)
  let reopened = Dashboard(source: ProjectSource([]), defaults: defaults)
  #expect(reopened.events.isEmpty && reopened.projectResults.isEmpty)
}

@Test @MainActor func historyCapDoesNotLoseLargeActiveBatchOutcomes() async throws {
  let rows = (0..<(Dashboard.completedEventLimit + 5)).map { projectRow(Int32(900001 + $0)) }
  let model = projectModel(ProjectSource(rows), FakeProjectActions())
  await model.refresh()
  try await model.stopProject(selectedPlan(model))
  #expect(model.projectResults.first?.closed == rows.count)
  #expect(model.events.count == Dashboard.completedEventLimit)
  #expect(model.pendingProjects.isEmpty)
}

@Test(arguments: [
  "/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
  "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
])
func helperPermissionIsSeparateFromNormalProcessAndProjectPermission(_ path: String) throws {
  let helper = projectRow(900001, executable: path)
  #expect(helper.sample.allowsSeparateHelperStop)
  #expect(ProjectStopPlan.exclusion(for: helper, pending: false) == ProjectStopPlan.helperApprovalRequired)
  #expect(ProjectStopPlan.exclusion(for: helper, pending: false, mode: .managedHelpers) == nil)
  #expect(throws: (any Error).self) {
    try ProcessMonitor.validateStop(helper.sample, current: helper.sample)
  }
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateStop(helper.sample, current: helper.sample)
  }
  try NativeProjectProcessActions.validateStop(helper.sample, current: helper.sample, mode: .managedHelpers)
  var reused = helper.sample
  reused.id = .init(pid: reused.id.pid, seconds: reused.id.seconds, microseconds: 1)
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateStop(helper.sample, current: reused, mode: .managedHelpers)
  }
  #expect(!helper.sample.protection!.contains("Aktif"))
  #expect(helper.stopImpact.contains("Hangi Codex sohbetinin kullandığı bilinmiyor"))
}

@Test(arguments: [
  "/Applications/Codex.app/Contents/MacOS/Codex",
  "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
  "/Applications/Codex.app/Contents/other/node",
  "/tmp/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
  "/System/Library/node", "/opt/homebrew/bin/node",
])
func separateHelperApprovalCannotBypassOtherProcessProtections(_ path: String) {
  let row = projectRow(900001, executable: path)
  #expect(!row.sample.allowsSeparateHelperStop)
  #expect(ProjectStopPlan.exclusion(for: row, pending: false, mode: .managedHelpers) != nil)
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateStop(row.sample, current: row.sample, mode: .managedHelpers)
  }
}

@Test func helperApprovalCannotBypassSystemSelfOrForeignUserProtection() {
  let base = projectRow(900001, executable: bundledNode).sample
  var foreign = base
  foreign.uid = getuid() &+ 1
  var own = base
  own.id = .init(pid: getpid(), seconds: 1)
  var system = base
  system.id = .init(pid: 1, seconds: 1)
  for sample in [foreign, own, system] {
    #expect(!sample.allowsSeparateHelperStop)
    #expect(throws: (any Error).self) {
      try NativeProjectProcessActions.validateStop(sample, current: sample, mode: .managedHelpers)
    }
  }
}

@Test(.enabled(if: installedBundledNode != nil))
@MainActor func realManagedHelperStopOnlyTouchesTheSelectedDisposableChild() async throws {
  let bundledNode = try #require(installedBundledNode)
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  var children: [Process] = []
  defer {
    for child in children where child.isRunning { child.terminate() }
  }
  for _ in 0..<2 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: bundledNode)
    child.arguments = ["-e", "setInterval(() => {}, 1000)"]
    child.currentDirectoryURL = root
    try child.run()
    children.append(child)
  }
  // Wait for exec and verify the actual path before enabling the helper-only policy.
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while children.contains(where: { ProcessMonitor.read($0.processIdentifier)?.path != bundledNode }),
    ProcessInfo.processInfo.systemUptime < deadline
  { try await Task.sleep(for: .milliseconds(10)) }
  let rows = try children.map { child in
    var sample = try #require(ProcessMonitor.read(child.processIdentifier))
    #expect(sample.path == bundledNode)
    let cwd: String = try #require(ProcessMonitor.workingDirectory(sample))
    sample.cwd = cwd
    var row = ProcessRow(
      sample: sample, cpu: nil, reasons: [], owner: "Codex",
      project: ProjectHint(path: root.path, sourcePID: sample.id.pid, inherited: false, hasProjectMarker: true))
    row.applicationKey = "codex"
    row.applicationName = "Codex"
    return row
  }
  let model = Dashboard(
    source: ProjectSource(rows),
    defaults: UserDefaults(suiteName: "ManagedHelperIntegration." + UUID().uuidString)!)
  await model.refresh()
  let app = try #require(model.presentation.applications.first { $0.id == "codex" })
  let project = try #require(app.projects.first { $0.id == root.path })
  let key = app.projectKey(project)
  model.selection = .group(key)
  let original = try #require(model.projectStopPlan(for: key))
  #expect(original.targets.isEmpty && original.helperEntries.count == 2)
  let selected = try #require(original.selectingHelpers([rows[0].id]))
  try await model.stopProject(selected)
  #expect(model.events.count == 1 && model.events.first?.state == .closed)
  #expect(ProcessMonitor.presence(rows[0].id) == .absent)
  #expect(children[1].isRunning)
  #expect(ProcessMonitor.presence(rows[1].id) == .sameIdentity)
}
@Test @MainActor func projectBatchFailureDoesNotSkipRemainingOrDisappearOnRefresh() async throws {
  let actions = FakeProjectActions(fail: 900001)
  let model = projectModel(ProjectSource([projectRow(900001), projectRow(900002)]), actions)
  await model.refresh()
  try await model.stopProject(selectedPlan(model))
  #expect(await actions.calls.count == 2)
  #expect(model.events.first { $0.process?.pid == 900001 }?.state == .failed("fixture failure"))
  #expect(model.events.first { $0.process?.pid == 900002 }?.state == .closed)
  await model.refresh()
  #expect(model.events.count == 2)
  #expect(model.pendingProjects.isEmpty)
}
@Test @MainActor func projectBatchRejectsReusedPIDMovedDirectoryAndNewChildren() async throws {
  let actions = FakeProjectActions()
  let source = ProjectSource([projectRow(900001), projectRow(900002), projectRow(900003)])
  let model = projectModel(source, actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  await source.set([
    projectRow(900001, seconds: 2), projectRow(900002, cwd: "/work/project/elsewhere"),
    projectRow(900003), projectRow(900004),
  ])
  await model.refresh()
  try await model.stopProject(plan)
  #expect(await actions.calls.map(\.pid) == [900003])
  #expect(model.events.filter { if case .failed = $0.state { true } else { false } }.count == 2)
}
@Test @MainActor func filteredOrPausedProjectConfirmationCannotSubmit() async throws {
  let actions = FakeProjectActions()
  let model = projectModel(ProjectSource([projectRow(900001)]), actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  model.request.query = "no-match"
  #expect(!model.canConfirmProjectStop(plan))
  do {
    try await model.stopProject(plan)
    Issue.record("Hidden project was actionable")
  } catch {}
  #expect(await actions.calls.isEmpty)
  #expect(model.events.isEmpty)
  model.request.query = ""
  await model.refresh()
  let updated = try selectedPlan(model)
  model.paused = true
  #expect(!model.canConfirmProjectStop(updated))
  model.stopMonitoring()
}
@Test @MainActor func searchedProjectOnlyIncludesVisibleTargets() async throws {
  let actions = FakeProjectActions()
  let model = projectModel(ProjectSource([projectRow(900001), projectRow(900002)]), actions)
  model.request.query = "900001"
  await model.refresh()
  let plan = try selectedPlan(model)
  #expect(plan.targets.map(\.id.pid) == [900001])
  try await model.stopProject(plan)
  #expect(await actions.calls.map(\.pid) == [900001])
}

@Test @MainActor func projectOutcomeDoesNotCountUnrelatedNewProcessesAsReplacement() async throws {
  let actions = FakeProjectActions()
  let old = projectRow(900001)
  let model = projectModel(ProjectSource([old]), actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  let replacement = projectRow(900002)
  let otherApp = projectRow(900003, app: "different")
  let otherPath = projectRow(900004, path: "/other/project")
  let otherBinary = projectRow(900005, executable: "/opt/homebrew/bin/python3")
  let event = OperationEvent(
    id: UUID(), process: old.id, name: "fixture", date: Date(),
    state: .closed, simulatorID: nil, projectBatchID: plan.id)
  let result = ProjectOperationResult.evaluate(
    plan: plan, events: [event],
    before: projectSnapshot([old]),
    after: projectSnapshot([replacement, otherApp, otherPath, otherBinary]))
  #expect(result.closed == 1)
  #expect(result.replacementCount == 1)
  #expect(result.beforeMemory == nil && result.afterMemory == nil)
  #expect(result.incompleteMemory)
  let failedScan = ProjectOperationResult.evaluate(
    plan: plan, events: [event], before: projectSnapshot([old]), after: nil)
  #expect(failedScan.replacementCount == nil)
  #expect(failedScan.afterMemory == nil)
  var partial = projectSnapshot([replacement])
  partial.unreadableUserCount = 1
  let missingMember = ProjectOperationResult.evaluate(
    plan: plan, events: [event], before: projectSnapshot([old]), after: partial)
  #expect(missingMember.replacementCount == nil && missingMember.incompleteMemory)
}

private struct AlreadyExitedProjectAction: ProjectProcessActions {
  func stop(_ sample: ProcessSample) async throws { throw MonitorError.message("Already gone") }
  func presence(_ identity: ProcessIdentity) async -> ProcessPresence { .absent }
}
@Test @MainActor func childClosedByEarlierParentIsNotReportedAsFailed() async throws {
  let model = Dashboard(
    source: ProjectSource([projectRow(900001)]),
    defaults: UserDefaults(suiteName: "ClosedChild." + UUID().uuidString)!,
    projectActions: AlreadyExitedProjectAction())
  await model.refresh()
  try await model.stopProject(selectedPlan(model))
  #expect(model.events.first?.state == .closed)
}

private actor RefreshingParentExitActions: ProjectProcessActions {
  private var afterParentStop: (@Sendable () async -> Void)?
  let childPresence: ProcessPresence
  var stopped: [ProcessIdentity] = []
  var checked: [ProcessIdentity] = []
  init(childPresence: ProcessPresence) { self.childPresence = childPresence }
  func configure(_ callback: @escaping @Sendable () async -> Void) {
    afterParentStop = callback
  }
  func stop(_ sample: ProcessSample) async throws {
    stopped.append(sample.id)
    if sample.id.pid == 900001 { await afterParentStop?() }
  }
  func presence(_ identity: ProcessIdentity) -> ProcessPresence {
    checked.append(identity)
    return identity.pid == 900002 ? childPresence : .absent
  }
}
@Test(arguments: [ProcessPresence.absent, .differentIdentity, .unreadable, .sameIdentity])
@MainActor func refreshedSnapshotAfterParentStopResolvesChildPresence(_ presence: ProcessPresence)
  async throws
{
  let parent = projectRow(900001)
  let child = projectRow(900002, parent: parent.id.pid)
  let source = ProjectSource([parent, child])
  let actions = RefreshingParentExitActions(childPresence: presence)
  let model = Dashboard(
    source: source,
    defaults: UserDefaults(suiteName: "RefreshedParentExit." + UUID().uuidString)!,
    projectActions: actions)
  await model.refresh()
  let plan = try selectedPlan(model)
  #expect(plan.targets.map(\.id) == [parent.id, child.id])
  await actions.configure {
    // Model the next background scan arriving while the parent's stop call is suspended.
    await source.set([])
    await model.refresh()
  }
  try await model.stopProject(plan)
  #expect(model.snapshot?.rows.isEmpty == true)
  #expect(await actions.stopped == [parent.id])
  #expect(await actions.checked.contains(child.id))
  #expect(model.events.first { $0.process == parent.id }?.state == .closed)
  let childState = try #require(model.events.first { $0.process == child.id }?.state)
  switch presence {
  case .absent, .differentIdentity: #expect(childState == .closed)
  case .unreadable: #expect(childState == .unverified)
  case .sameIdentity:
    guard case .failed = childState else {
      Issue.record("Still-live hidden child must remain unsignalled and report the scope failure")
      return
    }
  }
}

@Test @MainActor func projectViewBatchCoversBothAppsButExcludesSharedModelService() async throws {
  let actions = FakeProjectActions()
  let model = projectModel(
    ProjectSource([
      projectRow(900001, app: "codex"), projectRow(900002, app: "claude"),
      projectRow(900003, app: "codex", executable: "/opt/homebrew/bin/llama-server"),
      projectRow(900004, path: "/other/project"),
    ]), actions)
  model.request.mode = .projects
  await model.refresh()
  model.selection = .group("/work/project")
  let plan = try #require(model.projectStopPlan(for: "/work/project"))
  #expect(plan.entries.count == 3)
  #expect(plan.excludedCount == 1)
  try await model.stopProject(plan)
  #expect(Set(await actions.calls.map(\.pid)) == [900001, 900002])
}

@Test @MainActor func projectWideResultsMatchEachTargetApplicationAndExcludeOtherProjects()
  async throws
{
  let a = projectRow(900001, app: "codex")
  let b = projectRow(900002, app: "claude")
  let model = projectModel(ProjectSource([a, b]), FakeProjectActions())
  model.request.mode = .projects
  await model.refresh()
  model.selection = .group("/work/project")
  let plan = try #require(model.projectStopPlan(for: "/work/project"))
  let result = ProjectOperationResult.evaluate(
    plan: plan, events: [],
    before: projectSnapshot([a, b]),
    after: projectSnapshot([
      projectRow(900003, app: "codex"), projectRow(900004, app: "claude"),
      projectRow(900005, app: "unrelated"),
      projectRow(900006, app: "codex", path: "/other/project"),
    ]))
  #expect(result.replacementCount == 2)
}

@Test func projectOverviewRanksByValueAcrossCategoriesWhenContextIsEnabled() async {
  let base = projectRow(990001)
  var large = base.sample
  large.id = .init(pid: 990002, seconds: 1)
  large.path = "/System/Library/test-helper"
  large.footprint = 900
  var small = base.sample
  small.id = .init(pid: 990001, seconds: 10)
  small.footprint = 10
  let rows = [
    ProcessRow(sample: small, cpu: 1, reasons: [], owner: "test", project: base.project),
    ProcessRow(sample: large, cpu: 20, reasons: [], owner: "macOS"),
  ]
  for sort in SortOrder.allCases {
    var request = PresentationRequest()
    request.mode = .projects
    request.showProjectContext = true
    request.sort = sort
    let result = await Presentation.prepare(projectSnapshot(rows), request: request)
    #expect(result.groups.first?.id == "context:system")
    #expect(result.groups.last?.isProject == true)
  }
}
