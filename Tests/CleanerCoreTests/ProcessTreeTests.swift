import Testing
import Darwin
@testable import CleanerCore

private func treeRow(_ pid: Int32, _ parent: Int32, _ start: UInt64 = 1) -> ProcessRow {
  ProcessRow(sample: ProcessSample(id: .init(pid: pid, seconds: start), parent: parent, uid: 501, path: "/bin/node"), cpu: 0, reasons: [], owner: "Codex")
}
@Test func processTreeKeepsEveryIdentityAndParentOrder() {
  let result = ProcessTreeItem.ordered([treeRow(3, 2), treeRow(1, 0), treeRow(2, 1), treeRow(4, 99)])
  #expect(result.map { $0.id.pid } == [1, 2, 3, 4])
  #expect(result.map(\.depth) == [0, 1, 2, 0])
}
@Test func processTreeSurvivesCyclesAndReusedParents() {
  let result = ProcessTreeItem.ordered([treeRow(1, 2), treeRow(2, 1), treeRow(3, 4, 1), treeRow(4, 0, 2)])
  #expect(Set(result.map(\.id)).count == 4)
  #expect(result.first { $0.id.pid == 3 }?.depth == 0)
}
@Test func codexHelperRequiresExactBundledExecutablePath() {
  var sample = treeRow(1, 0).sample
  sample.path = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
  #expect(sample.isBundledCodexHelper)
  sample.path = "/Users/test/project/node"
  #expect(!sample.isBundledCodexHelper)
  sample.path = "/tmp/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
  #expect(!sample.isBundledCodexHelper)
}

@Test func realProcessCPUCounterUsesNanoseconds() throws {
  let before = try #require(ProcessMonitor.read(getpid()))
  let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
  var value = 1.0
  while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started < 50_000_000 {
    value = value * 1.00000001 + 0.000001
  }
  let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started
  let after = try #require(ProcessMonitor.read(getpid()))
  #expect(value > 1)
  #expect(after.cpuTime >= before.cpuTime)
  // Other test threads may add CPU; this thread alone establishes a lower bound.
  #expect(Double(after.cpuTime - before.cpuTime) >= Double(elapsed) * 0.8)
}
