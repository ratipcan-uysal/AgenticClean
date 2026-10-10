import Foundation
import Testing
@testable import CleanerCore

struct WorkExplanationTests {
  private func point(_ seconds: Double, cpu: Double? = nil, pressure: Double? = 1, segment: Int = 0) -> HistoryPoint {
    HistoryPoint(id: UUID(), date: Date(timeIntervalSince1970: seconds), segment: segment,
      cpu: cpu, pressure: pressure, swapIn: nil, swapOut: nil)
  }
  @Test func cpuNeedsSustainedEvidenceAndGapsBreakIt() {
    #expect(PressureEpisode.collect(points: [point(0,cpu:90),point(10,cpu:90)], frames: []).isEmpty)
    #expect(PressureEpisode.collect(points: [point(0,cpu:90),point(15,cpu:90)], frames: []).count == 1)
    #expect(PressureEpisode.collect(points: [point(0,cpu:90),point(15,cpu:90,segment:1)], frames: []).isEmpty)
    #expect(PressureEpisode.collect(points: [point(0,cpu:90),point(10),point(20,cpu:90)], frames: []).isEmpty)
  }
  @Test func memoryUnknownIsNotNormalAndNeverBorrowsCurrentUsage() {
    let frame = GroupHistoryFrame(id: UUID(), date: Date(timeIntervalSince1970: 100), segment: 0,
      applications: [], projects: [])
    let events = PressureEpisode.collect(points: [point(0,pressure:2),point(5,pressure:nil),point(10,pressure:4)], frames: [frame])
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.applications.isEmpty && $0.evidenceDate == nil })
    #expect(events.first?.peak == 4)
  }
  @Test func runtimeDoesNotInventFrameworkOrProject() {
    let sample = ProcessSample(id: .init(pid: 999001, seconds: 20), parent: 1, uid: 501, path: "/opt/homebrew/bin/node")
    let row = ProcessRow(sample: sample, cpu: 0, reasons: [], owner: "Codex")
    #expect(WorkRole.identify(row) == .runtime)
    #expect(row.project == nil)
    let model = ProcessSample(id: sample.id, parent: 1, uid: 501, path: "/opt/homebrew/bin/llama-server")
    #expect(WorkRole.identify(ProcessRow(sample: model, cpu: 0, reasons: [], owner: "Codex")) == .localAI)
  }
}
