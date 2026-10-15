import Foundation
import Testing
@testable import CleanerCore

private let simA = "00000000-0000-0000-0000-000000000011"
private let simB = "00000000-0000-0000-0000-000000000012"
private let simC = "00000000-0000-0000-0000-000000000013"
private let simRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
private func storageDevice(_ id: String, state: String = "Shutdown", bytes: UInt64? = 100) -> SimulatorDevice {
  var device = SimulatorDevice(udid: id, name: "QA " + id.suffix(2), state: state)
  device.runtime = simRuntime; device.dataPath = "/synthetic/devices/" + id + "/data"
  device.deviceTypeIdentifier = "synthetic.phone"; device.dataPathSize = bytes
  return device
}
private actor StorageEnvironment: SimulatorEnvironment, SimulatorStorageService {
  var rows: [SimulatorDevice]
  var commands: [[String]] = []
  var failure: CommandFailure?
  var keepAfterDelete = false
  var failAfterMutation = false
  var hold = false
  var submitted: CheckedContinuation<Void, Never>?
  var release: CheckedContinuation<Void, Never>?
  init(_ rows: [SimulatorDevice]) { self.rows = rows }
  func developerDirectory() -> String { "/Applications/Xcode.app/Contents/Developer" }
  func isExecutable(_ path: String) -> Bool { path == "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl" }
  func run(_ executable: String, arguments: [String]) async throws -> Data {
    #expect(executable == "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl")
    commands.append(arguments)
    if arguments.first == "list" {
      if failAfterMutation && commands.contains(where: { $0.first == "delete" || $0.first == "erase" }) {
        throw CommandFailure.timedOut
      }
      let values: [[String: Any]] = rows.map { row in
        var data: [String: Any] = ["udid": row.id, "name": row.name, "state": row.state]
        if let value = row.dataPath { data["dataPath"] = value }
        if let value = row.dataPathSize { data["dataPathSize"] = value }
        if let value = row.deviceTypeIdentifier { data["deviceTypeIdentifier"] = value }
        return data
      }
      return try JSONSerialization.data(withJSONObject: ["devices": [simRuntime: values]])
    }
    if hold {
      submitted?.resume(); submitted = nil
      await withCheckedContinuation { release = $0 }
    }
    if let failure { throw failure }
    if arguments.first == "delete", !keepAfterDelete { rows.removeAll { $0.id == arguments[1] } }
    if arguments.first == "erase", let index = rows.firstIndex(where: { $0.id == arguments[1] }) {
      let old = rows[index]; rows[index] = storageDevice(old.id, bytes: 0)
    }
    return Data()
  }
  func inventory() async throws -> [SimulatorDevice] { try await SimulatorControl.inventory(environment: self) }
  func clean(_ device: SimulatorDevice, action: SimulatorStorageAction) async -> SimulatorStorageResult {
    await SimulatorControl.clean(device, action: action, environment: self)
  }
  func set(_ rows: [SimulatorDevice]) { self.rows = rows }
  func configure(failure: CommandFailure? = nil, keep: Bool = false, failAfter: Bool = false) {
    self.failure = failure; keepAfterDelete = keep; failAfterMutation = failAfter
  }
  func prepareBarrier() { hold = true }
  func waitUntilSubmitted() async {
    if commands.contains(where: { $0.first == "delete" || $0.first == "erase" }) { return }
    await withCheckedContinuation { submitted = $0 }
  }
  func unblock() { hold = false; release?.resume(); release = nil }
  var mutations: [[String]] { commands.filter { $0.first == "delete" || $0.first == "erase" } }
}

@Test func storageInventoryIncludesClosedDevicesAndUnknownMetadataWithoutGuessing() async throws {
  let env = StorageEnvironment([storageDevice(simA, bytes: nil), storageDevice(simB, state: "Booted", bytes: 500)])
  let devices = try await env.inventory()
  #expect(devices.map(\.id) == [simB, simA])
  #expect(devices[0].runtime == simRuntime && devices[0].measuredBytes == 500)
  #expect(devices[1].measuredBytes == nil && devices[1].lastUsedAt == nil)
  #expect(!devices[0].canReviewStorage && devices[1].canReviewStorage)
  #expect(await env.commands == [["list", "devices", "--json"]])
}
@Test func bootedTransitioningAndMalformedDevicesCannotSubmitStorageCommands() async {
  for device in [storageDevice(simA, state: "Booted"), storageDevice(simA, state: "Creating"), storageDevice("bad-id")] {
    let env = StorageEnvironment([device])
    #expect(await env.clean(device, action: .delete).status == .blocked)
    #expect(await env.commands.isEmpty)
  }
}
@Test func deviceBootedOrChangedSinceReviewIsSkippedByFreshPreflight() async {
  let reviewed = storageDevice(simA)
  let env = StorageEnvironment([storageDevice(simA, state: "Booted")])
  #expect(await env.clean(reviewed, action: .delete).status == .blocked)
  var moved = storageDevice(simA); moved.dataPath = "/synthetic/replaced"
  await env.set([moved])
  #expect(await env.clean(reviewed, action: .erase).status == .changed)
  await env.set([])
  #expect(await env.clean(reviewed, action: .delete).status == .missing)
  #expect(await env.mutations.isEmpty)
}
@Test func deleteTargetsOneExactIDAndVerifiesItsAbsence() async throws {
  let a = storageDevice(simA), b = storageDevice(simB)
  let env = StorageEnvironment([a, b])
  #expect(await env.clean(a, action: .delete).status == .completed)
  #expect(await env.mutations == [["delete", simA]])
  #expect(try await env.inventory().map(\.id) == [simB])
}
@Test func eraseKeepsDeviceAndDoesNotInvokeDeleteOrShutdown() async throws {
  let a = storageDevice(simA), env = StorageEnvironment([storageDevice(simA)])
  #expect(await env.clean(a, action: .erase).status == .completed)
  #expect(await env.mutations == [["erase", simA]])
  #expect(try await env.inventory().first?.id == simA)
}
@Test func commandAcknowledgementWithoutVerifiedInventoryIsNotReportedAsSuccess() async {
  let a = storageDevice(simA), env = StorageEnvironment([storageDevice(simA)])
  await env.configure(keep: true)
  #expect(await env.clean(a, action: .delete).status == .unverified)
  await env.configure(failAfter: true)
  #expect(await env.clean(a, action: .erase).status == .unverified)
}
@Test func timeoutHasUnverifiedOutcomeWithoutAutomaticRetry() async {
  let a = storageDevice(simA), env = StorageEnvironment([storageDevice(simA)])
  await env.configure(failure: .timedOut)
  #expect(await env.clean(a, action: .delete).status == .unverified)
  #expect(await env.mutations.count == 1)
}
@Test @MainActor func reviewStartsUncheckedCancelDoesNothingAndRefreshClearsSelection() async {
  let a = storageDevice(simA), env = StorageEnvironment([storageDevice(simA)])
  let model = SimulatorStorage(service: env)
  await model.refresh()
  #expect(model.checked.isEmpty)
  model.select(a, checked: true); model.review(.delete)
  #expect(model.plan?.devices == [a])
  model.dismissReview()
  #expect(await env.mutations.isEmpty)
  await model.refresh()
  #expect(model.checked.isEmpty && model.plan == nil)
}
@Test @MainActor func reviewedBatchIsFrozenAndDoubleConfirmationCannotResubmit() async throws {
  let a = storageDevice(simA), b = storageDevice(simB), env = StorageEnvironment([storageDevice(simA), storageDevice(simB)])
  let model = SimulatorStorage(service: env)
  await model.refresh(); model.select(a, checked: true); model.review(.delete)
  let plan = try #require(model.plan)
  model.select(b, checked: true)
  await model.refresh() // A review's identity cannot be silently replaced.
  model.confirm(plan); model.confirm(plan)
  await model.waitForBatch()
  model.confirm(plan)
  #expect(model.results.count == 1 && model.results.first?.status == .completed)
  #expect(model.devices.map(\.id) == [simB])
  #expect(await env.mutations == [["delete", simA]])
}
@Test @MainActor func batchKeepsPerDeviceOutcomesWhenOneDeviceBecameActive() async throws {
  let a = storageDevice(simA), b = storageDevice(simB), env = StorageEnvironment([storageDevice(simA), storageDevice(simB)])
  let model = SimulatorStorage(service: env)
  await model.refresh(); model.select(a, checked: true); model.select(b, checked: true); model.review(.delete)
  let plan = try #require(model.plan)
  await env.set([storageDevice(simA, state: "Booted"), b])
  model.confirm(plan); await model.waitForBatch()
  #expect(model.results.map(\.status) == [.blocked, .completed])
  #expect(await env.mutations == [["delete", simB]])
}
@Test @MainActor func cancelRemainingWaitsForSubmittedDeviceAndDoesNotSubmitAnother() async throws {
  let a = storageDevice(simA), b = storageDevice(simB), env = StorageEnvironment([storageDevice(simA), storageDevice(simB)])
  let model = SimulatorStorage(service: env)
  await model.refresh(); model.select(a, checked: true); model.select(b, checked: true); model.review(.delete)
  let plan = try #require(model.plan)
  await env.prepareBarrier()
  model.confirm(plan)
  await env.waitUntilSubmitted()
  model.cancelRemaining()
  #expect(model.running && model.results.isEmpty)
  await env.unblock(); await model.waitForBatch()
  #expect(model.results.map(\.status) == [.completed, .cancelled])
  #expect(!model.running && model.checked.isEmpty)
  #expect(await env.mutations == [["delete", simA]])
}

@Test @MainActor func storageMeasurementsNeverTurnAnUnknownTotalIntoZeroOrOverflow() async throws {
  let a = storageDevice(simA, bytes: nil), env = StorageEnvironment([storageDevice(simA, bytes: nil)])
  let model = SimulatorStorage(service: env)
  await model.refresh(); model.select(a, checked: true); model.review(.erase)
  #expect(model.measuredBytes == nil && model.unknownSizeCount == 1)
  #expect(model.plan?.measuredBytes == nil && model.plan?.unknownSizeCount == 1)
  model.dismissReview()
  await env.set([storageDevice(simA, bytes: UInt64.max), storageDevice(simB, bytes: 1)])
  await model.refresh()
  #expect(model.measuredBytes == nil)
  await env.set([])
  await model.refresh()
  #expect(model.measuredBytes == 0)
}
