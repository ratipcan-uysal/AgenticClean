import Darwin
import Foundation
import Testing
@testable import CleanerCore

private struct WebTrash: CacheTrashService {
  let root: URL
  let fail: Bool
  func moveToTrash(_ url: URL) throws -> URL {
    if fail { throw CacheCleanupFailure.message("fixture trash unavailable") }
    let target = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: url, to: target)
    return target
  }
}
private final class WebClock: @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: TimeInterval = 0
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
  func expire() { lock.lock(); seconds = 121; lock.unlock() }
}
private struct WebFixture {
  let base: URL
  let project: URL
  let output: URL
  let marker: URL
  let provider: CleanupProvider
  init(_ provider: CleanupProvider) throws {
    self.provider = provider
    base = URL(fileURLWithPath: "/private/tmp/AgenticWeb-" + UUID().uuidString)
    project = base.appendingPathComponent("Source")
    output = project.appendingPathComponent(provider == .next ? ".next/cache" : "node_modules/.vite")
    marker = project.appendingPathComponent(provider == .next ? ".next/build-manifest.json" : "node_modules/.vite/deps/_metadata.json")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("Trash"), withIntermediateDirectories: true)
    try Data((provider == .next ? "{\"dependencies\":{\"next\":\"16\"}}" : "{\"devDependencies\":{\"vite\":\"7\"}}").utf8).write(to: project.appendingPathComponent("package.json"))
    try Data((provider == .next ? "{\"pages\":{}}" : "{\"optimized\":{}}").utf8).write(to: marker)
    try Data("cache data".utf8).write(to: output.appendingPathComponent("data"))
    try Data("source protected".utf8).write(to: project.appendingPathComponent("main.ts"))
  }
  func remove() { try? FileManager.default.removeItem(at: base) }
  func engine(complete: Bool = true, active: Bool = false, fail: Bool = false, clock: WebClock? = nil) -> CacheCleanupEngine {
    var sample = ProcessSample(id: .init(pid: 999_111, seconds: 1), parent: 1, uid: getuid(), path: "/opt/node")
    sample.cwd = project.path
    let samples = active ? [sample] : []
    return CacheCleanupEngine(root: base.appendingPathComponent("AbsentDerivedData"), trash: WebTrash(root: base.appendingPathComponent("Trash"), fail: fail), currentDate: { clock?.now() ?? Date() }, activity: { .init(samples: samples, complete: complete) })
  }
}

@Test(arguments: [CleanupProvider.next, .vite])
func webVerifiedOutputMovesWithoutSourceOrDependencies(_ provider: CleanupProvider) async throws {
  let fixture = try WebFixture(provider); defer { fixture.remove() }
  let dependency = fixture.project.appendingPathComponent("node_modules/library")
  try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
  let engine = fixture.engine()
  let plan = try await engine.scan(projectPaths: [fixture.project.path])
  let item = try #require(plan.candidates.first)
  #expect(item.provider == provider && item.path == fixture.output.path && item.blockedReason == nil)
  #expect(item.projectRoot == fixture.project.path && item.projectRoot != fixture.base.path)
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [item.id])
  #expect(result.first?.moved == true)
  #expect(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("main.ts").path))
  #expect(FileManager.default.fileExists(atPath: dependency.path))
  #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
}

@Test(arguments: [CleanupProvider.next, .vite])
func webRejectsFalseMarkersMetadataChangesAndLinks(_ provider: CleanupProvider) async throws {
  let fixture = try WebFixture(provider); defer { fixture.remove() }
  let engine = fixture.engine()
  let plan = try await engine.scan(projectPaths: [fixture.project.path])
  let item = try #require(plan.candidates.first)
  try Data("{}".utf8).write(to: fixture.marker)
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [item.id])
  #expect(result.first?.moved == false)
  let invalid = try await engine.scan(projectPaths: [fixture.project.path])
  #expect(invalid.candidates.isEmpty && invalid.exclusions.count == 1)
  try FileManager.default.removeItem(at: fixture.marker)
  let outside = fixture.base.appendingPathComponent("Outside.json")
  try Data((provider == .next ? "{\"pages\":{}}" : "{\"optimized\":{}}").utf8).write(to: outside)
  try FileManager.default.createSymbolicLink(at: fixture.marker, withDestinationURL: outside)
  let linked = try await engine.scan(projectPaths: [fixture.project.path])
  #expect(linked.candidates.isEmpty)
  #expect(FileManager.default.fileExists(atPath: fixture.output.path))
}

@Test(arguments: [CleanupProvider.next, .vite])
func webBlocksActivityExpiryAndTrashFailures(_ provider: CleanupProvider) async throws {
  let fixture = try WebFixture(provider); defer { fixture.remove() }
  for engine in [fixture.engine(complete: false), fixture.engine(active: true)] {
    let plan = try await engine.scan(projectPaths: [fixture.project.path])
    let item = try #require(plan.candidates.first)
    #expect(item.blockedReason != nil)
    let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [item.id])
    #expect(result.first?.moved == false)
  }
  let clock = WebClock(); let expired = fixture.engine(clock: clock)
  let plan = try await expired.scan(projectPaths: [fixture.project.path]); let item = try #require(plan.candidates.first)
  clock.expire()
  await #expect(throws: (any Error).self) { try await expired.moveToTrash(planID: plan.id, selectedIDs: [item.id]) }
  let failing = fixture.engine(fail: true)
  let failedPlan = try await failing.scan(projectPaths: [fixture.project.path]); let failedItem = try #require(failedPlan.candidates.first)
  let result = try await failing.moveToTrash(planID: failedPlan.id, selectedIDs: [failedItem.id])
  #expect(result.first?.error == "fixture trash unavailable")
  #expect(FileManager.default.fileExists(atPath: fixture.output.path))
}

@Test func webMissingDependencyAndZeroBudgetNeverOfferCleanup() async throws {
  let fixture = try WebFixture(.next); defer { fixture.remove() }
  let engine = fixture.engine()
  try Data("{\"dependencies\":{}}".utf8).write(to: fixture.project.appendingPathComponent("package.json"))
  let noTool = try await engine.scan(projectPaths: [fixture.project.path])
  #expect(noTool.candidates.isEmpty && noTool.exclusions.count == 1)
  try Data("{\"dependencies\":{\"next\":\"16\"}}".utf8).write(to: fixture.project.appendingPathComponent("package.json"))
  let bounded = CacheCleanupEngine(root: fixture.base.appendingPathComponent("Absent"), trash: WebTrash(root: fixture.base.appendingPathComponent("Trash"), fail: false), maximumEntries: 0)
  let unmeasured = try await bounded.scan(projectPaths: [fixture.project.path])
  #expect(unmeasured.candidates.isEmpty && !unmeasured.exclusions.isEmpty)
}

private final class WebActivitySwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var complete = true
  func read() -> Bool { lock.lock(); defer { lock.unlock() }; return complete }
  func block() { lock.lock(); complete = false; lock.unlock() }
}
@Test(arguments: [CleanupProvider.next, .vite])
func webRechecksChangedContentsActivityAndCancellation(_ provider: CleanupProvider) async throws {
  let fixture = try WebFixture(provider); defer { fixture.remove() }
  let activity = WebActivitySwitch()
  let engine = CacheCleanupEngine(root: fixture.base.appendingPathComponent("Absent"), trash: WebTrash(root: fixture.base.appendingPathComponent("Trash"), fail: false), activity: { .init(samples: [], complete: activity.read()) })
  let plan = try await engine.scan(projectPaths: [fixture.project.path]); let item = try #require(plan.candidates.first)
  try Data("changed cache".utf8).write(to: fixture.output.appendingPathComponent("data"))
  let changed = try await engine.moveToTrash(planID: plan.id, selectedIDs: [item.id])
  #expect(changed.first?.moved == false && changed.first?.error?.contains("changed") == true)
  let fresh = try await engine.scan(projectPaths: [fixture.project.path]); let freshItem = try #require(fresh.candidates.first)
  activity.block()
  let blocked = try await engine.moveToTrash(planID: fresh.id, selectedIDs: [freshItem.id])
  #expect(blocked.first?.moved == false)
  let task = Task {
    while !Task.isCancelled { await Task.yield() }
    return try await engine.scan(projectPaths: [fixture.project.path])
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(FileManager.default.fileExists(atPath: fixture.output.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("Trash").path).isEmpty)
}

@Test func webValidExternalMetadataChangeInvalidatesPreview() async throws {
  let fixture = try WebFixture(.next); defer { fixture.remove() }
  let engine = fixture.engine()
  let plan = try await engine.scan(projectPaths: [fixture.project.path]); let item = try #require(plan.candidates.first)
  try Data("{\"pages\":{\"/new\":[]}}".utf8).write(to: fixture.marker)
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [item.id])
  #expect(result.first?.error == "Project metadata changed. Scan again.")
  #expect(FileManager.default.fileExists(atPath: fixture.output.path))
}
