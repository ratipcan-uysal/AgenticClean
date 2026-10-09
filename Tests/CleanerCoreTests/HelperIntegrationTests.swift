import Darwin
import Foundation
import Testing

@testable import CleanerCore

@concurrent private func disposableSleep(ignoringTerm: Bool = false) async throws -> (Process, URL)
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cleaner-helper-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("node")
  let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/process-helper.c")
  _ = try await CommandRunner.run(
    executable: "/usr/bin/clang", arguments: [source.path, "-o", executable.path])
  let ready = directory.appendingPathComponent("ready")
  let child = Process()
  child.executableURL = executable
  child.arguments = [ignoringTerm ? "ignore-term" : "normal", ready.path]
  try child.run()
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while !FileManager.default.fileExists(atPath: ready.path), child.isRunning,
    ProcessInfo.processInfo.systemUptime < deadline
  {
    try await Task.sleep(for: .milliseconds(10))
  }
  guard FileManager.default.fileExists(atPath: ready.path) else {
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: directory)
    throw MonitorError.message("Test helper did not become ready")
  }
  return (child, directory)
}
@Test func onlyOwnedDisposableProcessIsStoppedAndPresenceVerified() async throws {
  let (child, directory) = try await disposableSleep()
  defer {
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: directory)
  }
  let sample = try #require(ProcessMonitor.read(child.processIdentifier))
  #expect(ProcessMonitor.presence(sample.id) == .sameIdentity)
  #expect(
    ProcessMonitor.presence(.init(pid: sample.id.pid, seconds: sample.id.seconds + 1))
      == .differentIdentity)
  try await MonitorActions.stop(sample)
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(!child.isRunning)
  #expect(ProcessMonitor.presence(sample.id) == .absent)
}
@Test @MainActor func ignoredTERMFinishesDashboardOperationAfterFifteenSecondsWithoutKilling()
  async throws
{
  let (child, directory) = try await disposableSleep(ignoringTerm: true)
  defer {
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: directory)
  }
  let sample = try #require(ProcessMonitor.read(child.processIdentifier))
  var counts: [ProcessIdentity: Int] = [:]
  let rows = ProcessMonitor.rows([sample], previous: [:], elapsed: 0, hotCounts: &counts)
  let value = Snapshot(
    date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interval: 5, duration: 0,
    system: SystemSample(ticks: nil, memory: nil), swap: nil, cpu: nil, paging: nil, rows: rows,
    applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: .partial, sustainedCPU: false)
  let model = Dashboard(
    source: FixedSource(value: value),
    defaults: UserDefaults(suiteName: "CleanerHelper." + UUID().uuidString)!)
  await model.refresh()
  model.selection = .process(sample.id)
  let start = ProcessInfo.processInfo.systemUptime
  await model.stop(rows[0])
  let duration = ProcessInfo.processInfo.systemUptime - start
  #expect(duration >= 15 && duration < 18)
  #expect(model.events.first?.state == .stillRunning)
  #expect(ProcessMonitor.presence(sample.id) == .sameIdentity)
  #expect(child.isRunning)
}
@Test func helperSuccessAndExitFailureAreReported() async throws {
  let output = try await CommandRunner.run(
    executable: "/bin/sh", arguments: ["-c", "printf cleaner-ok"])
  #expect(String(decoding: output, as: UTF8.self) == "cleaner-ok")
  do {
    _ = try await CommandRunner.run(
      executable: "/bin/sh", arguments: ["-c", "printf fixture-error; exit 42"])
    Issue.record("Nonzero exit was reported as success")
  } catch CommandFailure.exit(let code, let message) {
    #expect(code == 42 && message == "fixture-error")
  }
}
@Test func realFifteenSecondHelperTimeoutIsBoundedBelowTwenty() async throws {
  let start = ProcessInfo.processInfo.systemUptime
  do {
    _ = try await CommandRunner.run(
      executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"])
    Issue.record("Ignoring TERM helper returned success")
  } catch CommandFailure.timedOut {
    let duration = ProcessInfo.processInfo.systemUptime - start
    #expect(duration >= 17 && duration < 20)
  }
}
@Test func outputFloodCannotDefeatTimeoutOrMemoryLimit() async throws {
  let start = ProcessInfo.processInfo.systemUptime
  do {
    _ = try await CommandRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "while :; do printf abcdefghijklmnopqrstuvwxyz; done"], timeout: 0.2,
      grace: 0.1, outputLimit: 4096)
    Issue.record("Flood was reported as success")
  } catch { #expect(ProcessInfo.processInfo.systemUptime - start < 2) }
}
@Test func inheritedPipeDoesNotHoldRunnerOpenAfterChildExits() async throws {
  let start = ProcessInfo.processInfo.systemUptime
  let data = try await CommandRunner.run(
    executable: "/bin/sh", arguments: ["-c", "/bin/sleep 2 & printf done"], timeout: 0.3, grace: 0.1
  )
  #expect(String(decoding: data, as: UTF8.self) == "done")
  #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
}
@Test func cancellingHelperAlsoHasBoundedCleanup() async throws {
  let job = Task {
    try await CommandRunner.run(
      executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"], timeout: 15,
      grace: 0.1)
  }
  try await Task.sleep(for: .milliseconds(80))
  let start = ProcessInfo.processInfo.systemUptime
  job.cancel()
  do {
    _ = try await job.value
    Issue.record("Cancelled helper succeeded")
  } catch { #expect(ProcessInfo.processInfo.systemUptime - start < 1.5) }
}
@Test func engineRunsInspectionOffMainAndResetMakesBaselineUnavailable() async throws {
  let engine = MonitorEngine()
  let first = try await engine.capture()
  #expect(first.cpu == nil && first.paging == nil)
  try await Task.sleep(for: .milliseconds(100))
  let second = try await engine.capture()
  #expect(second.interval != nil)
  await engine.resetBaseline()
  let reset = try await engine.capture()
  #expect(reset.cpu == nil && reset.paging == nil)
  #expect(reset.rows.allSatisfy { $0.cpu == nil })
}

private struct FixedSource: SnapshotSource {
  let value: Snapshot
  func capture() async throws -> Snapshot { value }
  func resetBaseline() async {}
}

@Test @MainActor func projectBatchSignalsOtherHelpersBeforeWaitingForResistantOne() async throws {
  let (resistant, firstDirectory) = try await disposableSleep(ignoringTerm: true)
  defer {
    if resistant.isRunning { kill(resistant.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: firstDirectory)
  }
  let (normal, secondDirectory) = try await disposableSleep()
  defer {
    if normal.isRunning { kill(normal.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: secondDirectory)
  }
  let rows = try [resistant, normal].map { child in
    var sample = try #require(ProcessMonitor.read(child.processIdentifier))
    let cwd: String = try #require(ProcessMonitor.workingDirectory(sample))
    sample.cwd = cwd
    var row = ProcessRow(
      sample: sample, cpu: 0, reasons: [], owner: "Fixture",
      project: ProjectHint(
        path: cwd, sourcePID: sample.id.pid, inherited: false, hasProjectMarker: true))
    row.applicationKey = "fixture"
    row.applicationName = "Fixture"
    return row
  }
  let value = Snapshot(
    date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interval: 30, duration: 0,
    system: SystemSample(ticks: nil, memory: nil), swap: nil, cpu: nil, paging: nil, rows: rows,
    applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows),
    unreadableCount: 0, quality: .partial, sustainedCPU: false)
  let model = Dashboard(
    source: FixedSource(value: value),
    defaults: UserDefaults(suiteName: "ProjectHelpers." + UUID().uuidString)!)
  await model.refresh()
  let app = try #require(model.presentation.applications.first)
  let project = try #require(app.projects.first)
  let key = app.projectKey(project)
  model.selection = .group(key)
  let plan = try #require(model.projectStopPlan(for: key))
  #expect(plan.targets.count == 2)
  let job = Task { try await model.stopProject(plan) }
  try await Task.sleep(for: .seconds(1))
  #expect(!normal.isRunning)
  #expect(resistant.isRunning)
  try await job.value
  #expect(model.events.first { $0.process == rows[0].id }?.state == .stillRunning)
  #expect(model.events.first { $0.process == rows[1].id }?.state == .closed)
  #expect(resistant.isRunning)
}
@Test func projectStopRechecksActualWorkingDirectoryBeforeSignal() async throws {
  let (child, directory) = try await disposableSleep()
  defer {
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: directory)
  }
  var sample = try #require(ProcessMonitor.read(child.processIdentifier))
  sample.cwd = "/this-is-not-the-helper-directory"
  do {
    try await NativeProjectProcessActions().stop(sample)
    Issue.record("Changed working directory was not rejected")
  } catch {}
  #expect(child.isRunning)
}

@Test func nativeTrashRoundTripTouchesOnlyItsOwnDisposableFolder() async throws {
  let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("Cleaner-Disposable-Trash-" + UUID().uuidString, isDirectory: true)
  let payload = folder.appendingPathComponent("fixture.txt")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  try Data("disposable Cleaner verification fixture".utf8).write(to: payload)
  defer { try? FileManager.default.removeItem(at: folder) }
  let destination = try SystemCacheTrashService().moveToTrash(folder)
  // Restore only the exact item returned by macOS. Never enumerate or empty the user's Trash.
  defer {
    if FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.moveItem(at: destination, to: folder)
      try? FileManager.default.removeItem(at: folder)
    }
  }
  #expect(!FileManager.default.fileExists(atPath: folder.path))
  #expect(
    try String(contentsOf: destination.appendingPathComponent("fixture.txt"), encoding: .utf8)
      == "disposable Cleaner verification fixture")
  try FileManager.default.moveItem(at: destination, to: folder)
  #expect(FileManager.default.fileExists(atPath: payload.path))
}
