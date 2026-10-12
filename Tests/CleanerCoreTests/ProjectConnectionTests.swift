import Foundation
import Testing
import Darwin
import ProcessKit
@testable import CleanerCore

private func connectionRow(_ pid: Int32, path: String, project: ProjectHint? = nil) -> ProcessRow {
  ProcessRow(sample: .init(id: .init(pid: pid, seconds: 1), parent: 1, uid: getuid(), path: path), cpu: 1, reasons: [], owner: "fixture", project: project)
}
@Test func projectContextIsOptInAndPreservesEveryRow() async {
  let project = connectionRow(900001, path: "/opt/homebrew/bin/node", project: .init(path: "/Users/test/site", sourcePID: 900001, inherited: false, hasProjectMarker: true))
  let app = connectionRow(900002, path: "/Applications/Claude.app/Contents/MacOS/Claude Helper (Renderer)")
  let system = connectionRow(900003, path: "/System/Library/test")
  let runtime = connectionRow(900004, path: "/opt/homebrew/bin/node")
  let rows = [project, app, system, runtime]
  let snapshot = Snapshot(date: Date(), uptime: 1, interval: 5, duration: 0, system: .init(ticks: [], memory: []), swap: 0, cpu: 1, paging: [], rows: rows, applications: ResourceSummary.groups(rows), projects: ResourceSummary.projectGroups(rows), unreadableCount: 0, quality: .fresh, sustainedCPU: false)
  var request = PresentationRequest()
  request.mode = .projects
  var result = await Presentation.prepare(snapshot, request: request)
  #expect(result.rows.map(\.id) == [project.id])
  #expect(result.projectContextCount == 3)
  #expect(!result.containsGroup("context:system"))
  request.query = "Renderer"
  result = await Presentation.prepare(snapshot, request: request)
  #expect(result.rows.isEmpty && result.projectContextCount == 1)
  request.showProjectContext = true
  result = await Presentation.prepare(snapshot, request: request)
  #expect(result.rows.map(\.id) == [app.id])
  request.query = ""
  result = await Presentation.prepare(snapshot, request: request)
  #expect(Set(result.groups.flatMap(\.rows).map(\.id)) == Set(rows.map(\.id)))
  #expect(ProjectConnectionKind.identify(app) == .application)
  #expect(ProjectConnectionKind.identify(system) == .system)
  #expect(ProjectConnectionKind.identify(runtime) == .unknown)
  let provider = connectionRow(900005, path: "/opt/homebrew/bin/llama-server")
  #expect(ProjectConnectionKind.identify(provider) == .service)
}
@Test func investigationReturnsOnlyExplicitPathsAndNeverEnvironment() throws {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/bin/sh")
  child.arguments = ["-c", "read value", "fixture", "--cwd", "/tmp/project-evidence", "--token", "secret-value", "--config=/tmp/project-evidence/package.json"]
  child.environment = ["PRIVATE_TEST_VALUE": "must-not-be-returned"]
  let input = Pipe()
  child.standardInput = input
  try child.run()
  defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
  var bytes = [CChar](repeating: 0, count: 32768)
  let count = bytes.withUnsafeMutableBufferPointer { cleaner_project_paths(child.processIdentifier, $0.baseAddress, Int32($0.count)) }
  #expect(count > 0)
  let paths = bytes.prefix(max(0, Int(count))).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
  #expect(paths == ["/tmp/project-evidence", "/tmp/project-evidence/package.json"])
}
@Test func investigationRejectsReusedIdentityAndResolvesExistingMarkers() async throws {
  let sample = ProcessSample(id: .init(pid: getpid(), seconds: 1), parent: 1, uid: getuid(), path: "/fixture")
  do { _ = try await ProjectInvestigation.inspect(sample); Issue.record("Reused identity accepted") } catch { }
  let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("agenticclean-evidence-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data("{}".utf8).write(to: directory.appendingPathComponent("package.json"))
  let root = ProjectInvestigation.argumentRoot(directory.appendingPathComponent("package.json").path)
  #expect(root?.0 == directory.path && root?.1 == true)
  #expect(ProjectInvestigation.argumentRoot("relative/package.json") == nil)
  #expect(ProjectInvestigation.argumentRoot(directory.appendingPathComponent("missing.json").path) == nil)
  let ambiguous = ProjectInvestigation(clues: [.init(path: "/a", source: .directory, pid: 1, marked: true), .init(path: "/b", source: .argument, pid: 1, marked: true)], partial: false)
  #expect(ambiguous.conflicting)
}
