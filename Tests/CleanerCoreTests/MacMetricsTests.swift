import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func diskSample(
  seconds: UInt64 = 1, read: UInt64 = 100, write: UInt64 = 200,
  time: Double = 10
) -> ProcessSample {
  var sample = ProcessSample(
    id: .init(pid: 900001, seconds: seconds), parent: 1,
    uid: getuid(), path: "/opt/homebrew/bin/node")
  sample.diskIO = DiskIOCounters(readBytes: read, writtenBytes: write, measuredAt: time)
  return sample
}

struct MacMetricsTests {
  @Test func perCoreCPUDoesNotHideASingleBusyCore() {
    let old = CoreCPUSample(ticks: [[100, 0, 0, 100], [100, 0, 0, 100]], measuredAt: 1)
    let current = CoreCPUSample(ticks: [[200, 0, 0, 100], [100, 0, 0, 200]], measuredAt: 2)
    #expect(current.usage(since: old) == [100, 0])
    #expect(current.usage(since: nil) == [nil, nil])
    #expect(current.usage(since: current) == [nil, nil])
    let reset = CoreCPUSample(ticks: [[1, 0, 0, 101], [100, 0, 0, 200]], measuredAt: 2)
    #expect(reset.usage(since: old) == [nil, 0])
    let changedCores = CoreCPUSample(ticks: [[200, 0, 0, 100]], measuredAt: 2)
    #expect(changedCores.usage(since: old) == [nil])
  }

  @Test func pressureFallbackNeverInventsNormalBeforeAnEvent() {
    let unknown = MemoryPressureReading.resolve(kernel: -1, event: nil)
    #expect(unknown.value == nil)
    #expect(unknown.source == .unavailable)
    let warning = MemoryPressureReading.resolve(kernel: -1, event: 2)
    #expect(warning.value == 2)
    #expect(warning.source == .dispatchEvent)
    #expect(MemoryPressureReading.resolve(kernel: 4, event: 1).value == 4)
    #expect(MemoryPressureReading.resolve(kernel: 0, event: 0).value == nil)
  }

  @Test func diskRatesUseActualSampleTimes() throws {
    let old = diskSample()
    let next = diskSample(read: 300, write: 600, time: 12)
    let rates = try #require(DiskActivity.between(old, next))
    #expect(rates.readBytesPerSecond == 100)
    #expect(rates.writtenBytesPerSecond == 200)
    #expect(rates.interval == 2)
    #expect(rates.measuredAt == 12)
  }

  @Test func invalidDiskMeasurementsRemainUnknown() {
    let old = diskSample()
    #expect(DiskActivity.between(nil, old) == nil)
    #expect(DiskActivity.between(old, diskSample(seconds: 2, time: 12)) == nil)
    #expect(DiskActivity.between(old, diskSample(read: 99, time: 12)) == nil)
    #expect(DiskActivity.between(old, diskSample(write: 199, time: 12)) == nil)
    #expect(DiskActivity.between(old, diskSample(time: 10)) == nil)
    #expect(DiskActivity.between(old, diskSample(time: .infinity)) == nil)
    var missing = diskSample(time: 12)
    missing.diskIO = nil
    #expect(DiskActivity.between(old, missing) == nil)
    #expect(DiskActivity.between(missing, old) == nil)
  }

  @Test func zeroDiskActivityIsMeasuredNotMissing() throws {
    let rates = try #require(DiskActivity.between(diskSample(), diskSample(time: 11)))
    #expect(rates.readBytesPerSecond == 0)
    #expect(rates.writtenBytesPerSecond == 0)
  }

  @Test func resettingProcessBaselineAlsoResetsDiskRate() {
    var hot: [ProcessIdentity: Int] = [:]
    let old = diskSample()
    let current = diskSample(read: 300, time: 12)
    let first = ProcessMonitor.rows([current], previous: [old.id: old], elapsed: 2, hotCounts: &hot)
    #expect(first.first?.diskActivity != nil)
    let resumed = ProcessMonitor.rows([current], previous: [:], elapsed: 0, hotCounts: &hot)
    #expect(resumed.first?.diskActivity == nil)
  }

  @Test func thermalContextDoesNotInventMissingValues() {
    #expect(MacResourceContext.unavailable.thermal == .unknown)
    #expect(MacResourceContext.unavailable.lowPowerMode == nil)
    #expect(MacResourceContext.unavailable.measuredAt == nil)
    #expect(MacThermalState(.nominal) == .nominal)
    #expect(!MacThermalState(.fair).isConstrained)
    #expect(MacThermalState(.serious).isConstrained)
    #expect(MacThermalState(.critical).isConstrained)
    let current = MacResourceContext.capture()
    #expect(current.measuredAt != nil)
    #expect(current.lowPowerMode != nil)
  }

  @Test func listenerURLsHandleBothFamilies() {
    let identity = ProcessIdentity(pid: 1, seconds: 1)
    let v4 = LocalListener(identity: identity, host: "127.0.0.1", port: 11434, generation: 1)
    let v6 = LocalListener(identity: identity, host: "::1", port: 8080, generation: 2)
    #expect(v4.url?.absoluteString == "http://127.0.0.1:11434")
    #expect(v6.url?.absoluteString == "http://[::1]:8080")
    #expect(
      v4.id != LocalListener(identity: identity, host: v4.host, port: v4.port, generation: 2).id)
  }
}
