import Foundation
import Testing

@testable import CleanerCore

private func historySnapshot(_ date: Date, groups: [ResourceGroup] = [], unreadableUsers: Int = 0)
  -> Snapshot
{
  Snapshot(
    date: date, uptime: 1, interval: 5, duration: 0,
    system: SystemSample(ticks: nil, memory: nil), swap: nil, cpu: nil, paging: nil,
    rows: groups.flatMap(\.rows), applications: groups, projects: groups,
    unreadableCount: 0, quality: .partial, sustainedCPU: false, unreadableUserCount: unreadableUsers
  )
}
@Test func groupHistoryIsBoundedThrottledAndLeavesGaps() {
  var buffer = GroupHistoryBuffer()
  let start = Date(timeIntervalSince1970: 100_000)
  buffer.record(historySnapshot(start))
  buffer.record(historySnapshot(start.addingTimeInterval(5)))
  #expect(buffer.frames.count == 1)
  buffer.gap(at: start.addingTimeInterval(6))
  buffer.record(historySnapshot(start.addingTimeInterval(7)))
  #expect(buffer.frames.count == 3)
  #expect(buffer.frames[0].segment != buffer.frames[2].segment)
  for i in 1...1000 { buffer.record(historySnapshot(start.addingTimeInterval(Double(i * 15)))) }
  #expect(buffer.frames.count <= 121)
  #expect(buffer.frames.allSatisfy { $0.date >= start.addingTimeInterval(15_000 - 1800) })
}
@Test func groupHistoryRetainsBothLeadersAndMissingValues() {
  let groups = (0..<500).map { index in
    var sample = ProcessSample(
      id: .init(pid: Int32(index + 100), seconds: 1), parent: 1,
      uid: 501, path: "/example/\(index)", memory: 10)
    sample.footprint = index == 0 ? nil : UInt64(index)
    let row = ProcessRow(
      sample: sample, cpu: index == 499 ? nil : Double(500 - index), reasons: [], owner: "")
    return ResourceGroup(id: "\(index)", name: "App \(index)", rows: [row])
  }
  var buffer = GroupHistoryBuffer()
  buffer.record(historySnapshot(Date(), groups: groups))
  let values = buffer.frames[0].applications
  #expect(values.count <= 40)
  #expect(values.contains { $0.id == "0" && $0.memory == nil && $0.missingMemoryCount == 1 })
  #expect(values.contains { $0.id == "499" && $0.cpu == nil && $0.missingCPUCount == 1 })
}

@Test func unreadableUserMembershipCannotBecomeACompleteHistoryTotal() {
  var sample = ProcessSample(
    id: .init(pid: 990000, seconds: 1), parent: 1, uid: 501, path: "/example/node")
  sample.footprint = 100
  let group = ResourceGroup(
    id: "fixture", name: "Fixture",
    rows: [ProcessRow(sample: sample, cpu: 10, reasons: [], owner: "")])
  var buffer = GroupHistoryBuffer()
  buffer.record(historySnapshot(Date(), groups: [group], unreadableUsers: 1))
  #expect(buffer.frames[0].applications[0].memory == 100)
  #expect(buffer.frames[0].applications[0].cpu == 10)
  #expect(!buffer.frames[0].applications[0].membershipComplete)
}
