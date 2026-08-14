import Foundation

public enum LocalAIEngineKind: String, CaseIterable, Codable, Hashable, Sendable {
  case ollama
  case lmStudio
  case vLLM
  case mlx

  public var displayName: String {
    switch self {
    case .ollama:
      return "Ollama"
    case .lmStudio:
      return "LM Studio"
    case .vLLM:
      return "vLLM"
    case .mlx:
      return "MLX"
    }
  }

  public var localizedTitle: String { displayName }
}

public struct LocalAIEngineDiscoveryResult: Codable, Hashable, Sendable {
  public var kind: LocalAIEngineKind
  public var baseURL: String
  public var isAvailable: Bool
  public var models: [String]
  public var message: String

  public init(
    kind: LocalAIEngineKind,
    baseURL: String,
    isAvailable: Bool,
    models: [String],
    message: String
  ) {
    self.kind = kind
    self.baseURL = baseURL
    self.isAvailable = isAvailable
    self.models = models
    self.message = message
  }
}

public protocol LocalAIEngineDiscoveryTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct LocalAIEngineDiscoveryService: Sendable {
  public static let requestTimeout: TimeInterval = 1.5
  public static let maximumResponseByteCount = 512 * 1_024

  private let transport: any LocalAIEngineDiscoveryTransport

  public init() {
    transport = URLSessionLocalAIEngineDiscoveryTransport()
  }

  public init(transport: any LocalAIEngineDiscoveryTransport) {
    self.transport = transport
  }

  public func discoverAll() async -> [LocalAIEngineDiscoveryResult] {
    let endpoints = LocalAIEngineDiscoveryEndpoint.all
    return await withTaskGroup(of: LocalAIEngineDiscoveryResult.self) { group in
      for endpoint in endpoints {
        group.addTask {
          await discover(endpoint)
        }
      }

      var resultByKind: [LocalAIEngineKind: LocalAIEngineDiscoveryResult] = [:]
      for await result in group {
        resultByKind[result.kind] = result
      }
      return endpoints.compactMap { resultByKind[$0.kind] }
    }
  }

  private func discover(
    _ endpoint: LocalAIEngineDiscoveryEndpoint
  ) async -> LocalAIEngineDiscoveryResult {
    guard let modelsURL = URL(string: endpoint.modelsURL),
          Self.isStrictLoopbackURL(modelsURL) else {
      return unavailableResult(endpoint, reason: .unsafeEndpoint)
    }

    var request = URLRequest(url: modelsURL)
    request.httpMethod = "GET"
    request.timeoutInterval = Self.requestTimeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await transport.data(for: request)
      try BoundedHTTPResponseLoader.validate(
        data,
        response: response,
        maximumByteCount: Self.maximumResponseByteCount
      )
      guard let responseURL = response.url,
            Self.isStrictLoopbackURL(responseURL),
            Self.isSameOrigin(modelsURL, responseURL) else {
        return unavailableResult(endpoint, reason: .unsafeResponse)
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        return unavailableResult(endpoint, reason: .invalidResponse)
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        return unavailableResult(endpoint, reason: .httpStatus(httpResponse.statusCode))
      }

      let models: [String]
      do {
        models = try Self.models(from: data, parser: endpoint.parser)
      } catch {
        return unavailableResult(endpoint, reason: .invalidPayload)
      }

      let message = models.isEmpty
        ? CoreL10n.text("本地服务可用，但未返回模型。")
        : CoreL10n.format("已检测到 %d 个本地模型。", models.count)
      return LocalAIEngineDiscoveryResult(
        kind: endpoint.kind,
        baseURL: endpoint.baseURL,
        isAvailable: true,
        models: models,
        message: message
      )
    } catch is CancellationError {
      return unavailableResult(endpoint, reason: .cancelled)
    } catch is HTTPResponseLimitError {
      return unavailableResult(endpoint, reason: .responseTooLarge)
    } catch {
      return unavailableResult(endpoint, reason: .unreachable)
    }
  }

  private static func models(
    from data: Data,
    parser: LocalAIEngineDiscoveryEndpoint.Parser
  ) throws -> [String] {
    let rawModels: [String]
    switch parser {
    case .ollama:
      let payload = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
      rawModels = payload.models.compactMap { model in
        let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return model.model
      }
    case .openAICompatible:
      let payload = try JSONDecoder().decode(OpenAICompatibleModelsResponse.self, from: data)
      rawModels = payload.data.map(\.id)
    }
    return normalizedModels(rawModels)
  }

  private static func normalizedModels(_ models: [String]) -> [String] {
    var seen: Set<String> = []
    return models
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .sorted { lhs, rhs in
        let comparison = lhs.compare(
          rhs,
          options: [.caseInsensitive, .diacriticInsensitive],
          range: nil,
          locale: Locale(identifier: "en_US_POSIX")
        )
        if comparison == .orderedSame {
          return lhs < rhs
        }
        return comparison == .orderedAscending
      }
  }

  private static func isStrictLoopbackURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http",
          url.user == nil,
          url.password == nil,
          url.query == nil,
          url.fragment == nil,
          let rawHost = url.host else {
      return false
    }
    let host = rawHost
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    if host == "localhost" || host == "::1" {
      return true
    }
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
          octets.allSatisfy({ !$0.isEmpty && UInt8($0) != nil }) else {
      return false
    }
    return octets[0] == "127"
  }

  private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsScheme = lhs.scheme?.lowercased(),
          let rhsScheme = rhs.scheme?.lowercased(),
          let lhsHost = lhs.host?.lowercased(),
          let rhsHost = rhs.host?.lowercased() else {
      return false
    }
    let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
    let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
    return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
  }

  private func unavailableResult(
    _ endpoint: LocalAIEngineDiscoveryEndpoint,
    reason: LocalAIEngineDiscoveryFailureReason
  ) -> LocalAIEngineDiscoveryResult {
    LocalAIEngineDiscoveryResult(
      kind: endpoint.kind,
      baseURL: endpoint.baseURL,
      isAvailable: false,
      models: [],
      message: reason.message
    )
  }
}

private struct LocalAIEngineDiscoveryEndpoint: Sendable {
  enum Parser: Sendable {
    case ollama
    case openAICompatible
  }

  var kind: LocalAIEngineKind
  var baseURL: String
  var modelsURL: String
  var parser: Parser

  static let all: [LocalAIEngineDiscoveryEndpoint] = [
    LocalAIEngineDiscoveryEndpoint(
      kind: .ollama,
      baseURL: "http://127.0.0.1:11434/v1",
      modelsURL: "http://127.0.0.1:11434/api/tags",
      parser: .ollama
    ),
    LocalAIEngineDiscoveryEndpoint(
      kind: .lmStudio,
      baseURL: "http://127.0.0.1:1234/v1",
      modelsURL: "http://127.0.0.1:1234/v1/models",
      parser: .openAICompatible
    ),
    LocalAIEngineDiscoveryEndpoint(
      kind: .vLLM,
      baseURL: "http://127.0.0.1:8000/v1",
      modelsURL: "http://127.0.0.1:8000/v1/models",
      parser: .openAICompatible
    ),
    LocalAIEngineDiscoveryEndpoint(
      kind: .mlx,
      baseURL: "http://127.0.0.1:8080/v1",
      modelsURL: "http://127.0.0.1:8080/v1/models",
      parser: .openAICompatible
    ),
  ]
}

private enum LocalAIEngineDiscoveryFailureReason {
  case unsafeEndpoint
  case unsafeResponse
  case invalidResponse
  case httpStatus(Int)
  case invalidPayload
  case responseTooLarge
  case unreachable
  case cancelled

  var message: String {
    switch self {
    case .unsafeEndpoint, .unsafeResponse:
      return CoreL10n.text("已阻止非本机探测响应。")
    case .invalidResponse:
      return CoreL10n.text("本地服务返回了无效响应。")
    case let .httpStatus(statusCode):
      return CoreL10n.format("本地服务响应异常（HTTP %d）。", statusCode)
    case .invalidPayload:
      return CoreL10n.text("本地服务响应格式无法识别。")
    case .responseTooLarge:
      return CoreL10n.text("本地服务响应超过安全上限。")
    case .unreachable:
      return CoreL10n.text("未检测到本地服务。")
    case .cancelled:
      return CoreL10n.text("本地服务探测已取消。")
    }
  }
}

private struct OllamaModelsResponse: Decodable {
  struct Model: Decodable {
    var name: String?
    var model: String?
  }

  var models: [Model]
}

private struct OpenAICompatibleModelsResponse: Decodable {
  struct Model: Decodable {
    var id: String
  }

  var data: [Model]
}

private struct URLSessionLocalAIEngineDiscoveryTransport: LocalAIEngineDiscoveryTransport {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = LocalAIEngineDiscoveryService.requestTimeout
    configuration.timeoutIntervalForResource = LocalAIEngineDiscoveryService.requestTimeout
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration,
      delegate: LocalAIEngineDiscoveryURLSessionDelegate(),
      delegateQueue: nil
    )
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: LocalAIEngineDiscoveryService.maximumResponseByteCount
    )
  }
}

private final class LocalAIEngineDiscoveryURLSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
