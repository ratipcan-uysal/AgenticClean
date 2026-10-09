import Dispatch
import Foundation
import ProcessKit
import os

public struct CoreCPUSample: Sendable {
  public let ticks: [[UInt32]]
  public let measuredAt: Double
  public init(ticks: [[UInt32]], measuredAt: Double) {
    self.ticks = ticks
    self.measuredAt = measuredAt
  }
  public func usage(since previous: Self?) -> [Double?] {
    guard let previous, measuredAt.isFinite, previous.measuredAt.isFinite,
      measuredAt > previous.measuredAt, ticks.count == previous.ticks.count
    else { return ticks.map { _ in nil } }
    return zip(ticks, previous.ticks).map { current, old in
      guard current.count == 4, old.count == 4,
        zip(current, old).allSatisfy({ $0 >= $1 || ($1 > 0xF000_0000 && $0 < 0x1000_0000) })
      else { return nil }
      let delta = zip(current, old).map { Double($0 &- $1) }
      let total = delta.reduce(0, +)
      return total > 0 ? (1 - delta[3] / total) * 100 : nil
    }
  }
  public static func capture() -> Self? {
    var raw = [CleanerCoreTicks](repeating: CleanerCoreTicks(), count: 256)
    let count = raw.withUnsafeMutableBufferPointer {
      cleaner_core_ticks($0.baseAddress, Int32($0.count))
    }
    guard count > 0 else { return nil }
    return Self(
      ticks: raw.prefix(Int(count)).map { [$0.user, $0.system, $0.nice, $0.idle] },
      measuredAt: ProcessInfo.processInfo.systemUptime)
  }
}

public enum MemoryPressureSource: String, Sendable {
  case kernelSnapshot, dispatchEvent, unavailable
}
public struct MemoryPressureReading: Sendable {
  public let value: Int?
  public let source: MemoryPressureSource
  public static func resolve(kernel: Int, event: Int?) -> Self {
    // The existing kernel snapshot is isolated here. Dispatch cannot provide an initial level.
    if [1, 2, 4].contains(kernel) { return Self(value: kernel, source: .kernelSnapshot) }
    if let event, [1, 2, 4].contains(event) { return Self(value: event, source: .dispatchEvent) }
    return Self(value: nil, source: .unavailable)
  }
}

/// The lock protects the sole mutable value; Dispatch manages its own thread-safe source lifecycle.
final class MemoryPressureEvents: @unchecked Sendable {
  private let value = OSAllocatedUnfairLock<Int?>(initialState: nil)
  private let source: any DispatchSourceMemoryPressure
  var latest: Int? { value.withLock { $0 } }
  init() {
    source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical],
      queue: .global(qos: .utility))
    let value = self.value
    source.setEventHandler { [weak self] in
      guard let flags = self?.source.data else { return }
      let level: Int? =
        flags.contains(.critical)
        ? 4 : flags.contains(.warning) ? 2 : flags.contains(.normal) ? 1 : nil
      value.withLock { $0 = level }
    }
    source.activate()
  }
  deinit { source.cancel() }
}
