import Darwin
import Foundation

public struct SimulatorDevice: Identifiable, Decodable, Sendable {
  public let udid: String
  public let name: String
  public let state: String
  public var id: String { udid }
}
public enum CommandFailure: Error, LocalizedError, Sendable {
  case timedOut, cancelled, outputLimit
  case exit(Int32, String)
  public var errorDescription: String? {
    switch self {
    case .timedOut: "Yardımcı komut zaman aşımına uğradı. Sonuç doğrulanamadı."
    case .cancelled: "Yardımcı komut iptal edildi."
    case .outputLimit: "Yardımcı komut beklenenden fazla çıktı üretti."
    case .exit(let code, let output): "Komut başarısız (\(code)): \(output)"
    }
  }
}
/// Bounded execution of a helper we own. Never signals a process group or a service.
public enum CommandRunner {
  @concurrent public static func run(
    executable: String, arguments: [String], timeout: Double = 15,
    grace: Double = 2, outputLimit: Int = 1_048_576
  ) async throws -> Data {
    let child = Process()
    let pipe = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.standardOutput = pipe
    child.standardError = pipe
    try child.run()
    try? pipe.fileHandleForWriting.close()
    let fd = pipe.fileHandleForReading.fileDescriptor
    defer { try? pipe.fileHandleForReading.close() }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      throw MonitorError.message("Yardımcı komutun çıktısı güvenli okunamadı.")
    }
    let start = ProcessInfo.processInfo.systemUptime
    var terminationAt: Double?
    var forced = false
    var failure: CommandFailure?
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      // Bound draining too: a writer must not monopolize the timeout loop.
      for _ in 0..<16 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        if data.count + count > outputLimit { failure = failure ?? .outputLimit }
        if data.count < outputLimit {
          data.append(contentsOf: buffer.prefix(min(count, outputLimit - data.count)))
        }
      }
      if !child.isRunning {
        if let failure { throw failure }
        guard child.terminationStatus == 0 else {
          throw CommandFailure.exit(
            child.terminationStatus, String(decoding: data.prefix(800), as: UTF8.self))
        }
        return data
      }
      let now = ProcessInfo.processInfo.systemUptime
      if Task.isCancelled { failure = failure ?? .cancelled }
      if now - start >= timeout { failure = failure ?? .timedOut }
      if failure != nil && terminationAt == nil {
        child.terminate()
        terminationAt = now
      }
      if let terminationAt, now - terminationAt >= grace, !forced {
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        forced = true
      }
      if let terminationAt, now - terminationAt >= grace + 1 { throw failure ?? .timedOut }
      // Cancellation is observed above; still allow the bounded cleanup grace.
      if Task.isCancelled { usleep(20_000) } else { try? await Task.sleep(for: .milliseconds(20)) }
    }
  }
}
public enum SimulatorToolIssue: Error, LocalizedError, Sendable, Equatable {
  case xcodeNotConfigured, simulatorToolMissing
  public var errorDescription: String? {
    switch self {
    case .xcodeNotConfigured: "iOS simülatörlerini yönetmek için Xcode gerekiyor."
    case .simulatorToolMissing: "Seçili geliştirici konumunda iOS simülatör aracı bulunamadı."
    }
  }
}

protocol SimulatorEnvironment: Sendable {
  func developerDirectory() async throws -> String
  func isExecutable(_ path: String) async -> Bool
  func run(_ executable: String, arguments: [String]) async throws -> Data
}

private struct NativeSimulatorEnvironment: SimulatorEnvironment {
  @concurrent func developerDirectory() async throws -> String {
    if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
      return override
    }
    do {
      let data = try await CommandRunner.run(executable: "/usr/bin/xcode-select", arguments: ["--print-path"])
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch CommandFailure.exit {
      throw SimulatorToolIssue.xcodeNotConfigured
    }
  }
  @concurrent func isExecutable(_ path: String) async -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
  }
  func run(_ executable: String, arguments: [String]) async throws -> Data {
    try await CommandRunner.run(executable: executable, arguments: arguments)
  }
}

public enum SimulatorControl {
  private struct DeviceList: Decodable { let devices: [String: [SimulatorDevice]] }
  // Resolve without xcrun: its shim can trigger macOS's developer-tools installer.
  private static func tool(environment: some SimulatorEnvironment) async throws -> String {
    let selected = try await environment.developerDirectory()
    guard !selected.isEmpty else { throw SimulatorToolIssue.xcodeNotConfigured }
    var directory = URL(fileURLWithPath: selected, isDirectory: true)
    if directory.pathExtension == "app" {
      directory.appendPathComponent("Contents/Developer", isDirectory: true)
    }
    let executable = directory.appendingPathComponent("usr/bin/simctl").path
    guard await environment.isExecutable(executable) else {
      throw SimulatorToolIssue.simulatorToolMissing
    }
    return executable
  }
  public static func devices() async throws -> [SimulatorDevice] {
    try await devices(environment: NativeSimulatorEnvironment())
  }
  static func devices(environment: some SimulatorEnvironment) async throws -> [SimulatorDevice] {
    let executable = try await tool(environment: environment)
    let data = try await environment.run(executable, arguments: ["list", "devices", "booted", "--json"])
    return try JSONDecoder().decode(DeviceList.self, from: data).devices.values.flatMap { $0 }
      .filter { $0.state == "Booted" }.sorted { $0.name < $1.name }
  }
  public static func shutdown(_ device: SimulatorDevice) async throws {
    try await shutdown(device, environment: NativeSimulatorEnvironment())
  }
  static func shutdown(_ device: SimulatorDevice, environment: some SimulatorEnvironment) async throws {
    guard UUID(uuidString: device.udid) != nil else {
      throw MonitorError.message("Geçersiz simülatör kimliği.")
    }
    let executable = try await tool(environment: environment)
    _ = try await environment.run(executable, arguments: ["shutdown", device.udid])
  }
}
