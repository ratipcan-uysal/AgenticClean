import Foundation
import Testing
@testable import CleanerCore

private actor SimulatorFixture: SimulatorEnvironment {
  let directory: String
  let executable: Bool
  let issue: SimulatorToolIssue?
  let commandFailure: CommandFailure?
  var commands: [(String, [String])] = []
  init(directory: String = "/Applications/Xcode.app/Contents/Developer", executable: Bool = true,
       issue: SimulatorToolIssue? = nil, commandFailure: CommandFailure? = nil) {
    self.directory = directory; self.executable = executable
    self.issue = issue; self.commandFailure = commandFailure
  }
  func developerDirectory() throws -> String {
    if let issue { throw issue }
    return directory
  }
  func isExecutable(_ path: String) -> Bool { executable && path.hasSuffix("/usr/bin/simctl") }
  func run(_ executable: String, arguments: [String]) throws -> Data {
    commands.append((executable, arguments))
    if let commandFailure { throw commandFailure }
    return Data(#"{"devices":{"runtime":[{"udid":"00000000-0000-0000-0000-000000000001","name":"Z Phone","state":"Booted"},{"udid":"00000000-0000-0000-0000-000000000002","name":"A Phone","state":"Booted"},{"udid":"00000000-0000-0000-0000-000000000003","name":"Off Phone","state":"Shutdown"}]}}"#.utf8)
  }
}

@Test func missingXcodeDoesNotInvokeAnySimulatorCommand() async throws {
  let fixture = SimulatorFixture(issue: .xcodeNotConfigured)
  do { _ = try await SimulatorControl.devices(environment: fixture); Issue.record("Expected missing Xcode") }
  catch { #expect(error as? SimulatorToolIssue == .xcodeNotConfigured) }
  #expect(await fixture.commands.isEmpty)
}

@Test(arguments: ["/Library/Developer/CommandLineTools", "/Applications/Missing.app/Contents/Developer"])
func unavailableSelectedToolsDoNotInvokeAnInstallerOrSimctl(_ directory: String) async throws {
  let fixture = SimulatorFixture(directory: directory, executable: false)
  do { _ = try await SimulatorControl.devices(environment: fixture); Issue.record("Expected unavailable tool") }
  catch { #expect(error as? SimulatorToolIssue == .simulatorToolMissing) }
  #expect(await fixture.commands.isEmpty)
}

@Test(arguments: ["/Applications/Custom Xcode.app", "/Applications/Custom Xcode.app/Contents/Developer"])
func configuredXcodeUsesDirectToolAndPreservesBootedFiltering(_ directory: String) async throws {
  let fixture = SimulatorFixture(directory: directory)
  let devices = try await SimulatorControl.devices(environment: fixture)
  #expect(devices.map(\.name) == ["A Phone", "Z Phone"])
  let calls = await fixture.commands
  #expect(calls.count == 1)
  #expect(calls.first?.0 == "/Applications/Custom Xcode.app/Contents/Developer/usr/bin/simctl")
  #expect(calls.first?.1 == ["list", "devices", "booted", "--json"])
  try await SimulatorControl.shutdown(devices[0], environment: fixture)
  let after = await fixture.commands
  #expect(after.last?.1 == ["shutdown", devices[0].udid])
  #expect(after.allSatisfy { !$0.0.contains("xcrun") && !$0.1.contains("--install") })
}

@Test func simulatorRuntimeFailureIsNotMisreportedAsMissingXcode() async throws {
  let fixture = SimulatorFixture(commandFailure: .timedOut)
  do { _ = try await SimulatorControl.devices(environment: fixture); Issue.record("Expected timeout") }
  catch { #expect(error as? CommandFailure != nil); #expect(error as? SimulatorToolIssue == nil) }
  #expect(await fixture.commands.count == 1)
}

@Test func invalidSimulatorIdentityDoesNotRunPreflightOrShutdown() async throws {
  let fixture = SimulatorFixture(issue: .xcodeNotConfigured)
  let device = try JSONDecoder().decode(SimulatorDevice.self, from: Data(#"{"udid":"invalid","name":"Invalid","state":"Booted"}"#.utf8))
  do { try await SimulatorControl.shutdown(device, environment: fixture); Issue.record("Expected invalid identity") }
  catch { #expect(error as? SimulatorToolIssue == nil) }
  #expect(await fixture.commands.isEmpty)
}
