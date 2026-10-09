import Darwin
import Foundation

public enum DockerProviderError: Error, Sendable {
  case unavailable, endpointChanged, invalidResponse, expiredPreview, targetChanged
}

/// Explicitly targets Docker Desktop's user-owned Unix socket, ignoring DOCKER_HOST/context.
public struct DockerLocalEndpoint: Sendable, Equatable {
  public let executable: String
  public let socketPath: String
  let inode: UInt64
  let device: Int32
  public static func discover() throws -> Self {
    let executable = "/Applications/Docker.app/Contents/Resources/bin/docker"
    let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".docker/run/docker.sock"
    ).path
    var info = stat()
    guard FileManager.default.isExecutableFile(atPath: executable), lstat(socket, &info) == 0,
      info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid()
    else { throw DockerProviderError.unavailable }
    return Self(executable: executable, socketPath: socket, inode: info.st_ino, device: info.st_dev)
  }
  public func validate() -> Bool {
    var info = stat()
    return lstat(socketPath, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
      && info.st_uid == getuid() && info.st_ino == inode && info.st_dev == device
  }
}

public struct DockerWorkload: Identifiable, Decodable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let created: String
  public let running: Bool
  public let project: String?
  public let service: String?
  public let restartCount: Int
}
public struct DockerStopPlan: Sendable {
  public let endpoint: DockerLocalEndpoint
  public let container: DockerWorkload
  public let createdAt: Date
  fileprivate init(endpoint: DockerLocalEndpoint, container: DockerWorkload) {
    self.endpoint = endpoint
    self.container = container
    self.createdAt = Date()
  }
}
public enum DockerStopResult: Sendable, Equatable { case stopped, stillRunning, unverified }

public struct DockerProviderService: Sendable {
  public typealias Runner = @Sendable (String, [String]) async throws -> Data
  private let run: Runner
  private let validate: @Sendable (DockerLocalEndpoint) -> Bool
  public init(
    run: @escaping Runner = { executable, arguments in
      try await CommandRunner.run(
        executable: executable, arguments: arguments, timeout: 15, grace: 2)
    }, validate: @escaping @Sendable (DockerLocalEndpoint) -> Bool = { $0.validate() }
  ) {
    self.run = run
    self.validate = validate
  }

  /// Explicit refresh only; never launch Docker or reconfigure Resource Saver.
  public func inventory(_ endpoint: DockerLocalEndpoint) async throws -> [DockerWorkload] {
    let data = try await command(endpoint, ["container", "ls", "--no-trunc", "--quiet"])
    let ids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(
      String.init)
    guard ids.count <= 128, ids.allSatisfy(Self.validID) else {
      throw DockerProviderError.invalidResponse
    }
    guard !ids.isEmpty else { return [] }
    return try await inspect(endpoint, ids: ids)
  }
  public func prepareStop(_ endpoint: DockerLocalEndpoint, containerID: String) async throws
    -> DockerStopPlan
  {
    guard Self.validID(containerID),
      let container = try await inspect(endpoint, ids: [containerID]).first,
      container.running
    else { throw DockerProviderError.targetChanged }
    return DockerStopPlan(endpoint: endpoint, container: container)
  }
  public func stop(_ plan: DockerStopPlan, now: Date = Date()) async throws -> DockerStopResult {
    guard now >= plan.createdAt, now.timeIntervalSince(plan.createdAt) <= 60 else {
      throw DockerProviderError.expiredPreview
    }
    let current = try await inspect(plan.endpoint, ids: [plan.container.id])
    guard current.first == plan.container else { throw DockerProviderError.targetChanged }
    guard Date().timeIntervalSince(plan.createdAt) <= 60 else {
      throw DockerProviderError.expiredPreview
    }
    // -1 disables Docker's automatic SIGKILL escalation. The bounded CLI helper can time out
    // while the container keeps running; timing out never sends a stronger container signal.
    do {
      _ = try await command(plan.endpoint, Self.stopArguments(containerID: plan.container.id))
    } catch { return .unverified }
    do {
      guard let after = try await inspect(plan.endpoint, ids: [plan.container.id]).first else {
        return .unverified
      }
      return after.running ? .stillRunning : .stopped
    } catch { return .unverified }
  }
  public static func stopArguments(containerID: String) throws -> [String] {
    guard validID(containerID) else { throw DockerProviderError.invalidResponse }
    return ["container", "stop", "--signal", "SIGTERM", "--timeout", "-1", containerID]
  }
  public static func decode(_ data: Data) throws -> [DockerWorkload] {
    guard data.count <= 1_048_576 else { throw DockerProviderError.invalidResponse }
    do {
      let rows = try data.split(separator: 10).filter { !$0.isEmpty }.map { line in
        try JSONDecoder().decode(DockerWorkload.self, from: Data(line))
      }
      guard rows.count <= 128,
        rows.allSatisfy({ validID($0.id) && !$0.created.isEmpty && $0.restartCount >= 0 }),
        Set(rows.map(\.id)).count == rows.count
      else { throw DockerProviderError.invalidResponse }
      return rows
    } catch { throw DockerProviderError.invalidResponse }
  }
  private static func validID(_ id: String) -> Bool {
    id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private func inspect(_ endpoint: DockerLocalEndpoint, ids: [String]) async throws
    -> [DockerWorkload]
  {
    guard ids.allSatisfy(Self.validID) else { throw DockerProviderError.invalidResponse }
    // Deliberate allowlist: never retrieve Env, command lines, mounts or raw full inspect output.
    let format =
      #"{"id":{{json .Id}},"name":{{json .Name}},"created":{{json .Created}},"running":{{json .State.Running}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"restartCount":{{json .RestartCount}}}"#
    let data = try await command(endpoint, ["container", "inspect", "--format", format] + ids)
    let result = try Self.decode(data)
    guard Set(result.map(\.id)) == Set(ids) else { throw DockerProviderError.invalidResponse }
    return result
  }
  private func command(_ endpoint: DockerLocalEndpoint, _ arguments: [String]) async throws -> Data
  {
    guard validate(endpoint) else { throw DockerProviderError.endpointChanged }
    let result = try await run(
      endpoint.executable, ["--host", "unix://" + endpoint.socketPath] + arguments)
    guard validate(endpoint) else { throw DockerProviderError.endpointChanged }
    return result
  }
}
