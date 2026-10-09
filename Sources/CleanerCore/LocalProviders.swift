import Darwin
import Foundation

public enum LocalAIProvider: String, CaseIterable, Sendable {
  case ollama, lmStudio, llamaCPP

  public static func recognize(executablePath: String) -> Self? {
    let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
    if name == "ollama" { return .ollama }
    if name == "llama-server" { return .llamaCPP }
    if name == "llmster" || (executablePath.contains("/LM Studio.app/") && name == "lm studio") {
      return .lmStudio
    }
    return nil
  }
}

public enum ProviderError: Error, Equatable, Sendable {
  case invalidEndpoint, identityChanged, unsupported, invalidResponse, responseTooLarge
  case httpStatus(Int)
  case expiredPreview, modelChanged
}

/// A candidate is not trusted until the caller verifies that this exact process still owns
/// the listening socket. Construct only from observed listeners, never by probing default ports.
public struct LocalProviderEndpoint: Hashable, Sendable {
  public let provider: LocalAIProvider
  public let process: ProcessIdentity
  public let executablePath: String
  public let baseURL: URL
  public let listener: LocalListener?

  public init(process: ProcessIdentity, executablePath: String, baseURL: URL) throws {
    guard let provider = LocalAIProvider.recognize(executablePath: executablePath),
      let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      c.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(c.host ?? ""),
      let port = c.port, (1...65535).contains(port), c.user == nil, c.password == nil,
      c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/"
    else { throw ProviderError.invalidEndpoint }
    self.provider = provider
    self.process = process
    self.executablePath = executablePath
    self.baseURL = baseURL
    self.listener = nil
  }
  public init(listener: LocalListener, executablePath: String) throws {
    guard let url = listener.url else { throw ProviderError.invalidEndpoint }
    let checked = try Self(process: listener.identity, executablePath: executablePath, baseURL: url)
    self.provider = checked.provider
    self.process = checked.process
    self.executablePath = executablePath
    self.baseURL = url
    self.listener = listener
  }
}

public struct ProviderModel: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  /// Ollama digest or LM Studio loaded instance identifier; never inferred from display name.
  public let revision: String
  /// Provider-reported allocation, not process footprint; never add to process totals.
  public let reportedMemoryBytes: UInt64?
  public let reportedGPUMemoryBytes: UInt64?
  public let canUnload: Bool
}

public struct ProviderInventory: Sendable {
  public let endpoint: LocalProviderEndpoint
  public let observedAt: Date
  public let models: [ProviderModel]
  /// Only llama.cpp /slots currently provides observed inference activity; nil means unknown.
  public let activeRequests: Int?
}

public struct ModelUnloadPlan: Sendable {
  public let endpoint: LocalProviderEndpoint
  public let model: ProviderModel
  public let createdAt: Date
  public var expiresAt: Date { createdAt.addingTimeInterval(60) }
  // Every unload may affect other clients. Residency does not establish project ownership.
  public let mayAffectOtherClients = true
  fileprivate init(endpoint: LocalProviderEndpoint, model: ProviderModel, createdAt: Date) {
    self.endpoint = endpoint
    self.model = model
    self.createdAt = createdAt
  }
}

public enum ModelUnloadResult: Equatable, Sendable {
  case unloaded, stillResident, unverified
}

public struct ProviderHTTPResponse: Sendable {
  public let status: Int
  public let data: Data
  public init(status: Int, data: Data) {
    self.status = status
    self.data = data
  }
}

public protocol ProviderHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

private final class NoProviderRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// A separate ephemeral session per operation has a hard resource timeout, rejects redirects,
/// disables system proxies/cookies/cache, and bounds streamed data before decoding.
public struct BoundedProviderHTTPTransport: ProviderHTTPTransport {
  public init() {}
  public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 8
    config.connectionProxyDictionary = [:]
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(
      configuration: config, delegate: NoProviderRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
    guard response.expectedContentLength <= 524_288 else { throw ProviderError.responseTooLarge }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 524_288 else { throw ProviderError.responseTooLarge }
      data.append(byte)
    }
    return ProviderHTTPResponse(status: response.statusCode, data: data)
  }
}

private enum ProviderMutationError: Error { case outcomeUnknown }

public struct LocalProviderService: Sendable {
  public typealias Validator = @Sendable (LocalProviderEndpoint) async -> Bool
  private let transport: any ProviderHTTPTransport
  private let validate: Validator
  public init(
    transport: any ProviderHTTPTransport = BoundedProviderHTTPTransport(),
    validate: @escaping Validator = LocalProviderService.validateEndpoint
  ) {
    self.transport = transport
    self.validate = validate
  }

  @concurrent public static func validateEndpoint(_ endpoint: LocalProviderEndpoint) async -> Bool {
    guard let listener = endpoint.listener,
      let process = ProcessMonitor.read(endpoint.process.pid), process.id == endpoint.process,
      process.uid == getuid(), process.path == endpoint.executablePath
    else { return false }
    return (try? ProcessMonitor.validateListener(listener)) == true
  }

  /// Discovery inspects descriptors of an already recognized process; it does not send requests.
  @concurrent public static func endpoints(for process: ProcessSample) async throws
    -> [LocalProviderEndpoint]
  {
    guard process.uid == getuid(), LocalAIProvider.recognize(executablePath: process.path) != nil
    else { return [] }
    return try ProcessMonitor.listeners(for: process).compactMap {
      try? LocalProviderEndpoint(listener: $0, executablePath: process.path)
    }
  }

  public func inventory(_ endpoint: LocalProviderEndpoint) async throws -> ProviderInventory {
    let path: String =
      switch endpoint.provider {
      case .ollama: "/api/ps"
      case .lmStudio: "/api/v1/models"
      case .llamaCPP: "/slots"
      }
    let data = try await request(endpoint, path: path)
    let decoded = try Self.decodeInventory(data, provider: endpoint.provider)
    return ProviderInventory(
      endpoint: endpoint, observedAt: Date(), models: decoded.models,
      activeRequests: decoded.activeRequests)
  }

  public func prepareUnload(_ endpoint: LocalProviderEndpoint, modelID: String) async throws
    -> ModelUnloadPlan
  {
    let current = try await inventory(endpoint)
    guard let model = current.models.first(where: { $0.id == modelID }), model.canUnload else {
      throw ProviderError.unsupported
    }
    return ModelUnloadPlan(endpoint: endpoint, model: model, createdAt: Date())
  }

  /// Call only after a user reviews this exact plan. No bulk or automatic unload is provided.
  /// A failed post-request read is unverified, never reported as unloaded.
  public func unload(_ plan: ModelUnloadPlan, now: Date = Date()) async throws -> ModelUnloadResult
  {
    guard now >= plan.createdAt, now <= plan.expiresAt else { throw ProviderError.expiredPreview }
    let current = try await inventory(plan.endpoint)
    guard
      current.models.contains(where: {
        $0.id == plan.model.id && $0.revision == plan.model.revision
      })
    else {
      throw ProviderError.modelChanged
    }
    guard Date() <= plan.expiresAt else { throw ProviderError.expiredPreview }
    let path: String
    let body: [String: Any]
    switch plan.endpoint.provider {
    case .ollama:
      path = "/api/generate"
      body = ["model": plan.model.id, "keep_alive": 0, "stream": false]
    case .lmStudio:
      path = "/api/v1/models/unload"
      body = ["instance_id": plan.model.id]
    case .llamaCPP: throw ProviderError.unsupported
    }
    do {
      _ = try await request(
        plan.endpoint, path: path, body: JSONSerialization.data(withJSONObject: body))
    } catch ProviderMutationError.outcomeUnknown { return .unverified }
    do {
      let after = try await inventory(plan.endpoint)
      return after.models.contains(where: { $0.id == plan.model.id }) ? .stillResident : .unloaded
    } catch { return .unverified }
  }

  private func request(_ endpoint: LocalProviderEndpoint, path: String, body: Data? = nil)
    async throws -> Data
  {
    guard await validate(endpoint) else { throw ProviderError.identityChanged }
    var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(String(path.dropFirst())))
    request.timeoutInterval = 5
    request.httpMethod = body == nil ? "GET" : "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let response: ProviderHTTPResponse
    do { response = try await transport.send(request) } catch {
      if body != nil { throw ProviderMutationError.outcomeUnknown }
      throw error
    }
    guard await validate(endpoint) else {
      if body != nil { throw ProviderMutationError.outcomeUnknown }
      throw ProviderError.identityChanged
    }
    guard (200...299).contains(response.status) else {
      // Auth/validation/unsupported-method rejections establish that this action was rejected.
      // A server error, timeout, or changed identity after dispatch cannot establish failure.
      if body != nil && ![400, 401, 403, 404, 405, 422].contains(response.status) {
        throw ProviderMutationError.outcomeUnknown
      }
      throw ProviderError.httpStatus(response.status)
    }
    guard response.data.count <= 524_288 else {
      if body != nil { throw ProviderMutationError.outcomeUnknown }
      throw ProviderError.responseTooLarge
    }
    return response.data
  }

  public static func decodeInventory(_ data: Data, provider: LocalAIProvider) throws
    -> (models: [ProviderModel], activeRequests: Int?)
  {
    guard data.count <= 524_288 else { throw ProviderError.responseTooLarge }
    do {
      let decoder = JSONDecoder()
      switch provider {
      case .ollama:
        let response = try decoder.decode(OllamaResponse.self, from: data)
        guard response.models.count <= 256 else { throw ProviderError.invalidResponse }
        let models = try response.models.map { model in
          try validIdentifier(model.name)
          try validIdentifier(model.digest)
          return ProviderModel(
            id: model.name, name: model.name, revision: model.digest,
            reportedMemoryBytes: model.size, reportedGPUMemoryBytes: model.size_vram,
            canUnload: true)
        }
        guard Set(models.map(\.id)).count == models.count else {
          throw ProviderError.invalidResponse
        }
        return (models, nil)
      case .lmStudio:
        let response = try decoder.decode(LMResponse.self, from: data)
        guard response.models.count <= 256 else { throw ProviderError.invalidResponse }
        var models: [ProviderModel] = []
        for model in response.models {
          try validIdentifier(model.key)
          guard model.loaded_instances.count <= 256 else { throw ProviderError.invalidResponse }
          for instance in model.loaded_instances {
            try validIdentifier(instance.id)
            if let name = model.display_name { try validIdentifier(name) }
            models.append(
              ProviderModel(
                id: instance.id, name: model.display_name ?? model.key,
                revision: model.key + ":" + instance.id, reportedMemoryBytes: nil,
                reportedGPUMemoryBytes: nil, canUnload: true))
          }
        }
        guard models.count <= 256, Set(models.map(\.id)).count == models.count else {
          throw ProviderError.invalidResponse
        }
        return (models, nil)
      case .llamaCPP:
        let slots = try decoder.decode([LlamaSlot].self, from: data)
        guard slots.count <= 1024 else { throw ProviderError.invalidResponse }
        return ([], slots.filter(\.is_processing).count)
      }
    } catch let error as ProviderError { throw error } catch { throw ProviderError.invalidResponse }
  }

  private static func validIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1024,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw ProviderError.invalidResponse }
  }
}

private struct OllamaResponse: Decodable { let models: [OllamaModel] }
private struct OllamaModel: Decodable {
  let name: String
  let digest: String
  let size: UInt64?
  let size_vram: UInt64?
}
private struct LMResponse: Decodable { let models: [LMModel] }
private struct LMModel: Decodable {
  let key: String
  let display_name: String?
  let loaded_instances: [LMInstance]
}
private struct LMInstance: Decodable { let id: String }
private struct LlamaSlot: Decodable { let is_processing: Bool }
