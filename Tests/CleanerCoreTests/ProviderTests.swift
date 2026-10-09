import Foundation
import Testing

@testable import CleanerCore

private func providerEndpoint(_ provider: String = "ollama") throws -> LocalProviderEndpoint {
  try LocalProviderEndpoint(
    process: .init(pid: 900_000, seconds: 1),
    executablePath: "/opt/homebrew/bin/" + provider, baseURL: URL(string: "http://127.0.0.1:11434")!
  )
}
private actor ProviderFixture: ProviderHTTPTransport {
  var responses: [ProviderHTTPResponse]
  var requests: [URLRequest] = []
  init(_ bodies: [String]) { responses = bodies.map { .init(status: 200, data: Data($0.utf8)) } }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.timedOut) }
    return responses.removeFirst()
  }
}
private let loadedOllama =
  #"{"models":[{"name":"model:tag","digest":"abc","size":2048,"size_vram":1024}]}"#

@Test func providerEndpointRejectsRemoteAndCredentialedTargets() throws {
  for url in [
    "http://example.com:11434", "http://localhost:11434", "http://127.0.0.1:11434/api",
    "http://user:secret@127.0.0.1:11434", "https://127.0.0.1:11434", "http://127.0.0.1:11434?x=1",
  ] {
    #expect(throws: ProviderError.invalidEndpoint) {
      try LocalProviderEndpoint(
        process: .init(pid: 1, seconds: 1), executablePath: "/bin/ollama",
        baseURL: URL(string: url)!)
    }
  }
  #expect(throws: ProviderError.invalidEndpoint) {
    try LocalProviderEndpoint(
      process: .init(pid: 1, seconds: 1), executablePath: "/bin/node",
      baseURL: URL(string: "http://127.0.0.1:11434")!)
  }
}
@Test func providerResidencyNeverImpliesActivityOrAdditiveMemory() throws {
  let result = try LocalProviderService.decodeInventory(Data(loadedOllama.utf8), provider: .ollama)
  #expect(result.activeRequests == nil)
  #expect(result.models[0].reportedMemoryBytes == 2048)
  #expect(result.models[0].reportedGPUMemoryBytes == 1024)
  let lm =
    #"{"models":[{"key":"disk-only","loaded_instances":[],"size_bytes":9999},{"key":"loaded","display_name":"Friendly","loaded_instances":[{"id":"instance-7"}]}]}"#
  let inventory = try LocalProviderService.decodeInventory(Data(lm.utf8), provider: .lmStudio)
  #expect(inventory.models.count == 1)
  #expect(inventory.models[0].id == "instance-7")
  #expect(inventory.models[0].reportedMemoryBytes == nil)
}
@Test func providerMalformedAndDuplicateDataIsNotEmptySuccess() {
  for body in [
    #"{}"#, #"{"models":[{"name":"x"}]}"#,
    #"{"models":[{"name":"x","digest":"a"},{"name":"x","digest":"b"}]}"#,
  ] {
    #expect(throws: ProviderError.invalidResponse) {
      try LocalProviderService.decodeInventory(Data(body.utf8), provider: .ollama)
    }
  }
  #expect(throws: ProviderError.responseTooLarge) {
    try LocalProviderService.decodeInventory(Data(repeating: 32, count: 524_289), provider: .ollama)
  }
}
@Test func llamaSlotsArePointInTimeActivityWithoutUnloadCapability() throws {
  let result = try LocalProviderService.decodeInventory(
    Data(#"[{"is_processing":false},{"is_processing":true}]"#.utf8), provider: .llamaCPP)
  #expect(result.activeRequests == 1)
  #expect(result.models.isEmpty)
}
@Test func unloadRevalidatesThenVerifiesInventory() async throws {
  let fixture = ProviderFixture([loadedOllama, loadedOllama, "{}", #"{"models":[]}"#])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await service.unload(plan) == .unloaded)
  let requests = await fixture.requests
  #expect(requests.count == 4)
  #expect(requests[2].httpMethod == "POST")
  #expect(requests[2].url?.path == "/api/generate")
  let body = try #require(
    JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
  #expect(body["model"] as? String == "model:tag")
  #expect(body["keep_alive"] as? Int == 0)
  #expect(body["prompt"] == nil)
}
@Test func unloadCannotTreatFailedFollowupAsSuccess() async throws {
  let fixture = ProviderFixture([loadedOllama, loadedOllama, "{}"])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await service.unload(plan) == .unverified)
}
@Test func unloadRejectsChangedModelAndExpiredPlanWithoutMutation() async throws {
  let fixture = ProviderFixture([
    loadedOllama, #"{"models":[{"name":"model:tag","digest":"changed"}]}"#,
  ])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  await #expect(throws: ProviderError.expiredPreview) {
    try await service.unload(plan, now: plan.expiresAt.addingTimeInterval(1))
  }
  await #expect(throws: ProviderError.modelChanged) { try await service.unload(plan) }
  #expect(await fixture.requests.allSatisfy { $0.httpMethod == "GET" })
}
@Test func changedServerIdentityPreventsAnyHTTP() async throws {
  let fixture = ProviderFixture([loadedOllama])
  let service = LocalProviderService(transport: fixture, validate: { _ in false })
  await #expect(throws: ProviderError.identityChanged) {
    try await service.inventory(providerEndpoint())
  }
  #expect(await fixture.requests.isEmpty)
}
@Test func lmStudioUnloadTargetsOnlyLoadedInstance() async throws {
  let loaded = #"{"models":[{"key":"model","loaded_instances":[{"id":"instance-1"}]}]}"#
  let fixture = ProviderFixture([loaded, loaded, "{}", #"{"models":[]}"#])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint("llmster"), modelID: "instance-1")
  #expect(try await service.unload(plan) == .unloaded)
  let requests = await fixture.requests
  #expect(requests[2].url?.path == "/api/v1/models/unload")
  let body = try #require(
    JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
  #expect(body == ["instance_id": "instance-1"])
}

@Test func dockerStopNeverEscalatesOrTargetsNames() throws {
  let id = String(repeating: "a", count: 64)
  let args = try DockerProviderService.stopArguments(containerID: id)
  #expect(args == ["container", "stop", "--signal", "SIGTERM", "--timeout", "-1", id])
  #expect(throws: DockerProviderError.self) {
    try DockerProviderService.stopArguments(containerID: "project_web_1")
  }
  #expect(throws: DockerProviderError.self) {
    try DockerProviderService.stopArguments(containerID: "--all")
  }
}
@Test func dockerProviderOnlyDecodesAllowlistedIdentityAndLabels() throws {
  let id = String(repeating: "a", count: 64)
  let data = Data(
    "{\"id\":\"\(id)\",\"name\":\"/web\",\"created\":\"2026-01-01T00:00:00Z\",\"running\":true,\"project\":\"site\",\"service\":\"web\",\"restartCount\":0}\n"
      .utf8)
  let rows = try DockerProviderService.decode(data)
  #expect(rows.count == 1)
  #expect(rows[0].project == "site")
  #expect(rows[0].id == id)
  #expect(throws: DockerProviderError.self) { try DockerProviderService.decode(data + data) }
  #expect(throws: DockerProviderError.self) { try DockerProviderService.decode(Data("{}".utf8)) }
}
@Test func defaultProviderValidationRequiresObservedSocket() async throws {
  let fixture = ProviderFixture([loadedOllama])
  let service = LocalProviderService(transport: fixture)
  await #expect(throws: ProviderError.identityChanged) {
    try await service.inventory(providerEndpoint())
  }
  #expect(await fixture.requests.isEmpty)
}

private struct ProviderStatusFixture: ProviderHTTPTransport {
  let status: Int
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    .init(status: status, data: Data(loadedOllama.utf8))
  }
}
@Test func providerHTTPFailureIsNeverEmptySuccess() async throws {
  for status in [301, 401, 404, 500] {
    let service = LocalProviderService(
      transport: ProviderStatusFixture(status: status), validate: { _ in true })
    await #expect(throws: ProviderError.httpStatus(status)) {
      try await service.inventory(providerEndpoint())
    }
  }
}
@Test func providerResidentAfterUnloadIsNotSuccess() async throws {
  let fixture = ProviderFixture([loadedOllama, loadedOllama, "{}", loadedOllama])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await service.unload(plan) == .stillResident)
}
private actor IdentitySequence {
  private var remaining = 1
  func valid() -> Bool {
    defer { remaining -= 1 }
    return remaining > 0
  }
}
@Test func providerIdentityChangesDuringReadAreRejected() async throws {
  let fixture = ProviderFixture([loadedOllama])
  let identities = IdentitySequence()
  let service = LocalProviderService(
    transport: fixture, validate: { _ in await identities.valid() })
  await #expect(throws: ProviderError.identityChanged) {
    try await service.inventory(providerEndpoint())
  }
  #expect(await fixture.requests.count == 1)
}

private actor DockerCommandFixture {
  var output: [Data]
  var calls: [[String]] = []
  init(_ strings: [String]) { output = strings.map { Data($0.utf8) } }
  func run(_ args: [String]) throws -> Data {
    calls.append(args)
    guard !output.isEmpty else { throw URLError(.timedOut) }
    return output.removeFirst()
  }
}
private let dockerTestID = String(repeating: "a", count: 64)
private func dockerJSON(running: Bool, restart: Int = 0) -> String {
  "{\"id\":\"\(dockerTestID)\",\"name\":\"/web\",\"created\":\"start\",\"running\":\(running),\"project\":\"site\",\"service\":\"web\",\"restartCount\":\(restart)}"
}
private let dockerTestEndpoint = DockerLocalEndpoint(
  executable: "/fixture/docker", socketPath: "/fixture/docker.sock", inode: 0, device: 0)
@Test func dockerProviderRevalidatesAndVerifiesExactStop() async throws {
  let fixture = DockerCommandFixture([
    dockerJSON(running: true), dockerJSON(running: true), "", dockerJSON(running: false),
  ])
  let service = DockerProviderService(
    run: { _, args in try await fixture.run(args) }, validate: { _ in true })
  let plan = try await service.prepareStop(dockerTestEndpoint, containerID: dockerTestID)
  #expect(try await service.stop(plan) == .stopped)
  let calls = await fixture.calls
  #expect(
    calls[2] == [
      "--host", "unix:///fixture/docker.sock", "container", "stop", "--signal", "SIGTERM",
      "--timeout", "-1", dockerTestID,
    ])
}
@Test func dockerProviderRestartedTargetCannotReceiveOldPlan() async throws {
  let fixture = DockerCommandFixture([
    dockerJSON(running: true), dockerJSON(running: true, restart: 1),
  ])
  let service = DockerProviderService(
    run: { _, args in try await fixture.run(args) }, validate: { _ in true })
  let plan = try await service.prepareStop(dockerTestEndpoint, containerID: dockerTestID)
  await #expect(throws: DockerProviderError.self) { try await service.stop(plan) }
  #expect(await fixture.calls.count == 2)
}
@Test func dockerProviderFailedReadAfterStopIsUnverified() async throws {
  let fixture = DockerCommandFixture([dockerJSON(running: true), dockerJSON(running: true), ""])
  let service = DockerProviderService(
    run: { _, args in try await fixture.run(args) }, validate: { _ in true })
  let plan = try await service.prepareStop(dockerTestEndpoint, containerID: dockerTestID)
  #expect(try await service.stop(plan) == .unverified)
}
@Test func dockerProviderInvalidSocketSendsNoCommand() async throws {
  let fixture = DockerCommandFixture([])
  let service = DockerProviderService(run: { _, args in try await fixture.run(args) })
  await #expect(throws: DockerProviderError.self) {
    try await service.inventory(dockerTestEndpoint)
  }
  #expect(await fixture.calls.isEmpty)
}

@Test func providerLostPOSTResponseIsUnverified() async throws {
  let fixture = ProviderFixture([loadedOllama, loadedOllama])
  let service = LocalProviderService(transport: fixture, validate: { _ in true })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await service.unload(plan) == .unverified)
  #expect(await fixture.requests.last?.httpMethod == "POST")
}
private actor PostStatusFixture: ProviderHTTPTransport {
  let status: Int
  init(_ status: Int) { self.status = status }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    .init(status: request.httpMethod == "POST" ? status : 200, data: Data(loadedOllama.utf8))
  }
}
@Test func providerPOSTServerErrorIsUnverifiedButAuthRejectionIsActionable() async throws {
  let uncertain = LocalProviderService(transport: PostStatusFixture(500), validate: { _ in true })
  let uncertainPlan = try await uncertain.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await uncertain.unload(uncertainPlan) == .unverified)
  let rejected = LocalProviderService(transport: PostStatusFixture(401), validate: { _ in true })
  let rejectedPlan = try await rejected.prepareUnload(providerEndpoint(), modelID: "model:tag")
  await #expect(throws: ProviderError.httpStatus(401)) { try await rejected.unload(rejectedPlan) }
}
private actor PostIdentitySequence {
  private var remaining = 5
  func valid() -> Bool {
    defer { remaining -= 1 }
    return remaining > 0
  }
}
@Test func providerIdentityLostAfterPOSTIsUnverified() async throws {
  let fixture = ProviderFixture([loadedOllama, loadedOllama, "{}"])
  let identities = PostIdentitySequence()
  let service = LocalProviderService(
    transport: fixture, validate: { _ in await identities.valid() })
  let plan = try await service.prepareUnload(providerEndpoint(), modelID: "model:tag")
  #expect(try await service.unload(plan) == .unverified)
}
