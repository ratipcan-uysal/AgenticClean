import Darwin
import Foundation
import Testing

@testable import CleanerCore

/// This fixture proves the real helper-only SIGTERM route, identity checks and
/// sibling isolation on every CI host. Its injected classification is deliberately
/// synthetic; it provides no evidence of OpenAI signing or vendor identity.
@Test func syntheticManagedHelperRouteSendsSIGTERMOnlyToSelectedOwnedChild() async throws {
  let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("cleaner-managed-signal-" + UUID().uuidString, isDirectory: true)
  let application = directory.appendingPathComponent("Synthetic Desktop.app", isDirectory: true)
  let executable = application.appendingPathComponent("Contents/Resources/cua_node/bin/node")
  let mainExecutable = application.appendingPathComponent("Contents/MacOS/Desktop")
  let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
  let source = sourceRoot.appendingPathComponent("Tests/Fixtures/process-helper.c")
  var children: [Process] = []
  defer {
    for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(
    at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: mainExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
  _ = try await CommandRunner.run(
    executable: "/usr/bin/clang", arguments: [source.path, "-o", executable.path])
  try FileManager.default.copyItem(at: executable, to: mainExecutable)
  let info = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "com.openai.codex", "CFBundleExecutable": "Desktop"],
    format: .xml, options: 0)
  try info.write(to: application.appendingPathComponent("Contents/Info.plist"))
  // A plausible bundle name/Info.plist and local linker signature never grant the
  // production vendor exception. The seam below is restricted to these test PIDs.
  #expect(ManagedHelperIdentityResolver().resolve(path: executable.path) == nil)

  for index in 0..<2 {
    let ready = directory.appendingPathComponent("ready-\(index)")
    let child = Process()
    child.executableURL = executable
    child.arguments = ["normal", ready.path]
    child.currentDirectoryURL = sourceRoot
    try child.run()
    children.append(child)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !FileManager.default.fileExists(atPath: ready.path), child.isRunning,
      ProcessInfo.processInfo.systemUptime < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(FileManager.default.fileExists(atPath: ready.path))
  }

  let ownedPIDs = Set(children.map(\.processIdentifier))
  // proc_pidpath uses the kernel's /private/var spelling; Foundation may preserve
  // the /var alias even after resolving the temporary-directory URL.
  let resolved = try #require(realpath(executable.path, nil))
  let ownedPath = String(cString: resolved)
  free(resolved)
  let readOwnedSyntheticHelper: @Sendable (Int32) -> ProcessSample? = { pid in
    // Preserve real PID/start time/UID/path/parent data. Only the signature-derived
    // classification is injected, after checking our private path and owned PIDs.
    guard var sample = ProcessMonitor.read(pid) else { return nil }
    if ownedPIDs.contains(pid), sample.uid == getuid(), sample.path == ownedPath {
      sample.managedHelperIdentity = ManagedHelperIdentity.candidate(for: sample.path)
    }
    return sample
  }
  var selected = try #require(readOwnedSyntheticHelper(children[0].processIdentifier))
  let currentDirectory: String = try #require(ProcessMonitor.workingDirectory(selected))
  selected.cwd = currentDirectory
  let sibling = try #require(ProcessMonitor.read(children[1].processIdentifier))
  try #require(selected.path == ownedPath)
  try #require(selected.allowsSeparateHelperStop)
  #expect(selected.cwd == sourceRoot.path)
  #expect(ProcessMonitor.presence(selected.id) == .sameIdentity)
  #expect(ProcessMonitor.presence(sibling.id) == .sameIdentity)

  // The public initializer must reject the exact same synthetic sample without
  // signalling it, because its native fresh read has no verified vendor identity.
  let production = NativeProjectProcessActions()
  await #expect(throws: (any Error).self) {
    try await production.stopManagedHelper(selected, projectPath: sourceRoot.path)
  }
  #expect(children[0].isRunning && children[1].isRunning)

  let actions = NativeProjectProcessActions(readProcess: readOwnedSyntheticHelper)
  try await actions.stopManagedHelper(selected, projectPath: sourceRoot.path)
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while children[0].isRunning, ProcessInfo.processInfo.systemUptime < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(!children[0].isRunning)
  if !children[0].isRunning {
    #expect(children[0].terminationReason == .uncaughtSignal)
    #expect(children[0].terminationStatus == SIGTERM)
  }
  #expect(ProcessMonitor.presence(selected.id) == .absent)
  #expect(children[1].isRunning)
  #expect(ProcessMonitor.presence(sibling.id) == .sameIdentity)
}
