import Darwin
import Foundation
import Testing

@testable import CleanerCore

private func agentSample(_ pid: Int32, parent: Int32 = 1, path: String) -> ProcessSample {
  var sample = ProcessSample(
    id: .init(pid: pid, seconds: 1), parent: parent, uid: getuid(), path: path)
  sample.cwd = "/Users/test/work/project"
  return sample
}
private func agentRows(
  _ samples: [ProcessSample], applications: [String: ApplicationIdentity] = [:]
)
  -> [ProcessRow]
{
  var counts: [ProcessIdentity: Int] = [:]
  return ProcessMonitor.rows(
    samples, previous: [:], elapsed: 0, hotCounts: &counts,
    projectRoots: [
      "/Users/test/work/project": ProjectRoot(path: "/Users/test/work/project", marked: true)
    ], applications: applications)
}
@Test(arguments: ["claude", "codex"])
func terminalCLIFamilyIncludesChildrenWithoutAbsorbingTerminal(_ name: String) {
  let rows = agentRows([
    agentSample(
      910001, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
    agentSample(910002, parent: 910001, path: "/bin/zsh"),
    agentSample(910003, parent: 910002, path: "/opt/homebrew/bin/" + name),
    agentSample(910004, parent: 910003, path: "/opt/homebrew/bin/node"),
  ])
  #expect(rows[2].applicationKey == "family:" + name)
  #expect(rows[3].applicationKey == rows[2].applicationKey)
  #expect(rows[0].applicationKey != rows[2].applicationKey)
  #expect(rows[1].applicationKey != rows[2].applicationKey)
  #expect(rows[3].owner == rows[2].applicationName)
}
@Test func nestedIndependentAppsRemainIndependentFromAgentAncestor() {
  let editor = "/Applications/Editor.app"
  let rows = agentRows(
    [
      agentSample(910001, path: "/opt/homebrew/bin/claude"),
      agentSample(910002, parent: 910001, path: editor + "/Contents/MacOS/Editor"),
      agentSample(910003, parent: 910002, path: "/opt/homebrew/bin/node"),
    ], applications: [editor: ApplicationIdentity(bundleID: "test.editor", path: editor)])
  #expect(rows[0].applicationKey == "family:claude")
  #expect(rows[1].applicationKey == "bundle:test.editor")
  #expect(rows[2].applicationKey == "bundle:test.editor")
}
@Test func cursorIdentityUsesBundleEvidenceEvenIfRenamed() {
  let identity = ApplicationIdentity(
    bundleID: "com.todesktop.230313mzl4w4u92", path: "/Applications/My Editor.app")
  #expect(identity.familyID == "family:cursor")
  #expect(identity.familyName == "Cursor")
  let unrelated = ApplicationIdentity(bundleID: "test.other", path: "/Applications/Cursor.app")
  #expect(unrelated.familyID == "bundle:test.other")
}
@Test func agentSessionRequiresExplicitProjectStopAndMarkedDirectProject() throws {
  let row = agentRows([agentSample(910001, path: "/opt/homebrew/bin/claude")])[0]
  #expect(row.sample.protection != nil)
  #expect(throws: (any Error).self) {
    try ProcessMonitor.validateStop(row.sample, current: row.sample)
  }
  #expect(ProjectStopPlan.exclusion(for: row, pending: false) == nil)
  try NativeProjectProcessActions.validateStop(row.sample, current: row.sample)
  var inherited = row
  inherited.project = ProjectHint(
    path: "/Users/test/work/project", sourcePID: 910002, inherited: true, hasProjectMarker: true)
  #expect(ProjectStopPlan.exclusion(for: inherited, pending: false) != nil)
  var unmarked = row
  unmarked.project = ProjectHint(
    path: "/Users/test/work/project", sourcePID: row.id.pid, inherited: false,
    hasProjectMarker: false)
  #expect(ProjectStopPlan.exclusion(for: unmarked, pending: false) != nil)
}
@Test func managedEmbeddedAgentAndSystemExecutablesNeverBecomeProjectStopTargets() {
  for path in [
    "/Applications/Codex.app/Contents/Resources/codex",
    "/Users/test/Library/Application Support/Claude/claude.app/Contents/MacOS/claude",
    "/usr/libexec/codex",
    "/Users/test/Library/Application Support/Claude/cli/claude",
  ] {
    let row = agentRows([agentSample(910001, path: path)])[0]
    #expect(row.sample.projectStopProtection != nil)
    #expect(ProjectStopPlan.exclusion(for: row, pending: false) != nil)
    #expect(throws: (any Error).self) {
      try NativeProjectProcessActions.validateStop(row.sample, current: row.sample)
    }
  }
}
@Test func sessionWithOtherOrUnknownProjectChildrenIsExcludedEvenOutsideVisibleGroup() {
  let rows = agentRows([
    agentSample(910001, path: "/opt/homebrew/bin/codex"),
    agentSample(910002, parent: 910001, path: "/opt/homebrew/bin/node"),
  ])
  #expect(ProjectStopPlan.sessionExclusion(for: rows[0], among: rows) == nil)
  var other = rows[1]
  other.project = ProjectHint(
    path: "/Users/test/other/project", sourcePID: other.id.pid, inherited: false,
    hasProjectMarker: true)
  #expect(ProjectStopPlan.sessionExclusion(for: rows[0], among: [rows[0], other]) != nil)
  other.project = nil
  #expect(ProjectStopPlan.sessionExclusion(for: rows[0], among: [rows[0], other]) != nil)
}
@Test func projectSpecificValidationRejectsPIDReuseUIDAndPathChanges() {
  let sample = agentSample(910001, path: "/opt/homebrew/bin/codex")
  var reused = sample
  reused.id = .init(pid: sample.id.pid, seconds: 2)
  var changedUser = sample
  changedUser.uid = getuid() &+ 1
  var changedPath = sample
  changedPath.path = "/opt/homebrew/bin/claude"
  for current in [reused, changedUser, changedPath] {
    #expect(throws: (any Error).self) {
      try NativeProjectProcessActions.validateStop(sample, current: current)
    }
  }
}

private func fixtureProjectRoot(_ cwd: String) -> ProjectRoot? {
  let root = "/Users/test/work/project"
  if cwd == root || cwd.hasPrefix(root + "/") {
    return ProjectRoot(path: root, marked: true)
  }
  if cwd == "/Users/test/other/project" {
    return ProjectRoot(path: cwd, marked: true)
  }
  return nil
}
@Test func freshSessionVerificationAllowsSameProjectDescendantsAndUnreadableSystemProcesses() throws
{
  let session = agentSample(910001, path: "/opt/homebrew/bin/codex")
  let child = agentSample(910002, parent: 910001, path: "/opt/homebrew/bin/node")
  var grandchild = agentSample(910003, parent: 910002, path: "/bin/zsh")
  grandchild.cwd = "/Users/test/work/project/subfolder"
  let scan = ProcessScan(samples: [session, child, grandchild], unreadableCount: 200)
  try NativeProjectProcessActions.validateSession(
    session, scan: scan, resolveRoot: fixtureProjectRoot)
}
@Test func freshSessionVerificationRejectsUnreadableUserAndUnknownDescendantCWD() {
  let session = agentSample(910001, path: "/opt/homebrew/bin/claude")
  var child = agentSample(910002, parent: 910001, path: "/opt/homebrew/bin/node")
  child.cwd = nil
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session, scan: ProcessScan(samples: [session, child], unreadableCount: 0),
      resolveRoot: fixtureProjectRoot)
  }
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session,
      scan: ProcessScan(samples: [session], unreadableCount: 1, unreadableUserCount: 1),
      resolveRoot: fixtureProjectRoot)
  }
}
@Test func freshSessionVerificationRejectsNewDeepChildOfAnotherProject() {
  let session = agentSample(910001, path: "/opt/homebrew/bin/codex")
  var samples = [session]
  for number in 1...40 {
    samples.append(
      agentSample(
        Int32(910001 + number), parent: Int32(910000 + number), path: "/opt/homebrew/bin/node"))
  }
  samples[samples.count - 1].cwd = "/Users/test/other/project"
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session, scan: ProcessScan(samples: samples, unreadableCount: 0),
      resolveRoot: fixtureProjectRoot)
  }
}
@Test func freshSessionVerificationRejectsChangedSessionDirectoryOrUnmarkedRoot() {
  let session = agentSample(910001, path: "/opt/homebrew/bin/codex")
  var moved = session
  moved.cwd = "/Users/test/other/project"
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session, scan: ProcessScan(samples: [moved], unreadableCount: 0),
      resolveRoot: fixtureProjectRoot)
  }
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session, scan: ProcessScan(samples: [session], unreadableCount: 0),
      resolveRoot: { ProjectRoot(path: $0, marked: false) })
  }
}

@Test func freshSessionVerificationRejectsChangedProjectRootWithoutCWDChange() throws {
  let session = agentSample(910001, path: "/opt/homebrew/bin/codex")
  let scan = ProcessScan(samples: [session], unreadableCount: 0)
  try NativeProjectProcessActions.validateSession(
    session, scan: scan, projectPath: "/Users/test/work/project", resolveRoot: fixtureProjectRoot)
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session, scan: scan, projectPath: "/Users/test/work",
      resolveRoot: fixtureProjectRoot)
  }
}

@Test(arguments: ["ollama", "llama-server", "llmster"])
func projectStopCannotReachSharedAIThroughSessionParent(_ executable: String) throws {
  let session = agentSample(910001, path: "/opt/homebrew/bin/codex")
  let intermediate = agentSample(910002, parent: 910001, path: "/opt/homebrew/bin/node")
  let shared = agentSample(910003, parent: 910002, path: "/opt/homebrew/bin/" + executable)
  let rows = agentRows([session, intermediate, shared])
  #expect(ProjectStopPlan.exclusion(for: rows[2], pending: false) != nil)
  #expect(ProjectStopPlan.sessionExclusion(for: rows[0], among: rows) != nil)
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateSession(
      session,
      scan: ProcessScan(samples: [session, intermediate, shared], unreadableCount: 0),
      projectPath: session.cwd,
      resolveRoot: { ProjectRoot(path: $0, marked: true) })
  }
  #expect(throws: (any Error).self) {
    try NativeProjectProcessActions.validateStop(shared, current: shared)
  }
}
