import Foundation
import Testing
@testable import CleanerCore

@Test(arguments: [(UInt64(40), UInt64(45), Int64(5)), (40, 40, 0), (40, 35, -5)])
func diskSpaceChangeReportsSignedWholeVolumeDifference(start: UInt64, end: UInt64, expected: Int64) {
  let before = DiskVolumeSample(capacity: 100, available: start, volumeID: "data")
  let after = DiskVolumeSample(capacity: 100, available: end, volumeID: "data")
  #expect(DiskSpaceChange(before: before, after: after).netBytes == expected)
}

@Test func diskSpaceChangeRequiresComparableMeasurements() {
  let before = DiskVolumeSample(capacity: 100, available: 40, volumeID: "data")
  for after in [nil,
    DiskVolumeSample(capacity: 100, available: 45, volumeID: nil),
    DiskVolumeSample(capacity: 100, available: 45, volumeID: "another-volume"),
    DiskVolumeSample(capacity: 200, available: 45, volumeID: "data"),
    DiskVolumeSample(capacity: UInt64.max, available: UInt64.max, volumeID: "data"),
  ] {
    #expect(DiskSpaceChange(before: before, after: after).netBytes == nil)
  }
  #expect(DiskSpaceChange(before: nil, after: before).netBytes == nil)
}

private actor DelayedVolumeRead {
  var calls = 0
  var firstStarted: CheckedContinuation<Void, Never>?
  var finishFirst: CheckedContinuation<DiskVolumeSample?, Never>?
  func read() async -> DiskVolumeSample? {
    calls += 1
    if calls == 1 {
      return await withCheckedContinuation {
        finishFirst = $0; firstStarted?.resume(); firstStarted = nil
      }
    }
    if calls == 2 { return DiskVolumeSample(capacity: 100, available: 45, volumeID: "data") }
    return nil
  }
  func waitForFirst() async {
    if finishFirst != nil { return }
    await withCheckedContinuation { firstStarted = $0 }
  }
  func unblock() {
    finishFirst?.resume(returning: DiskVolumeSample(capacity: 100, available: 40, volumeID: "data"))
    finishFirst = nil
  }
}

@Test @MainActor func diskVolumeRejectsLateReadAndClearsFailedMeasurement() async {
  let reader = DelayedVolumeRead()
  let volume = DiskVolume { await reader.read() }
  let first = Task { await volume.refresh() }
  await reader.waitForFirst()
  #expect(volume.refreshing)
  await volume.refresh()
  #expect(volume.sample?.available == 45 && !volume.refreshing)
  await reader.unblock(); _ = await first.value
  #expect(volume.sample?.available == 45)
  await volume.refresh()
  #expect(volume.sample == nil && !volume.refreshing)
}
