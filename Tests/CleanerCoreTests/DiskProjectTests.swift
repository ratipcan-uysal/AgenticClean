import Darwin
import Foundation
import Testing
@testable import CleanerCore

private struct DiskFixture {
  let root: URL
  init() throws {
    root = URL(fileURLWithPath: "/private/tmp/AgenticDisk-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func write(_ path: String, _ size: Int) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 65, count: size).write(to: file)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func diskLogicalCategoriesAndNestedRootsDoNotDoubleCount() async throws {
  let fixture = try DiskFixture(); defer { fixture.remove() }
  try fixture.write("main.swift", 10)
  try fixture.write("node_modules/tool/index.js", 20)
  try fixture.write(".next/cache/data", 30)
  try fixture.write(".git/objects/blob", 40)
  try fixture.write("child/main.swift", 50)
  let child = fixture.root.appendingPathComponent("child").path
  let scanner = DiskProjectScanner()
  let parent = await scanner.scan(DiskProject(path: fixture.root.path), excluding: [fixture.root.path, child])
  let nested = await scanner.scan(DiskProject(path: child), excluding: [fixture.root.path, child])
  #expect(parent.state == .complete && parent.bytes == 100)
  #expect(parent.bytes(in: .source) == 10)
  #expect(parent.bytes(in: .dependencies) == 20)
  #expect(parent.bytes(in: .outputs) == 30)
  #expect(parent.bytes(in: .other) == 40)
  #expect(nested.bytes == 50)
  #expect(parent.rootIdentity != nested.rootIdentity)
}

@Test func diskLinksAndPrivateDataAreExcludedAndUnknownIsNotZero() async throws {
  let fixture = try DiskFixture(); defer { fixture.remove() }
  try fixture.write("main.swift", 17)
  try fixture.write(".codex/chat.json", 1_000)
  try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("link"), withDestinationURL: fixture.root)
  let scanner = DiskProjectScanner()
  let measured = await scanner.scan(DiskProject(path: fixture.root.path), excluding: [])
  #expect(measured.state == .partial && measured.bytes == 17)
  let linkRoot = await scanner.scan(DiskProject(path: fixture.root.appendingPathComponent("link").path), excluding: [])
  #expect(linkRoot.state == .inaccessible && linkRoot.bytes == nil)
  let absent = await scanner.scan(DiskProject(path: fixture.root.appendingPathComponent("missing").path), excluding: [])
  #expect(absent.state == .inaccessible && absent.bytes == nil)
}

@Test func diskLimitsAndCancellationRemainExplicit() async throws {
  let fixture = try DiskFixture(); defer { fixture.remove() }
  try fixture.write("a.swift", 10); try fixture.write("b.swift", 20)
  let bounded = await DiskProjectScanner(maximumEntries: 1).scan(DiskProject(path: fixture.root.path), excluding: [])
  #expect(bounded.state == .partial && (bounded.bytes == 10 || bounded.bytes == 20) && bounded.notice == "limit")
  let timed = await DiskProjectScanner(seconds: -1).scan(DiskProject(path: fixture.root.path), excluding: [])
  #expect(timed.state == .partial && timed.notice == "limit")
  let task = Task {
    while !Task.isCancelled { await Task.yield() }
    return await DiskProjectScanner().scan(DiskProject(path: fixture.root.path), excluding: [])
  }
  task.cancel()
  let cancelled = await task.value
  #expect(cancelled.state == .cancelled)
}

@Test func diskWorktreesRemainDistinctAndGitIsOnlyMeasured() async throws {
  let fixture = try DiskFixture(); defer { fixture.remove() }
  try fixture.write("worktree-a/.git", 10)
  try fixture.write("worktree-a/main.swift", 20)
  try fixture.write("worktree-b/.git", 11)
  try fixture.write("worktree-b/main.swift", 21)
  let scanner = DiskProjectScanner()
  let a = await scanner.scan(DiskProject(path: fixture.root.appendingPathComponent("worktree-a").path), excluding: [])
  let b = await scanner.scan(DiskProject(path: fixture.root.appendingPathComponent("worktree-b").path), excluding: [])
  #expect(a.bytes == 30 && b.bytes == 32)
  #expect(a.id != b.id && a.rootIdentity != b.rootIdentity)
  #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worktree-a/.git").path))
}

@Test func diskUnreadableRootRequiresAccessRatherThanReportingZero() async throws {
  let fixture = try DiskFixture()
  defer { chmod(fixture.root.path, 0o700); fixture.remove() }
  try fixture.write("main.swift", 10)
  #expect(chmod(fixture.root.path, 0) == 0)
  let result = await DiskProjectScanner().scan(DiskProject(path: fixture.root.path), excluding: [])
  #expect(result.state == .inaccessible && result.bytes == nil)
}

@Test func diskPrivateRootCannotBeScannedAsAManualProject() async throws {
  let fixture = try DiskFixture(); defer { fixture.remove() }
  try fixture.write(".codex/chat.json", 10)
  let result = await DiskProjectScanner().scan(DiskProject(path: fixture.root.appendingPathComponent(".codex").path), excluding: [])
  #expect(result.state == .inaccessible && result.bytes == nil && result.notice == "excluded")
}
