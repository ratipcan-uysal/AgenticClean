import Darwin
import Foundation
import Testing
@testable import CleanerCore

private func stableRow(
  _ pid: Int32, bytes: UInt64, cpu: Double = 0, seconds: UInt64 = 1,
  parent: Int32 = 1, project: String = "/fixture/stable", reasons: [String] = []
) -> ProcessRow {
  var sample = ProcessSample(id: .init(pid: pid, seconds: seconds), parent: parent,
                             uid: getuid(), path: "/fixture/bin/python3")
  sample.cwd = project
  sample.footprint = bytes
  var row = ProcessRow(sample: sample, cpu: cpu, reasons: reasons, owner: "Fixture",
    project: ProjectHint(path: project, sourcePID: pid, inherited: false, hasProjectMarker: true))
  row.applicationKey = "fixture.tools"
  row.applicationName = "Fixture tools"
  return row
}
private func stableSnapshot(_ rows: [ProcessRow]) -> Snapshot {
  Snapshot(date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interval: 5,
    duration: 0, system: .init(ticks: nil, memory: nil), swap: nil, cpu: 20, paging: nil,
    rows: rows, applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: .partial, sustainedCPU: false)
}
private actor StableSource: SnapshotSource {
  var rows: [ProcessRow]
  init(_ rows: [ProcessRow]) { self.rows = rows }
  func capture() -> Snapshot { stableSnapshot(rows) }
  func resetBaseline() {}
  func set(_ rows: [ProcessRow]) { self.rows = rows }
}
private actor StableActions: ProjectProcessActions {
  var result: ProcessPresence = .absent
  func stop(_ sample: ProcessSample) throws { throw MonitorError.message("No fixture signals") }
  func presence(_ identity: ProcessIdentity) -> ProcessPresence { result }
  func setPresence(_ result: ProcessPresence) { self.result = result }
}
@MainActor private func stableDashboard(_ source: StableSource, _ actions: StableActions = .init()) -> Dashboard {
  Dashboard(source: source, defaults: UserDefaults(suiteName: "StableList." + UUID().uuidString)!,
            projectActions: actions)
}

@Test @MainActor func liveRanksAndValuesChangeWithoutMovingInspectionRows() async {
  let source = StableSource([stableRow(900001, bytes: 200), stableRow(900002, bytes: 100)])
  let model = stableDashboard(source)
  await model.refresh()
  let ids = model.list.presentation.rows.map(\.id)
  model.selection = .process(ids[0])
  await source.set([stableRow(900001, bytes: 50, cpu: 42), stableRow(900002, bytes: 400)])
  await model.refresh()
  #expect(model.list.presentation.rows.map(\.id) == ids)
  #expect(model.list.presentation.workloads.map(\.primary?.id) == ids.map(Optional.some))
  #expect(model.presentation.rows.first?.id == ids[1])
  #expect(model.list.presentation.rows[0].sample.footprint == 50)
  #expect(model.list.presentation.rows[0].cpu == 42)
  #expect(model.snapshot?.cpu == 20 && model.history.points.count >= 1)
  #expect(model.selectedRow?.id == ids[0] && model.selectedRow?.sample.footprint == 50)
  #expect(model.canStop(model.selectedRow!))
  await model.resortList()
  #expect(model.list.presentation.rows.map(\.id) == [ids[1], ids[0]])
  #expect(model.selection == .process(ids[0]))
}

@Test @MainActor func newTasksWaitForExplicitSortAndDeparturesNeverAuthorizeStops() async {
  let a = stableRow(900001, bytes: 200), b = stableRow(900002, bytes: 100)
  let source = StableSource([a, b])
  let model = stableDashboard(source)
  await model.refresh()
  model.selection = .process(a.id)
  let added = stableRow(900003, bytes: 900)
  await source.set([b, added])
  await model.refresh()
  #expect(model.list.pendingCount == 1)
  #expect(model.list.presentation.rows.map(\.id) == [a.id, b.id])
  #expect(model.list.missing == [a.id])
  #expect(model.list.presence[a.id] == .absent)
  #expect(model.selectedRow?.id == a.id && !model.canStop(a))
  #expect(model.selectedPresence == .absent)
  await model.refresh()
  #expect(model.selectedPresence == .absent)
  await model.stop(a)
  #expect(model.events.isEmpty)
  #expect(!model.presentation.rows.contains { $0.id == a.id })
  await model.resortList()
  #expect(model.list.pendingCount == 0 && model.list.missing.isEmpty)
  #expect(model.list.presentation.rows.map(\.id) == [added.id, b.id])
  #expect(model.selectedPresence == .absent)
}

@Test @MainActor func reusedPIDWaitsAsNewIdentityAndCannotReplaceTheSelectedOldProcess() async {
  let old = stableRow(900001, bytes: 200), replacement = stableRow(900001, bytes: 900, seconds: 2)
  let source = StableSource([old])
  let model = stableDashboard(source)
  await model.refresh()
  model.selection = .process(old.id)
  await source.set([replacement])
  await model.refresh()
  #expect(model.list.presentation.rows.map(\.id) == [old.id])
  #expect(model.list.pendingCount == 1 && model.list.missing.contains(old.id))
  #expect(model.selection == .process(old.id) && !model.canStop(old))
  await model.resortList()
  #expect(model.list.presentation.rows.map(\.id) == [replacement.id])
  #expect(model.selection == .process(old.id) && !model.canStop(replacement))
}

@Test @MainActor func missingMeasurementsAreExcludedAndUnreadableIsNotClosed() async {
  let a = stableRow(900001, bytes: 200), b = stableRow(900002, bytes: 100)
  let source = StableSource([a, b]), actions = StableActions()
  await actions.setPresence(.unreadable)
  let model = stableDashboard(source, actions)
  await model.refresh()
  await source.set([b])
  await model.refresh()
  let group = model.list.presentation.groups[0]
  #expect(group.rows.count == 2 && group.memory == 100 && group.missingMemoryCount == 1)
  #expect(model.list.presence[a.id] == .unreadable)
  #expect(model.list.presentation.rows.first?.sample.footprint == 200) // explicitly last-known
  await actions.setPresence(.absent)
  await model.refresh()
  #expect(model.list.presence[a.id] == .absent)
  await source.set([a, b])
  await model.refresh()
  #expect(model.list.missing.isEmpty && model.list.presence[a.id] == nil)
}

@Test func projectHierarchyAndMembershipStayFixedUntilExplicitSort() async throws {
  let a = stableRow(900001, bytes: 200)
  let b = stableRow(900002, bytes: 100, seconds: 2, parent: a.id.pid)
  var request = PresentationRequest()
  request.mode = .projects
  let initial = await Presentation.prepare(stableSnapshot([a, b]), request: request)
  var list = StableList()
  list.update(initial)
  let group = try #require(list.presentation.groups.first)
  let tree = list.tree(for: group)
  let changedA = stableRow(900001, bytes: 50)
  let changedB = stableRow(900002, bytes: 900, seconds: 2, project: "/fixture/moved")
  let latest = await Presentation.prepare(stableSnapshot([changedA, changedB]), request: request)
  list.update(latest)
  #expect(list.presentation.groups.map(\.id) == initial.groups.map(\.id))
  #expect(list.presentation.groups[0].isProject)
  #expect(list.tree(for: group).map(\.id) == tree.map(\.id))
  #expect(list.tree(for: group).map(\.depth) == [0, 1])
  #expect(list.tree(for: group)[1].row.sample.footprint == 900)
  list.update(latest, reset: true)
  #expect(list.presentation.groups.count == 2)
}

@Test @MainActor func filterAndSortChangesAdoptFreshMembershipRatherThanKeepingOldScope() async throws {
  let a = stableRow(900001, bytes: 200), b = stableRow(900002, bytes: 100)
  let source = StableSource([a])
  let model = stableDashboard(source)
  await model.refresh()
  await source.set([a, b])
  await model.refresh()
  #expect(model.list.pendingCount == 1)
  model.request.sort = .cpu
  await model.resortList()
  #expect(model.list.pendingCount == 0 && model.list.presentation.rows.count == 2)
  model.selection = .process(a.id)
  model.request.query = "900002"
  await model.resortList()
  #expect(model.selection == nil)
  #expect(model.list.presentation.rows.map(\.id) == [b.id])
  model.request.query = ""
  await model.resortList()
  #expect(model.list.presentation.rows.count == 2)
}

@Test @MainActor func selectingRetainedMissingRowsStillShowsTheirIdentityWithoutActionAccess() async {
  let a = stableRow(900001, bytes: 200)
  let source = StableSource([a])
  let model = stableDashboard(source)
  await model.refresh()
  await source.set([])
  await model.refresh()
  model.selection = .process(a.id)
  #expect(model.selectedRow?.id == a.id)
  #expect(!model.canStop(a) && model.helperStopPlan(for: a) == nil)
  #expect(model.list.presentation.groups.count == 1)
  #expect(model.list.presentation.groups[0].memory == nil)
  #expect(model.list.isMissing(model.list.presentation.groups[0]))
  model.stopMonitoring()
}

@Test func fixedListRetainsNoGrowingBacklogAcrossManyNewProcesses() async {
  let initial = stableRow(900001, bytes: 10)
  var list = StableList()
  list.update(await Presentation.prepare(stableSnapshot([initial]), request: .init()))
  for pid in 900002..<900052 {
    let row = stableRow(Int32(pid), bytes: 100)
    list.update(await Presentation.prepare(stableSnapshot([row]), request: .init()))
    #expect(list.presentation.rows.count == 1 && list.pendingCount == 1)
  }
}

@Test @MainActor func retainedProcessLosingFilterMatchKeepsLiveReadingsAndSelection() async {
  let busy = stableRow(900001, bytes: 200, cpu: 90, reasons: ["High CPU"])
  let source = StableSource([busy])
  let model = stableDashboard(source)
  model.request.filter = .attention
  await model.refresh()
  model.selection = .process(busy.id)
  let quiet = stableRow(900001, bytes: 50, cpu: 2)
  let newcomer = stableRow(900002, bytes: 100, cpu: 80, reasons: ["High CPU"])
  await source.set([quiet, newcomer])
  await model.refresh()
  #expect(model.list.presentation.rows.map(\.id) == [busy.id])
  #expect(model.list.presentation.rows.first?.cpu == 2)
  #expect(model.list.presentation.groups.first?.memory == 50)
  #expect(model.list.missing.isEmpty && model.list.pendingCount == 1)
  #expect(model.selection == .process(busy.id) && model.selectedPresence == .sameIdentity)
  #expect(model.selectedRow?.sample.footprint == 50)
  model.selection = nil
  model.selection = .process(busy.id)
  #expect(model.selectedPresence == .sameIdentity && model.selectedRow?.cpu == 2)
  await model.resortList()
  #expect(model.list.presentation.rows.map(\.id) == [newcomer.id])
  #expect(model.selection == nil)
}
