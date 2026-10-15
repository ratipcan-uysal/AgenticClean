import Foundation
import Observation

public enum SimulatorStorageAction: String, Sendable, CaseIterable {
  case erase, delete
}
public enum SimulatorStorageStatus: Sendable, Equatable {
  case completed, blocked, changed, missing, unverified, cancelled
}
public struct SimulatorStorageResult: Identifiable, Sendable {
  public let device: SimulatorDevice
  public let action: SimulatorStorageAction
  public let status: SimulatorStorageStatus
  public let detail: String?
  public var id: String { device.id }
  public init(device: SimulatorDevice, action: SimulatorStorageAction,
              status: SimulatorStorageStatus, detail: String? = nil) {
    self.device = device; self.action = action; self.status = status; self.detail = detail
  }
}
public struct SimulatorStoragePlan: Identifiable, Sendable {
  public let id = UUID()
  public let action: SimulatorStorageAction
  public let devices: [SimulatorDevice]
  public var measuredBytes: UInt64? { totalMeasured(devices) }
  public var unknownSizeCount: Int { devices.filter { $0.measuredBytes == nil }.count }
}
public protocol SimulatorStorageService: Sendable {
  func inventory() async throws -> [SimulatorDevice]
  func clean(_ device: SimulatorDevice, action: SimulatorStorageAction) async -> SimulatorStorageResult
}
public struct NativeSimulatorStorageService: SimulatorStorageService {
  public init() {}
  public func inventory() async throws -> [SimulatorDevice] { try await SimulatorControl.inventory() }
  public func clean(_ device: SimulatorDevice, action: SimulatorStorageAction) async -> SimulatorStorageResult {
    await SimulatorControl.clean(device, action: action)
  }
}

/// Shared by both entry points. No timer or persisted selection; refreshed only
/// on explicit entry/refresh and after actions. The view never owns a running batch.
@MainActor @Observable public final class SimulatorStorage {
  public private(set) var devices: [SimulatorDevice] = []
  public private(set) var date: Date?
  public private(set) var error: String?
  public private(set) var loading = false
  public private(set) var running = false
  public private(set) var cancellationRequested = false
  public private(set) var currentDevice: String?
  public private(set) var results: [SimulatorStorageResult] = []
  public private(set) var plan: SimulatorStoragePlan?
  public private(set) var checked = Set<String>()
  @ObservationIgnored private let service: any SimulatorStorageService
  @ObservationIgnored private var batch: Task<Void, Never>?
  public init(service: any SimulatorStorageService = NativeSimulatorStorageService()) { self.service = service }
  public var measuredBytes: UInt64? { totalMeasured(devices) }
  public var unknownSizeCount: Int { devices.filter { $0.measuredBytes == nil }.count }
  public var selected: [SimulatorDevice] { devices.filter { checked.contains($0.id) && $0.canReviewStorage } }
  public func select(_ device: SimulatorDevice, checked value: Bool) {
    guard !running, !loading, plan == nil, error == nil, device.canReviewStorage,
      devices.contains(device) else { return }
    if value { checked.insert(device.id) } else { checked.remove(device.id) }
  }
  public func refresh() async {
    guard !running, !loading, plan == nil else { return }
    loading = true
    checked = []
    defer { loading = false }
    do {
      let value = try await service.inventory()
      guard !Task.isCancelled else { return }
      devices = value; date = Date(); error = nil
    } catch {
      devices = []; date = nil; self.error = error.localizedDescription
    }
  }
  public func review(_ action: SimulatorStorageAction) {
    guard !running, !loading, plan == nil, error == nil, !selected.isEmpty else { return }
    plan = SimulatorStoragePlan(action: action, devices: selected)
  }
  public func dismissReview() { if !running { plan = nil } }
  public func confirm(_ approved: SimulatorStoragePlan) {
    guard !running, !loading, plan?.id == approved.id else { return }
    running = true; cancellationRequested = false; results = []; checked = []; plan = nil
    batch = Task { [self, service] in
      for device in approved.devices {
        if cancellationRequested {
          results.append(.init(device: device, action: approved.action, status: .cancelled))
          continue
        }
        currentDevice = device.name
        results.append(await service.clean(device, action: approved.action))
      }
      currentDevice = nil
      do { devices = try await service.inventory(); date = Date(); error = nil }
      catch { devices = []; date = nil; self.error = error.localizedDescription }
      running = false; cancellationRequested = false; batch = nil
    }
  }
  /// Finish the in-flight device; stop before submitting the next one.
  public func cancelRemaining() { if running { cancellationRequested = true } }
  public func waitForBatch() async { await batch?.value }
}

private func totalMeasured(_ devices: [SimulatorDevice]) -> UInt64? {
  if devices.isEmpty { return 0 }
  let values = devices.compactMap(\.measuredBytes)
  guard !values.isEmpty else { return nil }
  var total: UInt64 = 0
  for value in values {
    let (next, overflow) = total.addingReportingOverflow(value)
    guard !overflow else { return nil }
    total = next
  }
  return total
}
