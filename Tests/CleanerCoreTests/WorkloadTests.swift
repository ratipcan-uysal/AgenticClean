import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func workRow(_ pid: Int32, _ name: String, memory: UInt64? = 100, project: String? = nil)
  -> ProcessRow
{
  var sample = ProcessSample(
    id: .init(pid: pid, seconds: 20), parent: 1, uid: getuid(), path: "/opt/homebrew/bin/" + name)
  sample.footprint = memory
  sample.cwd = project
  var row = ProcessRow(sample: sample, cpu: 2, reasons: [], owner: "Codex")
  row.applicationKey = "family:codex"
  row.applicationName = "Codex"
  if let project {
    row.project = ProjectHint(
      path: project, sourcePID: pid, inherited: false, hasProjectMarker: true)
  }
  return row
}
@Test func independentModelAndRuntimeAreVisibleOutsideAgentGroup() {
  let rows = [workRow(900001, "llama-server"), workRow(900002, "node"), workRow(900003, "helper")]
  let work = Workload.prepare(rows, sort: .memory)
  #expect(work.count == 3)
  #expect(work.first(where: { $0.kind == .localAI })?.primary?.id == rows[0].id)
  #expect(work.first(where: { $0.kind == .runtime })?.primary?.id == rows[1].id)
  let all = work.flatMap(\.group.rows).map(\.id)
  #expect(Set(all).count == rows.count)
  #expect(all.count == rows.count)
}
@Test func workloadUnknownMemoryIsNotZeroAndIdentityIncludesStart() {
  let row = workRow(900001, "node", memory: nil)
  let work = Workload.prepare([row], sort: .memory)
  #expect(work[0].group.memory == nil)
  #expect(work[0].group.missingMemoryCount == 1)
  var sample = row.sample
  sample.id = .init(pid: row.id.pid, seconds: row.id.seconds + 1)
  let newer = ProcessRow(sample: sample, cpu: nil, reasons: [], owner: "Codex")
  #expect(Workload.prepare([newer], sort: .memory)[0].id != work[0].id)
}
@Test func localModelServicesAreExcludedEvenWithDirectProjectEvidence() {
  for name in ["llama-server", "ollama", "llmster"] {
    let row = workRow(900001, name, project: "/Users/test/portfolio")
    #expect(ProjectStopPlan.exclusion(for: row, pending: false) != nil)
  }
}
@Test func sameNamedProjectsDoNotCollapseWorkloadIdentity() {
  let rows = [
    workRow(900001, "node", project: "/Users/a/site"),
    workRow(900002, "node", project: "/Users/b/site"),
  ]
  let work = Workload.prepare(rows, sort: .memory)
  #expect(Set(work.map(\.id)).count == 2)
  #expect(Set(work.compactMap(\.projectPath)).count == 2)
}

@Test func projectOverviewSeparatesContextWithoutLosingProcesses() {
  let project = workRow(900010, "node", project: "/Users/test/site")
  let runtime = workRow(900011, "node")
  let model = workRow(900012, "llama-server")
  var renderer = workRow(900013, "helper")
  var sample = renderer.sample
  sample.path = "/Applications/Codex.app/Contents/MacOS/helper"
  renderer = ProcessRow(sample: sample, cpu: 1, reasons: [], owner: "Codex")
  renderer.applicationKey = "family:codex"
  renderer.applicationName = "Codex"
  var systemSample = sample
  systemSample.id = .init(pid: 900014, seconds: 20)
  systemSample.path = "/System/Library/CoreServices/test-service"
  let system = ProcessRow(sample: systemSample, cpu: nil, reasons: [], owner: "macOS")
  let rows = [project, runtime, model, renderer, system]
  let groups = ResourceSummary.projectOverview(rows)
  #expect(groups.filter(\.isProject).count == 1)
  #expect(groups.first { $0.id == "context:unattributed" }?.rows.map(\.id) == [runtime.id])
  #expect(groups.first { $0.id == "context:system" }?.rows.map(\.id) == [system.id])
  #expect(groups.first { $0.name == "Codex" }?.rows.map(\.id) == [renderer.id])
  #expect(groups.first { $0.rows.contains { $0.id == model.id } }?.name == model.title)
  #expect(Set(groups.flatMap(\.rows).map(\.id)) == Set(rows.map(\.id)))
  #expect(groups.flatMap(\.rows).count == rows.count)
  #expect(groups.filter { !$0.isProject }.allSatisfy { $0.id.hasPrefix("context:") })
}
