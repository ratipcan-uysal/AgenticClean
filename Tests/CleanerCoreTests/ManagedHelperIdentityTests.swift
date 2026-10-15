import Darwin
import Foundation
import Testing

@testable import CleanerCore

private final class VerificationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct HelperBundleFixture: Sendable {
  let app: URL
  let node: URL
  let executable: URL
  let info: URL

  init() throws {
    app = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + "/Renamed Desktop.app", isDirectory: true)
    node = app.appendingPathComponent("Contents/Resources/cua_node/bin/node")
    executable = app.appendingPathComponent("Contents/MacOS/Desktop")
    info = app.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(
      at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture helper".utf8).write(to: node)
    try Data("fixture executable".utf8).write(to: executable)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.openai.codex", "CFBundleExecutable": "Desktop"],
      format: .xml, options: 0)
    try data.write(to: info)
  }
  func remove() { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
}

@Test(arguments: [
  "/Users/example/Applications/Studio Renamed.app/Contents/Resources/cua_node/bin/node",
  "/Volumes/External/Anything.app/Contents/Resources/cua_node/bin/node_repl",
  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
])
func managedHelperCandidatesHaveNoInstallationDirectoryOrAppNameAssumption(_ path: String) throws {
  let candidate = try #require(ManagedHelperIdentity.candidate(for: path))
  #expect(candidate.executablePath == path)
  #expect(candidate.applicationPath.hasSuffix(".app"))
  #expect(candidate.component.allowsSeparateStop == !path.hasSuffix("/codex"))
}

@Test(arguments: [
  "/tmp/Fake.app/Contents/Resources/cua_node/bin/node-evil",
  "/tmp/Fake.app/Contents/Resources/other/node",
  "/tmp/Fake.app/Contents/Resources/cua_node/bin/../bin/node",
  "/tmp/Fake.app//Contents/Resources/cua_node/bin/node",
  "/tmp/Fake/Contents/Resources/cua_node/bin/node",
  "/tmp/Fake.app/Contents/MacOS/Codex",
  "relative.app/Contents/Resources/cua_node/bin/node",
])
func managedHelperCandidatesRejectSimilarOrNoncanonicalPaths(_ path: String) {
  #expect(ManagedHelperIdentity.candidate(for: path) == nil)
}

@Test func helperPathsAndForgedBundleMetadataCannotGrantStopPermission() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  #expect(ManagedHelperIdentityResolver().resolve(path: fixture.node.path) == nil)
  let sample = ProcessSample(
    id: .init(pid: 900001, seconds: 1), parent: 1, uid: getuid(), path: fixture.node.path)
  #expect(!sample.isBundledCodexHelper)
  #expect(!sample.allowsSeparateHelperStop)
  #expect(sample.protection != nil)
}

@Test func copiedAppleCodeAndForgedOpenAIBundleIDAreNotOpenAIVendorIdentity() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  for destination in [fixture.node, fixture.executable] {
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: destination)
  }
  #expect(ManagedHelperIdentityResolver().resolve(path: fixture.node.path) == nil)
}

@Test func managedHelperCacheReusesPositiveAndNegativeValidation() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  for acceptance in [true, false] {
    let counter = VerificationCounter()
    let resolver = ManagedHelperIdentityResolver { _ in counter.record(); return acceptance }
    for _ in 0..<5 {
      #expect((resolver.resolve(path: fixture.node.path) != nil) == acceptance)
    }
    #expect(counter.value == 1)
  }
}

@Test func managedHelperCacheInvalidatesOnHelperMainExecutableAndInfoChanges() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  let counter = VerificationCounter()
  let resolver = ManagedHelperIdentityResolver { _ in counter.record(); return true }
  #expect(resolver.resolve(path: fixture.node.path) != nil)
  try Data("different helper bytes".utf8).write(to: fixture.node)
  #expect(resolver.resolve(path: fixture.node.path) != nil)
  try Data("different main executable bytes".utf8).write(to: fixture.executable)
  #expect(resolver.resolve(path: fixture.node.path) != nil)
  let info = try Data(contentsOf: fixture.info)
  try (info + Data("\n".utf8)).write(to: fixture.info)
  #expect(resolver.resolve(path: fixture.node.path) != nil)
  #expect(counter.value == 4)
}

@Test func managedHelperRejectsChangesDuringSignatureValidation() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  let resolver = ManagedHelperIdentityResolver { _ in
    try? Data(UUID().uuidString.utf8).write(to: fixture.node)
    return true
  }
  #expect(resolver.resolve(path: fixture.node.path) == nil)
}

@Test func managedHelperRejectsSymlinkedExecutablesAndMissingFiles() throws {
  let fixture = try HelperBundleFixture()
  defer { fixture.remove() }
  let counter = VerificationCounter()
  let resolver = ManagedHelperIdentityResolver { _ in counter.record(); return true }
  try FileManager.default.removeItem(at: fixture.node)
  #expect(resolver.resolve(path: fixture.node.path) == nil)
  try FileManager.default.createSymbolicLink(at: fixture.node, withDestinationURL: fixture.executable)
  #expect(resolver.resolve(path: fixture.node.path) == nil)
  #expect(counter.value == 0)
}

@Test func verifiedHelperIdentityDoesNotFollowMutableSamplePathOrOverrideCoordinatorProtection() throws {
  let node = "/Users/example/Applications/Renamed.app/Contents/Resources/cua_node/bin/node"
  var sample = ProcessSample(
    id: .init(pid: 900001, seconds: 1), parent: 1, uid: getuid(), path: node)
  sample.managedHelperIdentity = try #require(ManagedHelperIdentity.candidate(for: node))
  #expect(sample.isBundledCodexHelper && sample.allowsSeparateHelperStop)
  #expect(sample.protection != nil && sample.projectStopProtection != nil)
  sample.path = "/opt/homebrew/bin/node"
  #expect(!sample.isBundledCodexHelper && !sample.allowsSeparateHelperStop)
  let coordinator = "/Users/example/Applications/Renamed.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  sample.path = coordinator
  sample.managedHelperIdentity = ManagedHelperIdentity.candidate(for: coordinator)
  #expect(sample.isBundledCodexHelper && !sample.allowsSeparateHelperStop)
  #expect(sample.protection != nil)
}
