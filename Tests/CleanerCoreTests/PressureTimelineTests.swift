import Foundation
import Testing
@testable import CleanerCore

struct PressureTimelineTests {
  private func point(_ time: Double, _ pressure: Double?, segment: Int = 0) -> HistoryPoint {
    HistoryPoint(id: UUID(), date: Date(timeIntervalSince1970: time), segment: segment,
      cpu: nil, pressure: pressure, swapIn: nil, swapOut: nil)
  }
  @Test func sustainedPressureUsesOnlyObservedTime() {
    let timeline = PressureTimeline(points: [point(0, 2), point(60, 2), point(120, 2)])
    #expect(timeline.currentDuration == 120)
    #expect(timeline.intervals.count == 2)
    #expect(!timeline.hasMissingReadings)
    #expect(!PressureTimeline(points: [point(0, 2)]).hasMissingReadings)
    #expect(!PressureTimeline(points: []).hasMissingReadings)
    #expect(!PressureTimeline(points: [point(0, nil), point(1, 1, segment: 1)]).hasMissingReadings)
    #expect(PressureTimeline(points: [point(0, 2)]).currentDuration == 0)
  }
  @Test func gapsAndSamplingRestartsBreakDuration() {
    let missing = PressureTimeline(points: [point(0, 2), point(60, nil), point(120, 2)])
    #expect(missing.intervals.isEmpty)
    #expect(missing.hasMissingReadings)
    #expect(missing.currentDuration == 0)
    let resumed = PressureTimeline(points: [point(0, 2), point(60, 2, segment: 1)])
    #expect(resumed.intervals.isEmpty)
    #expect(resumed.hasMissingReadings)
    #expect(resumed.currentDuration == 0)
    #expect(PressureTimeline(points: [point(0, nil)]).currentDuration == nil)
  }
  @Test func transitionsRetainTheirOwnColorsAndResetDuration() {
    let timeline = PressureTimeline(points: [point(0, 1), point(60, 2), point(120, 4), point(180, 4)])
    #expect(timeline.intervals.map(\.level) == [1, 2, 4])
    #expect(timeline.currentDuration == 60)
  }
}
