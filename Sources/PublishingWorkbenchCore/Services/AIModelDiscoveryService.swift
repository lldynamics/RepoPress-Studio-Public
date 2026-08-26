import CryptoKit
import Foundation

public protocol AIModelDiscoveryTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionAIModelDiscoveryTransport: AIModelDiscoveryTransport {
  private let session: URLSession

  public init() {
    // This overload has no caller-provided proxy to validate, so use the
    // infallible hardened factory instead of retaining an unnecessary crash
    // point. Profile-bound discovery uses the throwing initializer below.
    let safeSession = CredentialSafeURLSession.make(
      timeoutIntervalForRequest: AIModelDiscoveryService.requestTimeout,
      timeoutIntervalForResource: 30
    )
    self.init(safeSession: safeSession)
  }

  /// Creates a discovery session bound to the selected profile's proxy. The
  /// strict credential-safe factory rejects malformed proxy values instead of
  /// silently falling back to a direct connection.
  public init(proxyURL: String?) throws {
    let safeSession = try CredentialSafeURLSession.makeValidated(
      timeoutIntervalForRequest: AIModelDiscoveryService.requestTimeout,
      timeoutIntervalForResource: 30,
      proxyURL: proxyURL
    )
    self.init(safeSession: safeSession)
  }

  private init(safeSession: URLSession) {
    // Keep the hardened ephemeral configuration (cookies disabled, bounded
    // timeouts, and proxy support) while installing a discovery-specific
    // delegate that rejects a cross-origin redirect before URLSession follows
    // it. The generic credential delegate intentionally strips headers on a
    // redirect; model discovery must additionally fail closed for local
    // no-key requests, where a stripped redirect would otherwise still make a
    // request to the wrong service.
    session = URLSession(
      configuration: safeSession.configuration,
      delegate: AIModelDiscoveryURLSessionDelegate(),
      delegateQueue: nil
    )
    safeSession.invalidateAndCancel()
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: AIModelDiscoveryService.maximumResponseByteCount
    )
  }
}

public enum AIModelDiscoveryError: LocalizedError, Equatable, Sendable {
  case missingAPIKey
  case unsupportedProvider
  case invalidProxyURL
  case invalidEndpoint
  case insecureEndpoint
  case redirectBlocked
  case invalidResponse
  case responseTooLarge(maximumBytes: Int)
  case httpStatus(Int, String, retryAfterSeconds: TimeInterval?)
  case paginationInvalid
  case paginationLoop
  case paginationLimitExceeded
  case configurationChanged
  case authorizationChanged

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return CoreL10n.text("请先保存 AI API Key，或关闭“需要 API Key”。")
    case .unsupportedProvider:
      return CoreL10n.text("当前 AI 连接不支持通过 HTTP 拉取模型列表。")
    case .invalidProxyURL:
      return CoreL10n.text("AI 代理地址无效或不受支持；请修正代理设置后重试。")
    case .invalidEndpoint:
      return CoreL10n.text("AI 模型接口地址无效或不受支持。")
    case .insecureEndpoint:
      return CoreL10n.text("模型发现已阻止不安全的 AI 接口地址；有 API Key 时仅允许 HTTPS。")
    case .redirectBlocked:
      return CoreL10n.text("模型发现已阻止跨来源或不安全的重定向。")
    case .invalidResponse:
      return CoreL10n.text("AI 模型服务返回了无效响应。")
    case .responseTooLarge(let maximumBytes):
      return CoreL10n.format("模型列表超过 %@ 字节的安全上限，已停止读取。", String(maximumBytes))
    case .httpStatus(let status, let body, let retryAfterSeconds):
      let retryHint =
        retryAfterSeconds.map {
          "\n服务器建议等待 \(Self.durationText($0)) 后再手动重试。"
        } ?? ""
      return "AI 模型列表请求失败：HTTP \(status)\n\(body)\(retryHint)"
    case .paginationInvalid:
      return CoreL10n.text("AI 模型服务返回了无效的分页游标。")
    case .paginationLoop:
      return CoreL10n.text("AI 模型服务返回了重复的分页游标，已停止读取。")
    case .paginationLimitExceeded:
      return CoreL10n.text("AI 模型列表分页次数超过安全上限，已停止读取。")
    case .configurationChanged:
      return CoreL10n.text("API 基础地址尚未应用；请先点击“应用地址”，再拉取模型。")
    case .authorizationChanged:
      return CoreL10n.text("AI 连接或授权状态已变化，请重试模型发现。")
    }
  }

  private static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 1 {
      return String(format: "%.1f 秒", seconds)
    }
    return "\(Int(ceil(seconds))) 秒"
  }
}

public struct AIModelDiscoveryService: Sendable {
  public static let requestTimeout: TimeInterval = 10.0
  public static let maximumResponseByteCount = 2 * 1024 * 1024
  public static let maximumPageCount = 8
  public static let maximumModelCount = 500
  private static let maximumCursorLength = 1_024

  private let transport: (any AIModelDiscoveryTransport)?
  private let cache: AIModelDiscoveryCache
  private let defaultTransportFactory: @Sendable (String?) throws -> any AIModelDiscoveryTransport

  public init(
    transport: (any AIModelDiscoveryTransport)? = nil,
    cache: AIModelDiscoveryCache = .shared
  ) {
    self.transport = transport
    self.cache = cache
    defaultTransportFactory = { proxyURL in
      try URLSessionAIModelDiscoveryTransport(proxyURL: proxyURL)
    }
  }

  /// Internal injection point for tests that need to observe the profile
  /// proxy without opening a real network session. Production calls use the
  /// strict default factory above.
  init(
    transport: (any AIModelDiscoveryTransport)? = nil,
    cache: AIModelDiscoveryCache = .shared,
    defaultTransportFactory:
      @escaping @Sendable (String?) throws
      -> any AIModelDiscoveryTransport
  ) {
    self.transport = transport
    self.cache = cache
    self.defaultTransportFactory = defaultTransportFactory
  }

  public func discoverModels(
    for config: AIProviderConfig,
    apiKey: String?,
    forceRefresh: Bool = true
  ) async throws -> [AIModelDescriptor] {
    try Task.checkCancellation()
    // A key is meaningful only for providers that explicitly require one.
    // This prevents an accidental credential from being sent to a local
    // endpoint or being incorporated into its cache identity.
    let normalizedAPIKey = config.requiresAPIKey ? apiKey?.nilIfEmpty : nil
    guard !config.usesCodexAppServer else {
      throw AIModelDiscoveryError.unsupportedProvider
    }
    guard !config.requiresAPIKey || normalizedAPIKey != nil else {
      throw AIModelDiscoveryError.missingAPIKey
    }
    guard let url = modelsEndpointURL(for: config) else {
      throw AIModelDiscoveryError.invalidEndpoint
    }
    guard
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        url,
        hasCredential: normalizedAPIKey != nil
      )
    else {
      throw AIModelDiscoveryError.insecureEndpoint
    }

    let requestTransport: any AIModelDiscoveryTransport
    if let transport {
      requestTransport = transport
    } else {
      do {
        requestTransport = try defaultTransportFactory(
          config.resolvedAdvancedSettings.proxyURL
        )
      } catch {
        throw AIModelDiscoveryError.invalidProxyURL
      }
    }

    let cacheKey = Self.cacheKey(for: config, apiKey: normalizedAPIKey)
    if !forceRefresh, let cachedModels = await cache.value(for: cacheKey) {
      try Task.checkCancellation()
      return cachedModels
    }

    var models: [AIModelDescriptor] = []
    var seenModelIDs: Set<String> = []
    var seenCursors: Set<String> = []
    var nextURL = url

    for pageIndex in 0..<Self.maximumPageCount {
      try Task.checkCancellation()
      let page = try await fetchPage(
        at: nextURL,
        endpointURL: url,
        config: config,
        apiKey: normalizedAPIKey,
        transport: requestTransport
      )

      for model in page.models {
        guard models.count < Self.maximumModelCount else {
          // Return a bounded list, but do not cache a result that may be a
          // truncation of the provider's catalog.
          return models.sorted(by: sortModels)
        }
        guard seenModelIDs.insert(model.id).inserted else { continue }
        models.append(model)
      }

      guard page.hasMore else {
        let result = models.sorted(by: sortModels)
        try Task.checkCancellation()
        let insertionToken = await cache.insert(result, for: cacheKey)
        do {
          try Task.checkCancellation()
        } catch {
          // A refresh can be cancelled after the actor writes its entry. Only
          // remove the entry created by this refresh; a concurrent refresh
          // for the same account may already have replaced it.
          if let insertionToken {
            await cache.removeValue(for: cacheKey, ifGeneration: insertionToken)
          }
          throw error
        }
        return result
      }

      guard pageIndex + 1 < Self.maximumPageCount else {
        throw AIModelDiscoveryError.paginationLimitExceeded
      }
      guard let cursor = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
        !cursor.isEmpty,
        cursor.utf8.count <= Self.maximumCursorLength
      else {
        throw AIModelDiscoveryError.paginationInvalid
      }
      guard seenCursors.insert(cursor).inserted else {
        throw AIModelDiscoveryError.paginationLoop
      }
      guard
        let pageURL = pageURL(
          from: url,
          config: config,
          cursor: cursor
        ),
        Self.isSameOrigin(url, pageURL),
        CredentialedEndpointPolicy.isAllowedAIRequestURL(
          pageURL,
          hasCredential: normalizedAPIKey != nil
        )
      else {
        throw AIModelDiscoveryError.invalidEndpoint
      }
      nextURL = pageURL
    }

    throw AIModelDiscoveryError.paginationLimitExceeded
  }

  private func fetchPage(
    at requestURL: URL,
    endpointURL: URL,
    config: AIProviderConfig,
    apiKey: String?,
    transport: any AIModelDiscoveryTransport
  ) async throws -> ModelPage {
    guard Self.isSameOrigin(endpointURL, requestURL),
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        requestURL,
        hasCredential: apiKey != nil
      )
    else {
      throw AIModelDiscoveryError.invalidEndpoint
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "GET"
    request.timeoutInterval = Self.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if config.usesAnthropicAPI {
      if let apiKey {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      }
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if let apiKey {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch let error as HTTPResponseLimitError {
      throw AIModelDiscoveryError.responseTooLarge(maximumBytes: error.maximumByteCount)
    }
    try Task.checkCancellation()
    do {
      try BoundedHTTPResponseLoader.validate(
        data,
        response: response,
        maximumByteCount: Self.maximumResponseByteCount
      )
    } catch let error as HTTPResponseLimitError {
      throw AIModelDiscoveryError.responseTooLarge(maximumBytes: error.maximumByteCount)
    }
    guard let responseURL = response.url else {
      throw AIModelDiscoveryError.invalidResponse
    }
    guard Self.isSameOrigin(requestURL, responseURL) else {
      throw AIModelDiscoveryError.redirectBlocked
    }
    guard
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        responseURL,
        hasCredential: apiKey != nil
      )
    else {
      throw AIModelDiscoveryError.redirectBlocked
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AIModelDiscoveryError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      if (300..<400).contains(httpResponse.statusCode),
        httpResponse.value(forHTTPHeaderField: "Location")?.nilIfEmpty != nil
      {
        throw AIModelDiscoveryError.redirectBlocked
      }
      let body = HTTPErrorResponseSanitizer.sanitize(
        data: data,
        sensitiveValues: [apiKey].compactMap { $0 }
      )
      throw AIModelDiscoveryError.httpStatus(
        httpResponse.statusCode,
        body,
        retryAfterSeconds: AIChatCompletionClient.retryAfterInterval(
          from: httpResponse.value(forHTTPHeaderField: "Retry-After")
        )
      )
    }

    return try parsePage(from: data)
  }

  private func pageURL(
    from endpointURL: URL,
    config: AIProviderConfig,
    cursor: String
  ) -> URL? {
    guard
      var components = URLComponents(
        url: endpointURL,
        resolvingAgainstBaseURL: false
      )
    else {
      return nil
    }
    let cursorName = config.usesAnthropicAPI ? "after_id" : "after"
    var queryItems = components.queryItems ?? []
    queryItems.removeAll { item in
      item.name == cursorName || item.name == "limit"
    }
    queryItems.append(URLQueryItem(name: cursorName, value: cursor))
    // Anthropic's endpoint permits up to 1,000 models per page. Asking for
    // that bounded maximum reduces round trips while keeping URL construction
    // entirely under the client's control.
    if config.usesAnthropicAPI {
      queryItems.append(URLQueryItem(name: "limit", value: "1000"))
    }
    components.queryItems = queryItems
    return components.url
  }

  public func modelsEndpointURL(for config: AIProviderConfig) -> URL? {
    let trimmed = config.normalizedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let baseURL = URL(string: trimmed),
      let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      components.scheme != nil,
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }
    if config.preset == .local && (trimmed.hasSuffix(":11434") || trimmed.hasSuffix(":11434/v1")) {
      let root = trimmed.replacingOccurrences(of: "/v1", with: "")
      return URL(string: root + "/api/tags")
    }
    return URL(string: trimmed + "/models")
  }

  public func parseModels(from data: Data) -> [AIModelDescriptor] {
    (try? parsePage(from: data))?.models ?? []
  }

  private func parsePage(from data: Data) throws -> ModelPage {
    // 1. Standard OpenAI-compatible and Anthropic format:
    // {"data":[{"id":"..."}],"has_more":true,"last_id":"..."}
    if let openAIPayload = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) {
      var seen: Set<String> = []
      let models: [AIModelDescriptor] = openAIPayload.data.compactMap {
        item -> AIModelDescriptor? in
        let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, seen.insert(id).inserted else { return nil }
        return descriptor(for: id)
      }
      return ModelPage(
        models: models.sorted(by: sortModels),
        hasMore: openAIPayload.hasMore ?? false,
        nextCursor: openAIPayload.lastID
      )
    }

    // 2. Ollama format: {"models":[{"name":"..."}]}. Ollama does not
    // expose a cursor, so it is intentionally always a single page.
    if let ollamaPayload = try? JSONDecoder().decode(OllamaModelsResponse.self, from: data) {
      var seen: Set<String> = []
      let models: [AIModelDescriptor] = ollamaPayload.models.compactMap {
        item -> AIModelDescriptor? in
        let name =
          item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? item.model?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? ""
        guard !name.isEmpty, seen.insert(name).inserted else { return nil }
        return descriptor(for: name)
      }
      return ModelPage(models: models.sorted(by: sortModels), hasMore: false, nextCursor: nil)
    }

    throw AIModelDiscoveryError.invalidResponse
  }

  private static func cacheKey(
    for config: AIProviderConfig,
    apiKey: String?
  ) -> String {
    let material = [
      "model-discovery-v1",
      config.preset.rawValue,
      config.dataSharingConsentIdentifier,
      config.capabilityEndpointIdentity,
      config.normalizedModel,
      config.requiresAPIKey ? "credentialed" : "anonymous",
      config.resolvedAdvancedSettings.proxyURL?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? "direct",
      apiKey.map(digest) ?? "no-credential",
    ].joined(separator: "\u{001F}")
    return digest(material)
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func descriptor(for id: String) -> AIModelDescriptor {
    let lower = id.lowercased()
    let isReasoning =
      lower.contains("r1") || lower.contains("reasoner") || lower.contains("o1")
      || lower.contains("o3") || lower.contains("thinking")
    let isVision =
      lower.contains("vision") || lower.contains("vl") || lower.contains("4o")
      || lower.contains("gemini") || lower.contains("claude")
    return AIModelDescriptor(
      id: id,
      name: id,
      isReasoning: isReasoning,
      isVision: isVision,
      isChat: true
    )
  }

  private func sortModels(_ lhs: AIModelDescriptor, _ rhs: AIModelDescriptor) -> Bool {
    if lhs.isReasoning != rhs.isReasoning {
      return lhs.isReasoning && !rhs.isReasoning
    }
    return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
  }

  fileprivate static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsScheme = lhs.scheme?.lowercased(),
      let rhsScheme = rhs.scheme?.lowercased(),
      let lhsHost = lhs.host?.lowercased(),
      let rhsHost = rhs.host?.lowercased(),
      !lhsHost.isEmpty,
      !rhsHost.isEmpty
    else {
      return false
    }
    let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
    let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
    return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
  }

}

private final class AIModelDiscoveryURLSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let sourceURL = response.url ?? task.currentRequest?.url,
      let destinationURL = request.url,
      AIModelDiscoveryService.isSameOrigin(sourceURL, destinationURL),
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        destinationURL,
        hasCredential: request.value(forHTTPHeaderField: "Authorization")?.nilIfEmpty != nil
          || request.value(forHTTPHeaderField: "x-api-key")?.nilIfEmpty != nil
      )
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

private struct OpenAIModelsResponse: Decodable {
  struct Item: Decodable {
    var id: String
  }
  var data: [Item]
  var hasMore: Bool?
  var lastID: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case lastID = "last_id"
  }
}

private struct OllamaModelsResponse: Decodable {
  struct Item: Decodable {
    var name: String?
    var model: String?
  }
  var models: [Item]
}

private struct ModelPage: Sendable {
  let models: [AIModelDescriptor]
  let hasMore: Bool
  let nextCursor: String?
}
