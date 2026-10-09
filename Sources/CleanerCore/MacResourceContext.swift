import Foundation

/// Kernel disk accounting, not file-access volume or device latency.
public struct DiskIOCounters: Equatable, Sendable {
  public let readBytes: UInt64
  public let writtenBytes: UInt64
  public let measuredAt: Double
  public init(readBytes: UInt64, writtenBytes: UInt64, measuredAt: Double) {
    self.readBytes = readBytes
    self.writtenBytes = writtenBytes
    self.measuredAt = measuredAt
  }
}

public struct DiskActivity: Equatable, Sendable {
  public let readBytesPerSecond: Double
  public let writtenBytesPerSecond: Double
  public let interval: Double
  public let measuredAt: Double

  /// Identity and counter checks prevent PID reuse or reset from becoming a false spike.
  public static func between(_ previous: ProcessSample?, _ current: ProcessSample) -> Self? {
    guard let previous, previous.id == current.id,
      let old = previous.diskIO, let new = current.diskIO,
      old.measuredAt.isFinite, new.measuredAt.isFinite,
      new.measuredAt > old.measuredAt,
      new.readBytes >= old.readBytes, new.writtenBytes >= old.writtenBytes
    else { return nil }
    let interval = new.measuredAt - old.measuredAt
    return Self(
      readBytesPerSecond: Double(new.readBytes - old.readBytes) / interval,
      writtenBytesPerSecond: Double(new.writtenBytes - old.writtenBytes) / interval,
      interval: interval, measuredAt: new.measuredAt)
  }
}

public enum MacThermalState: String, Sendable {
  case nominal, fair, serious, critical, unknown

  public init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal: self = .nominal
    case .fair: self = .fair
    case .serious: self = .serious
    case .critical: self = .critical
    @unknown default: self = .unknown
    }
  }
  public var isConstrained: Bool { self == .serious || self == .critical }
}

/// Public macOS context only; does not estimate watts, temperatures or lost performance.
public struct MacResourceContext: Sendable {
  public let thermal: MacThermalState
  public let lowPowerMode: Bool?
  public let measuredAt: Double?
  public static let unavailable = Self(thermal: .unknown, lowPowerMode: nil, measuredAt: nil)
  public init(thermal: MacThermalState, lowPowerMode: Bool?, measuredAt: Double?) {
    self.thermal = thermal
    self.lowPowerMode = lowPowerMode
    self.measuredAt = measuredAt
  }
  public static func capture() -> Self {
    let info = ProcessInfo.processInfo
    return Self(
      thermal: MacThermalState(info.thermalState),
      lowPowerMode: info.isLowPowerModeEnabled, measuredAt: info.systemUptime)
  }
}
