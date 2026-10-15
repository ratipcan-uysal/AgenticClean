import Foundation
import Observation

public struct DiskVolumeSample: Sendable, Equatable {
  public let capacity: UInt64
  public let available: UInt64
  public let volumeID: String?
  public let date: Date
  public init(capacity: UInt64, available: UInt64, volumeID: String?, date: Date = Date()) {
    self.capacity = capacity; self.available = available; self.volumeID = volumeID; self.date = date
  }
}

/// A whole-volume observation, never an attribution of recovered bytes to one action.
public struct DiskSpaceChange: Sendable {
  public let before: DiskVolumeSample?
  public let after: DiskVolumeSample?
  public init(before: DiskVolumeSample?, after: DiskVolumeSample?) {
    self.before = before; self.after = after
  }
  public var netBytes: Int64? {
    guard let before, let after, let id = before.volumeID, id == after.volumeID,
      before.capacity == after.capacity,
      let start = Int64(exactly: before.available), let end = Int64(exactly: after.available)
    else { return nil }
    return end - start
  }
}

/// Shared by project cleanup and simulator actions. Explicit reads only; no polling.
@MainActor @Observable public final class DiskVolume {
  public private(set) var sample: DiskVolumeSample?
  public private(set) var refreshing = false
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private let read: @Sendable () async -> DiskVolumeSample?
  public init(read: @escaping @Sendable () async -> DiskVolumeSample? = { await DiskVolume.readHomeVolume() }) {
    self.read = read
  }
  @discardableResult public func refresh() async -> DiskVolumeSample? {
    revision &+= 1
    let requested = revision
    refreshing = true
    let value = await read()
    // A delayed old read must not replace a newer post-action measurement.
    if requested == revision {
      sample = value; refreshing = false
    }
    return value
  }
  @concurrent public static func readHomeVolume() async -> DiskVolumeSample? {
    var url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    url.removeAllCachedResourceValues()
    guard let values = try? url.resourceValues(forKeys: [
      .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeUUIDStringKey,
    ]), let total = values.volumeTotalCapacity, total > 0,
      let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
    return DiskVolumeSample(capacity: UInt64(total), available: UInt64(available),
      volumeID: values.volumeUUIDString)
  }
}
