import Foundation

public struct AIProviderCapabilityProbeOptions: Equatable, Sendable {
  public var capabilities: Set<AIProviderCapabilityProbeKind>
  public var forceRefresh: Bool

  public init(
    capabilities: Set<AIProviderCapabilityProbeKind> = [],
    forceRefresh: Bool = false
  ) {
    self.capabilities = capabilities
    self.forceRefresh = forceRefresh
  }

  public static let connectionOnly = Self()
}

/// Internal proof that a successful connection response belongs to the exact
/// endpoint/model/schema key being probed. It prevents a convenient response
/// from one connection profile being silently reused for another profile.
struct AIProviderCapabilityChatProbeProof: Sendable {
  let key: AIProviderCapabilityCacheKey
  let result: AIChatCompletionResult
}

public enum AIProviderCapabilityProbeError: LocalizedError, Equatable, Sendable {
  case missingBaseURL
  case invalidBaseURL(String)
  case missingModel
  case missingAPIKey

  public var errorDescription: String? {
    switch self {
    case .missingBaseURL:
      return CoreL10n.text("API Base URL 尚未配置。")
    case .invalidBaseURL(let value):
      return CoreL10n.format("AI 接口地址无效：%@", value)
    case .missingModel:
      return CoreL10n.text("请先填写 AI 模型名称。")
    case .missingAPIKey:
      return CoreL10n.text("请先保存 AI API Key，或关闭“需要 API Key”。")
    }
  }
}

/// Probes the selected endpoint/model with protocol-minimal requests. It does
/// not read Keychain, and callers must provide the already-authorized token.
public struct AIProviderCapabilityProbeService: Sendable {
  public static let defaultTTL: TimeInterval = 15 * 60
  /// A fixed, synthetic 1x1 PNG. It is deliberately embedded in the probe
  /// code so a vision probe can never accidentally read a user/site image.
  static let syntheticVisionFixtureDataURL =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  private let client: AIChatCompletionClient
  private let cache: AIProviderCapabilityProbeCache
  private let ttl: TimeInterval
  private let now: @Sendable () -> Date
  private let probeSchemaVersion: Int

  public init(
    client: AIChatCompletionClient = AIChatCompletionClient(),
    cache: AIProviderCapabilityProbeCache = AIProviderCapabilityProbeCache(),
    ttl: TimeInterval = Self.defaultTTL,
    now: @escaping @Sendable () -> Date = { @Sendable in Date() },
    probeSchemaVersion: Int = AIProviderCapabilityCacheKey.currentProbeSchemaVersion
  ) {
    self.client = client
    self.cache = cache
    self.ttl = max(0, ttl)
    self.now = now
    self.probeSchemaVersion = probeSchemaVersion
  }

  public func probe(
    config: AIProviderConfig,
    apiKey: String?,
    capabilities: Set<AIProviderCapabilityProbeKind>,
    forceRefresh: Bool = false
  ) async throws -> AIProviderCapabilityProbeReport {
    try await probe(
      config: config,
      apiKey: apiKey,
      capabilities: capabilities,
      forceRefresh: forceRefresh,
      existingChatProof: nil
    )
  }

  func probe(
    config: AIProviderConfig,
    apiKey: String?,
    capabilities: Set<AIProviderCapabilityProbeKind>,
    forceRefresh: Bool = false,
    existingChatProof: AIProviderCapabilityChatProbeProof?
  ) async throws -> AIProviderCapabilityProbeReport {
    try validate(config: config, apiKey: apiKey)

    let key = AIProviderCapabilityCacheKey(
      preset: config.preset,
      endpointIdentity: config.capabilityEndpointIdentity,
      model: config.normalizedModel,
      probeSchemaVersion: probeSchemaVersion
    )
    let requested = capabilities.sorted { $0.rawValue < $1.rawValue }
    let generatedAt = now()
    let cachedEntry = await cache.entry(for: key)
    try Task.checkCancellation()
    var results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult] = [:]

    if !forceRefresh, let cachedEntry {
      for capability in requested {
        guard let cached = cachedEntry.results[capability],
          cached.evidence.key == key,
          cached.evidence.isCurrent(at: generatedAt, schemaVersion: probeSchemaVersion)
        else {
          continue
        }
        results[capability] = Self.cachedResult(cached)
      }
    }

    let cachedCount = results.count
    for capability in requested where results[capability] == nil {
      try Task.checkCancellation()
      if capability == .chat,
        let existingChatProof,
        existingChatProof.key == key
      {
        // The connection test already proved that a normal completion was
        // accepted. Reuse that response as the selected chat probe rather
        // than charging/sending an identical second request.
        results[capability] = result(
          capability: capability,
          outcome: .supported,
          key: key,
          observedAt: generatedAt,
          responseModel: existingChatProof.result.rawModel
        )
      } else {
        results[capability] = try await probeOne(
          capability: capability,
          config: config,
          apiKey: apiKey,
          key: key,
          observedAt: generatedAt
        )
      }
      try Task.checkCancellation()
    }

    if !requested.isEmpty {
      let expiry = generatedAt.addingTimeInterval(ttl)
      var storedResults = cachedEntry?.results ?? [:]
      storedResults.merge(results) { _, new in new }
      let entry = AIProviderCapabilityProbeCacheEntry(
        key: key,
        results: storedResults,
        storedAt: generatedAt,
        expiresAt: expiry
      )
      try Task.checkCancellation()
      guard await cache.storeUnlessCancelled(entry) else {
        throw CancellationError()
      }
    }

    let cacheState: AIProviderCapabilityProbeCacheState
    if forceRefresh {
      cacheState = .forcedRefresh
    } else if requested.isEmpty {
      cacheState = .miss
    } else if cachedCount == requested.count {
      cacheState = .hit
    } else if cachedCount > 0 {
      cacheState = .partialHit
    } else if requested.contains(where: { cachedEntry?.results[$0] != nil }) {
      cacheState = .expired
    } else {
      cacheState = .miss
    }

    try Task.checkCancellation()
    return AIProviderCapabilityProbeReport(
      key: key,
      results: results,
      cacheState: cacheState,
      generatedAt: generatedAt
    )
  }

  public func probe(
    config: AIProviderConfig,
    apiKey: String?,
    options: AIProviderCapabilityProbeOptions,
  ) async throws -> AIProviderCapabilityProbeReport {
    try await probe(
      config: config,
      apiKey: apiKey,
      capabilities: options.capabilities,
      forceRefresh: options.forceRefresh
    )
  }

  public func cachedEntry(
    for config: AIProviderConfig
  ) async -> AIProviderCapabilityProbeCacheEntry? {
    let key = AIProviderCapabilityCacheKey(
      preset: config.preset,
      endpointIdentity: config.capabilityEndpointIdentity,
      model: config.normalizedModel,
      probeSchemaVersion: probeSchemaVersion
    )
    return await cache.entry(for: key)
  }

  private func validate(config: AIProviderConfig, apiKey: String?) throws {
    guard !config.normalizedBaseURL.isEmpty else {
      throw AIProviderCapabilityProbeError.missingBaseURL
    }
    guard !config.normalizedModel.isEmpty else {
      throw AIProviderCapabilityProbeError.missingModel
    }
    if config.requiresAPIKey, apiKey?.nilIfEmpty == nil {
      throw AIProviderCapabilityProbeError.missingAPIKey
    }
    guard config.chatCompletionsURL != nil else {
      throw AIProviderCapabilityProbeError.invalidBaseURL(config.normalizedBaseURL)
    }
  }

  private func probeOne(
    capability: AIProviderCapabilityProbeKind,
    config: AIProviderConfig,
    apiKey: String?,
    key: AIProviderCapabilityCacheKey,
    observedAt: Date
  ) async throws -> AIProviderCapabilityProbeResult {
    do {
      let probeResult: AIProviderCapabilityProbeResult
      switch capability {
      case .chat:
        let response = try await client.complete(
          request: minimalRequest(for: config),
          config: config,
          apiKey: apiKey?.nilIfEmpty,
          purpose: .capabilityProbe
        )
        probeResult = result(
          capability: capability,
          outcome: .supported,
          key: key,
          observedAt: observedAt,
          responseModel: response.rawModel
        )

      case .streamingResponse:
        let stream = try await client.stream(
          request: minimalRequest(for: config),
          config: config,
          apiKey: apiKey?.nilIfEmpty,
          purpose: .capabilityProbe
        )
        var receivedEvent = false
        for try await _ in stream {
          try Task.checkCancellation()
          receivedEvent = true
        }
        probeResult = result(
          capability: capability,
          outcome: receivedEvent ? .supported : .inconclusive,
          key: key,
          observedAt: observedAt
        )

      case .toolCalling:
        let response = try await client.complete(
          request: toolCallingRequest(for: config),
          config: config,
          apiKey: apiKey?.nilIfEmpty,
          purpose: .capabilityProbe
        )
        probeResult = result(
          capability: capability,
          outcome: isValidToolProbeResponse(response) ? .supported : .inconclusive,
          key: key,
          observedAt: observedAt,
          responseModel: response.rawModel
        )

      case .structuredOutput:
        let response = try await client.complete(
          request: structuredOutputRequest(for: config),
          config: config,
          apiKey: apiKey?.nilIfEmpty,
          purpose: .capabilityProbe
        )
        let outcome: AIProviderCapabilityProbeOutcome =
          isValidStructuredProbeResponse(response.content)
          ? .supported
          : .inconclusive
        probeResult = result(
          capability: capability,
          outcome: outcome,
          key: key,
          observedAt: observedAt,
          responseModel: response.rawModel
        )

      case .visionInput:
        let response = try await client.complete(
          request: visionProbeRequest(for: config),
          config: config,
          apiKey: apiKey?.nilIfEmpty,
          purpose: .capabilityProbe
        )
        let outcome: AIProviderCapabilityProbeOutcome =
          isValidVisionProbeResponse(response.content)
          ? .supported
          : .inconclusive
        probeResult = result(
          capability: capability,
          outcome: outcome,
          key: key,
          observedAt: observedAt,
          detail: outcome == .supported
            ? nil
            : AIProviderCapabilityRejectionClassifier.inconclusiveDetail
        )
      }
      try Task.checkCancellation()
      return probeResult
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as AIChatCompletionClientError {
      let classification = classify(error, capability: capability)
      try Task.checkCancellation()
      return result(
        capability: capability,
        outcome: classification.outcome,
        key: key,
        observedAt: observedAt,
        statusCode: classification.statusCode,
        detail: classification.detail
      )
    } catch {
      try Task.checkCancellation()
      return result(
        capability: capability,
        outcome: .inconclusive,
        key: key,
        observedAt: observedAt,
        detail: "transport failure"
      )
    }
  }

  private func minimalRequest(for config: AIProviderConfig) -> AIChatCompletionRequest {
    AIChatCompletionRequest(
      model: config.normalizedModel,
      messages: [
        AIChatMessage(role: "system", content: "Return only OK."),
        AIChatMessage(role: "user", content: "ping"),
      ],
      temperature: 0,
      maximumOutputTokens: 8
    )
  }

  private func toolCallingRequest(for config: AIProviderConfig) -> AIChatCompletionRequest {
    let schema: AIStructuredOutputJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "ok": .object(["type": .string("boolean")])
      ]),
      "required": .array([.string("ok")]),
      "additionalProperties": .bool(false),
    ])
    return AIChatCompletionRequest(
      model: config.normalizedModel,
      messages: [AIChatMessage(role: "user", content: "Call the probe function.")],
      maximumOutputTokens: 16,
      tools: [
        AIToolDefinition(
          function: AIToolFunctionDefinition(
            name: "capability_probe",
            description: "Return the fixed probe result without side effects.",
            parameters: schema,
            strict: true
          )
        )
      ],
      toolChoice: .required
    )
  }

  private func structuredOutputRequest(for config: AIProviderConfig) -> AIChatCompletionRequest {
    let schema: AIStructuredOutputJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "ok": .object(["type": .string("boolean")])
      ]),
      "required": .array([.string("ok")]),
      "additionalProperties": .bool(false),
    ])
    return AIChatCompletionRequest(
      model: config.normalizedModel,
      messages: [AIChatMessage(role: "user", content: "Return the requested JSON object.")],
      maximumOutputTokens: 16,
      responseFormat: .jsonSchema(
        AIStructuredOutputJSONSchema(
          name: "capability_probe",
          description: "A fixed capability probe response.",
          schema: schema,
          strict: true
        )
      )
    )
  }

  private func visionProbeRequest(for config: AIProviderConfig) -> AIChatCompletionRequest {
    AIChatCompletionRequest(
      model: config.normalizedModel,
      messages: [
        AIChatMessage(
          role: "user",
          content: .parts([
            .text(
              "Inspect the attached image. Reply exactly with its width and height as WIDTHxHEIGHT, with no other text."
            ),
            .imageURL(Self.syntheticVisionFixtureDataURL),
          ])
        )
      ],
      maximumOutputTokens: 8
    )
  }

  private func isValidVisionProbeResponse(_ content: String) -> Bool {
    content
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "×", with: "x") == "1x1"
  }

  private func isValidStructuredProbeResponse(_ content: String) -> Bool {
    guard let data = content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["ok"],
      let ok = object["ok"] as? Bool
    else {
      return false
    }
    return ok
  }

  private func isValidToolProbeResponse(_ response: AIChatCompletionResult) -> Bool {
    guard response.toolCalls.count == 1,
      let toolCall = response.toolCalls.first,
      toolCall.type == "function",
      toolCall.function.name == "capability_probe",
      let data = toolCall.function.arguments.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["ok"],
      let ok = object["ok"] as? Bool
    else {
      return false
    }
    return ok
  }

  private struct Classification: Sendable {
    let outcome: AIProviderCapabilityProbeOutcome
    let statusCode: Int?
    let detail: String
  }

  private func classify(
    _ error: AIChatCompletionClientError,
    capability: AIProviderCapabilityProbeKind
  ) -> Classification {
    if case .httpStatus(let status, let body, _) = error {
      if [400, 404, 405, 422].contains(status),
        AIProviderCapabilityRejectionClassifier.explicitlyRejects(
          body,
          capability: capability
        )
      {
        return Classification(
          outcome: .unsupported,
          statusCode: status,
          detail: AIProviderCapabilityRejectionClassifier.fixedDetail(for: capability)
        )
      }
      return Classification(
        outcome: .inconclusive,
        statusCode: status,
        detail: AIProviderCapabilityRejectionClassifier.inconclusiveDetail
      )
    }
    return Classification(
      outcome: .inconclusive,
      statusCode: nil,
      detail: AIProviderCapabilityRejectionClassifier.inconclusiveDetail
    )
  }

  private func result(
    capability: AIProviderCapabilityProbeKind,
    outcome: AIProviderCapabilityProbeOutcome,
    key: AIProviderCapabilityCacheKey,
    observedAt: Date,
    statusCode: Int? = nil,
    responseModel: String? = nil,
    detail: String? = nil
  ) -> AIProviderCapabilityProbeResult {
    let evidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: capability,
      outcome: outcome,
      observedAt: observedAt,
      expiresAt: observedAt.addingTimeInterval(ttl),
      statusCode: statusCode,
      detail: detail
    )
    return AIProviderCapabilityProbeResult(
      capability: capability,
      outcome: outcome,
      statusCode: statusCode,
      responseModel: responseModel,
      responsePreview: nil,
      evidence: evidence
    )
  }

  private static func cachedResult(
    _ result: AIProviderCapabilityProbeResult
  ) -> AIProviderCapabilityProbeResult {
    AIProviderCapabilityProbeResult(
      capability: result.capability,
      outcome: result.outcome,
      statusCode: result.statusCode,
      responseModel: result.responseModel,
      responsePreview: result.responsePreview,
      evidence: result.evidence,
      fromCache: true
    )
  }
}
