import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func sample(
  pid: Int32 = 900000, parent: Int32 = 1, path: String = "/opt/homebrew/bin/node",
  seconds: UInt64 = 1, cpu: UInt64 = 0, memory: UInt64 = 0
) -> ProcessSample {
  var value = ProcessSample(
    id: .init(pid: pid, seconds: seconds), parent: parent, uid: getuid(), path: path, cpuTime: cpu,
    memory: memory)
  value.footprint = memory
  return value
}
@Test func reusedPIDIsRejected() {
  #expect(throws: (any Error).self) {
    try ProcessMonitor.validateStop(sample(), current: sample(seconds: 2))
  }
  #expect(throws: (any Error).self) { try ProcessMonitor.validateStop(sample(), current: nil) }
}
@Test func executableReplacementIsRejected() {
  #expect(throws: (any Error).self) {
    try ProcessMonitor.validateStop(sample(), current: sample(path: "/bin/other"))
  }
}
@Test(arguments: [
  "/System/Library/foo", "/usr/libexec/foo", "/Applications/ChatGPT.app/Contents/Resources/node",
  "/Applications/Claude.app/Contents/node", "/Library/Developer/CoreSimulator/foo",
  "/usr/local/bin/claude", "/usr/local/bin/codex",
])
func protectedProcessesCannotBeStopped(path: String) {
  let process = sample(path: path)
  #expect(process.protection != nil)
  #expect(throws: (any Error).self) { try ProcessMonitor.validateStop(process, current: process) }
}
@Test func unknownProcessCannotBeStopped() {
  let process = sample(path: "/bin/sleep")
  #expect(throws: (any Error).self) { try ProcessMonitor.validateStop(process, current: process) }
}
@Test func highCPURequiresThreeMeasurements() {
  var counts: [ProcessIdentity: Int] = [:]
  var old = sample(parent: 123, seconds: UInt64(Date().timeIntervalSince1970))
  for index in 1...3 {
    var new = old
    new.cpuTime += 15_000_000_000
    let rows = ProcessMonitor.rows([new], previous: [old.id: old], elapsed: 30, hotCounts: &counts)
    #expect(rows[0].cpu == 50)
    #expect(rows[0].reasons.contains("3 ölçümdür CPU ≥ %25") == (index == 3))
    old = new
  }
  let cool = ProcessMonitor.rows([old], previous: [old.id: old], elapsed: 30, hotCounts: &counts)
  #expect(cool[0].reasons.isEmpty)
}
@Test func missingBaselineIsNotIdleEvidence() {
  var counts: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows(
    [sample(parent: 123)], previous: [:], elapsed: 30, hotCounts: &counts)
  #expect(rows[0].cpu == nil)
  #expect(rows[0].reasons.isEmpty)
}
@Test func ancestryResolvesCodexAndCyclesTerminate() {
  var counts: [ProcessIdentity: Int] = [:]
  let agent = sample(
    pid: 900001, parent: 900000, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
  let child = sample(parent: 900001)
  let rows = ProcessMonitor.rows([child, agent], previous: [:], elapsed: 0, hotCounts: &counts)
  #expect(rows[0].owner == "Codex")
}

@Test func maestroDescriptionSeparatesRuntimeAndApplication() {
  var process = sample(path: "/opt/java/bin/java")
  process.isMaestroMCP = true
  let row = ProcessRow(sample: process, cpu: 0, reasons: [], owner: "Codex")
  #expect(row.title == "Maestro · Mobil test bağlantısı")
  #expect(row.connection == "Üst uygulama: Codex")
  #expect(row.ownershipExplanation.contains("bilinmiyor"))
  #expect(row.stopImpact.contains("Maestro"))
}
@Test func unknownJavaIsNotPresentedAsMaestro() {
  let row = ProcessRow(
    sample: sample(path: "/opt/java/bin/java"), cpu: 0, reasons: [], owner: "Claude")
  #expect(row.title == "Java · Görevi belirlenemedi")
  #expect(!row.explanation.contains("MCP"))
}

@Test func systemCPUUsesAllCoresAndHandlesCounterWrap() {
  let old = SystemSample(ticks: [100, 100, 0, 800], memory: nil)
  let new = SystemSample(ticks: [150, 150, 0, 900], memory: nil)
  #expect(new.cpuUsage(since: old) == 50)
  #expect(new.cpuUsage(since: nil) == nil)
  #expect(new.cpuUsage(since: new) == nil)
  let before = SystemSample(ticks: [UInt64(UInt32.max) - 5, 0, 0, 0], memory: nil)
  let wrapped = SystemSample(ticks: [4, 0, 0, 10], memory: nil)
  #expect(wrapped.cpuUsage(since: before) == 50)
}
@Test func appGroupsIncludeExternalChildrenWithoutDoubleCounting() {
  var counts: [ProcessIdentity: Int] = [:]
  let parent = sample(
    pid: 900001, parent: 1, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", memory: 100)
  let child = sample(pid: 900002, parent: 900001, path: "/opt/java/bin/java", memory: 200)
  let other = sample(
    pid: 900003, parent: 1,
    path: "/Applications/Google Chrome.app/Contents/Helpers/Helper.app/Contents/MacOS/Helper",
    memory: 400)
  let rows = ProcessMonitor.rows(
    [parent, child, other], previous: [:], elapsed: 1, hotCounts: &counts)
  let groups = ResourceSummary.groups(rows)
  #expect(groups.count == 2)
  #expect(groups.first(where: { $0.name == "Codex" })?.memory == 300)
  #expect(groups.first(where: { $0.name == "Codex" })?.rows.count == 2)
  #expect(groups.first(where: { $0.name == "Google Chrome" })?.memory == 400)
  #expect(groups.reduce(0) { $0 + $1.rows.count } == 3)
  #expect(groups.allSatisfy { $0.cpu == nil })
}

@Test func pagingRatesUseElapsedTimeAndRejectMissingCounters() {
  var old = SystemSample(ticks: nil, memory: nil)
  old.paging = [100, 200, 300, 400]
  old.pageSize = 16384
  old.measuredAt = 10
  var next = old
  next.paging = [110, 220, 330, 440]
  next.measuredAt = 12
  #expect(next.pagingRates(since: old) == [81920, 163840, 245760, 327680])
  #expect(next.pagingRates(since: nil) == nil)
  #expect(old.pagingRates(since: next) == nil)
  next.paging = [0, 0, 0, 0]
  #expect(next.pagingRates(since: old) == nil)
}
@Test func footprintRevealsMemoryHiddenFromRSS() {
  var process = sample(memory: 1024)
  process.footprint = 2_147_483_648
  #expect(process.memoryLoad == 2_147_483_648)
  var counts: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows([process], previous: [:], elapsed: 1, hotCounts: &counts)
  #expect(rows[0].reasons.contains("1 GiB üzerinde bellek yükü"))
  #expect(ResourceSummary.groups(rows)[0].memory == 2_147_483_648)
  process.footprint = nil
  #expect(process.memoryLoad == nil)
  #expect(process.memoryReading.rss == 1024)
  #expect(process.memoryReading.source == .rss)
}
@Test(arguments: [
  (1, "Normal"), (2, "Bellek baskısı yüksek"), (4, "Bellek baskısı kritik"), (-1, "Bilinmiyor"),
  (99, "Bilinmiyor"),
])
func pressureLabelsDoNotTreatUnknownAsHealthy(value: Int, label: String) {
  var sample = SystemSample(ticks: nil, memory: nil)
  sample.pressure = value
  #expect(sample.pressureTitle == label)
}

@Test func projectHintsDistinguishDirectAndInheritedEvidence() {
  var parent = sample(pid: 900001, path: "/usr/local/bin/claude")
  parent.cwd = "/Users/test/project"
  var child = sample(pid: 900002, parent: 900001)
  let roots = ["/Users/test/project": ProjectRoot(path: "/Users/test/project", marked: true)]
  let lookup = [parent.id.pid: parent, child.id.pid: child]
  let inherited = ProjectResolver.hint(for: child, samples: lookup, roots: roots)
  #expect(inherited?.name == "project")
  #expect(inherited?.inherited == true)
  child.cwd = "/Users/test/project"
  #expect(ProjectResolver.hint(for: child, samples: lookup, roots: roots)?.inherited == false)
}
@Test func sharedRendererIsNotAssignedAProjectFromItsParent() {
  var parent = sample(pid: 900001)
  parent.cwd = "/Users/test/project"
  let child = sample(
    pid: 900002, parent: 900001, path: "/Applications/ChatGPT.app/Contents/Renderer")
  #expect(
    ProjectResolver.hint(
      for: child, samples: [parent.id.pid: parent],
      roots: ["/Users/test/project": ProjectRoot(path: "/Users/test/project", marked: true)]) == nil
  )
}
@Test func genericAndRuntimeDirectoriesAreNotProjects() {
  for path in [
    "/", "/Users/test", "/Users/test/Library/foo", "/Users/test/.maestro/lib",
    "/Applications/X.app/Contents",
  ] {
    #expect(!ProjectResolver.usable(path, home: "/Users/test"))
  }
  #expect(ProjectResolver.usable("/Users/test/financeguy", home: "/Users/test"))
}
