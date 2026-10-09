import Darwin
import Foundation
import Testing

@testable import CleanerCore

private final class CacheTestBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}

private struct FixtureTrash: CacheTrashService {
  let destination: URL
  var fail = false
  func moveToTrash(_ url: URL) throws -> URL {
    if fail { throw CacheCleanupFailure.message("fixture trash unavailable") }
    let target = destination.appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: url, to: target)
    return target
  }
}

private struct CacheFixture {
  let base: URL
  let root: URL
  let build: URL
  let trash: URL
  let project: String
  init(marked: Bool = true) throws {
    base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("CleanerCacheTest-" + UUID().uuidString)
    root = base.appendingPathComponent("DerivedData")
    build = root.appendingPathComponent("Example-abcdef/Build")
    trash = base.appendingPathComponent("FakeTrash")
    project = base.appendingPathComponent("Source/Example.xcodeproj").path
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["WorkspacePath": project], format: .xml, options: 0)
    try plist.write(to: build.deletingLastPathComponent().appendingPathComponent("info.plist"))
    try Data("temporary build output".utf8).write(to: build.appendingPathComponent("product"))
    if marked {
      let marker = Array("true".utf8)
      let status = marker.withUnsafeBytes {
        setxattr(build.path, "com.apple.xcode.CreatedByBuildSystem", $0.baseAddress, $0.count, 0, 0)
      }
      guard status == 0 else { throw CacheCleanupFailure.message("fixture xattr failure") }
    }
  }
  func remove() { try? FileManager.default.removeItem(at: base) }
  func engine() -> CacheCleanupEngine {
    CacheCleanupEngine(root: root, trash: FixtureTrash(destination: trash))
  }
}

@Test func cachePreviewMovesOnlyConfirmedBuildAndNeverSource() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let source = fixture.base.appendingPathComponent("Source")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  try Data("user source".utf8).write(to: source.appendingPathComponent("main.swift"))
  let engine = fixture.engine()
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  #expect(candidate.bytes == UInt64("temporary build output".utf8.count))
  #expect(candidate.projectPath == fixture.project)
  #expect(candidate.blockedReason == nil)
  let results = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(results.count == 1 && results[0].moved)
  #expect(!FileManager.default.fileExists(atPath: fixture.build.path))
  #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("main.swift").path))
  #expect(FileManager.default.fileExists(atPath: try #require(results[0].trashPath)))
  await #expect(throws: (any Error).self) {
    try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  }
}

@Test func cacheRefusesMissingMarkerAndSymlinkRoots() async throws {
  let fixture = try CacheFixture(marked: false)
  defer { fixture.remove() }
  let unmarked = try await fixture.engine().scan()
  #expect(unmarked.candidates.isEmpty && unmarked.skippedCount == 1)
  let link = fixture.base.appendingPathComponent("LinkedDerivedData")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
  let linked = CacheCleanupEngine(root: link, trash: FixtureTrash(destination: fixture.trash))
  await #expect(throws: (any Error).self) { try await linked.scan() }
}

@Test func cacheDoesNotFollowDescendantSymlinks() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let outside = fixture.base.appendingPathComponent("Outside")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data(repeating: 65, count: 10_000).write(to: outside.appendingPathComponent("private-data"))
  try FileManager.default.createSymbolicLink(
    at: fixture.build.appendingPathComponent("reference"), withDestinationURL: outside)
  let engine = fixture.engine()
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  #expect(candidate.bytes < 10_000)
  let results = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(results.first?.moved == true)
  #expect(
    FileManager.default.fileExists(atPath: outside.appendingPathComponent("private-data").path))
}

@Test func cacheRejectsChangedContentsAndReplacedDirectory() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let engine = fixture.engine()
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  try Data("changed".utf8).write(to: fixture.build.appendingPathComponent("product"))
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(result.first?.moved == false)
  #expect(result.first?.error?.contains("changed") == true)
  #expect(FileManager.default.fileExists(atPath: fixture.build.path))
  let second = try await engine.scan()
  let secondCandidate = try #require(second.candidates.first)
  let held = fixture.base.appendingPathComponent("Held")
  try FileManager.default.moveItem(at: fixture.build, to: held)
  try FileManager.default.createSymbolicLink(at: fixture.build, withDestinationURL: held)
  let replacement = try await engine.moveToTrash(
    planID: second.id, selectedIDs: [secondCandidate.id])
  #expect(replacement.first?.moved == false)
  #expect(FileManager.default.fileExists(atPath: held.path))
}

@Test func cacheBlocksActiveProjectsAndIncompleteActivity() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  var process = ProcessSample(
    id: .init(pid: 900_101, seconds: 1), parent: 1, uid: getuid(), path: "/opt/node")
  process.cwd = URL(fileURLWithPath: fixture.project).deletingLastPathComponent().path
  let active = process
  let engine = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash),
    activity: { .init(samples: [active], complete: true) })
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  #expect(candidate.blockedReason != nil)
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(result.first?.moved == false)
  let incomplete = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash),
    activity: { .init(samples: [], complete: false) })
  let partial = try await incomplete.scan()
  #expect(partial.candidates.first?.blockedReason != nil)
}

@Test func cacheRechecksActivityAtConfirmationAndPreservesTrashFailures() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let activity = CacheTestBox(false)
  let engine = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash),
    activity: {
      .init(samples: [], complete: !activity.withLock { $0 })
    })
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  activity.withLock { $0 = true }
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(result.first?.moved == false)
  let failing = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash, fail: true))
  let failingPlan = try await failing.scan()
  let failingCandidate = try #require(failingPlan.candidates.first)
  let failed = try await failing.moveToTrash(
    planID: failingPlan.id, selectedIDs: [failingCandidate.id])
  #expect(failed.first?.error == "fixture trash unavailable")
  #expect(FileManager.default.fileExists(atPath: fixture.build.path))
}

@Test func cacheExcludesUnmeasuredFoldersAndExpiresPreviews() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let bounded = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash), maximumEntries: 0)
  let boundedPlan = try await bounded.scan()
  #expect(boundedPlan.candidates.isEmpty && !boundedPlan.notices.isEmpty)
  let now = CacheTestBox(Date())
  let engine = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash),
    currentDate: { now.withLock { $0 } })
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  now.withLock { $0 = $0.addingTimeInterval(121) }
  await #expect(throws: (any Error).self) {
    try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  }
  #expect(FileManager.default.fileExists(atPath: fixture.build.path))
}

@Test func cacheRechecksProjectMetadataAndRequiresKnownSelection() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let engine = fixture.engine()
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  await #expect(throws: (any Error).self) {
    try await engine.moveToTrash(planID: plan.id, selectedIDs: [UUID()])
  }
  let plist = try PropertyListSerialization.data(
    fromPropertyList: [
      "WorkspacePath": fixture.base.appendingPathComponent("Other.xcodeproj").path
    ],
    format: .xml, options: 0)
  try plist.write(
    to: fixture.build.deletingLastPathComponent().appendingPathComponent("info.plist"))
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(result.first?.error == "Project metadata changed. Scan again.")
  #expect(FileManager.default.fileExists(atPath: fixture.build.path))
}

@Test func cacheRejectsPathReplacementDuringFinalActivityCheck() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let calls = CacheTestBox(0)
  let held = fixture.base.appendingPathComponent("OriginalBuild")
  let engine = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash),
    activity: {
      let count = calls.withLock {
        $0 += 1
        return $0
      }
      if count == 3 {
        try FileManager.default.moveItem(at: fixture.build, to: held)
        try FileManager.default.copyItem(at: held, to: fixture.build)
      }
      return .init(samples: [], complete: true)
    })
  let plan = try await engine.scan()
  let candidate = try #require(plan.candidates.first)
  let result = try await engine.moveToTrash(planID: plan.id, selectedIDs: [candidate.id])
  #expect(result.first?.moved == false)
  #expect(result.first?.error == "Folder identity changed. Scan again.")
  #expect(FileManager.default.fileExists(atPath: fixture.build.path))
  #expect(FileManager.default.fileExists(atPath: held.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func cacheQuietPeriodBlocksRecentWritesAndAllowsOlderBuilds() async throws {
  let fixture = try CacheFixture()
  defer { fixture.remove() }
  let engine = CacheCleanupEngine(
    root: fixture.root, trash: FixtureTrash(destination: fixture.trash), quietPeriod: 60)
  let recent = try await engine.scan()
  #expect(
    recent.candidates.first?.blockedReason
      == "This folder changed in the last minute. Wait and scan again.")
  let old = Date().addingTimeInterval(-120)
  try FileManager.default.setAttributes(
    [.modificationDate: old], ofItemAtPath: fixture.build.appendingPathComponent("product").path)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fixture.build.path)
  let quiet = try await engine.scan()
  #expect(try #require(quiet.candidates.first).blockedReason == nil)
}
