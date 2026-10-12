import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func projectRow(
  _ pid: Int32, app: String = "codex", path: String = "/work/project", inherited: Bool = false,
  executable: String = "/opt/homebrew/bin/node", seconds: UInt64 = 1, cwd: String? = nil,
  parent: Int32 = 1
) -> ProcessRow {
  var sample = ProcessSample(
    id: .init(pid: pid, seconds: seconds), parent: parent, uid: getuid(), path: executable)
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
  let fail: Int32?
  init(fail: Int32? = nil) { self.fail = fail }
  func stop(_ sample: ProcessSample) throws {
    calls.append(sample.id)
    if sample.id.pid == fail { throw MonitorError.message("fixture failure") }
  }
  func presence(_ identity: ProcessIdentity) -> ProcessPresence {
    identity.pid == fail || !calls.contains(identity) ? .sameIdentity : .absent
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
