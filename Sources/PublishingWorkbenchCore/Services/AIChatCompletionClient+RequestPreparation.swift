import CryptoKit
import Foundation

extension AIChatCompletionClient {
  public func complete(
    request completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    purpose: AIProviderRequestPurpose = .utilityTask
  ) async throws -> AIChatCompletionResult {
    let prepared = try prepareRequest(
      completionRequest,
      config: config,
      purpose: purpose,
      mode: .nonStreaming
    )
    return try await completePrepared(
      prepared,
      config: config,
      apiKey: apiKey
    )
  }

  /// Produces the exact normalized request and canonical body that a later
  /// transport call will use. This method never reads credentials or performs
  /// I/O, so privacy preview can inspect it safely.
  public func prepareRequest(
    _ completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    purpose: AIProviderRequestPurpose,
    mode: AIChatTransportMode,
    transformMessages: (@Sendable ([AIChatMessage]) throws -> [AIChatMessage])? = nil
  ) throws -> AIPreparedAIChatCompletionRequest {
    let url = try validatedRequestURL(config: config, apiKey: nil)
    if mode == .streaming,
      purpose != .capabilityProbe,
      config.capabilitySupport(for: .streamingResponse) != .supported
    {
      throw AIChatCompletionClientError.streamingUnsupported
    }
    var normalized = try normalizedRequest(
      completionRequest,
      config: config,
      purpose: purpose
    )
    if let transformMessages {
      normalized.messages = try sanitizedMessages(
        transformMessages(normalized.messages),
        canSendTools: purpose == .capabilityProbe
          || config.capabilitySupport(for: .toolCalling) == .supported,
        canSendVision: purpose == .capabilityProbe
          || config.capabilitySupport(for: .visionInput) == .supported
      )
    }
    switch mode {
    case .nonStreaming:
      normalized.stream = nil
      normalized.streamOptions = nil
    case .streaming:
      normalized.stream = true
      normalized.streamOptions = AIChatStreamOptions(includeUsage: true)
    }
    return AIPreparedAIChatCompletionRequest(
      normalizedRequest: normalized,
      endpointIdentity: config.capabilityEndpointIdentity,
      endpointURL: url,
      encodedBody: try encoder.encode(normalized),
      mode: mode,
      purpose: purpose,
      capabilitySupportSnapshot: capabilitySupportSnapshot(for: config),
      capabilityEvidenceSnapshot: config.capabilityProbeEvidence ?? [:],
      configurationFingerprint: try configurationFingerprint(for: config)
    )
  }

  public func completePrepared(
    _ prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIChatCompletionResult {
    guard prepared.mode == .nonStreaming else {
      throw AIChatCompletionClientError.preparedRequestModeMismatch
    }
    try validatePrepared(prepared, against: config, apiKey: apiKey)
    try prepared.consume()
    return try await sendCompletePrepared(
      prepared: prepared,
      config: config,
      apiKey: apiKey
    )
  }

  func sendCompletePrepared(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIChatCompletionResult {
    try validatePrepared(prepared, against: config, apiKey: apiKey)
    let url = try validatedRequestURL(config: config, apiKey: apiKey)
    guard url == prepared.endpointURL else {
      throw AIChatCompletionClientError.preparedRequestConfigurationMismatch
    }

    if config.usesCodexAppServer {
      return try await completeWithCodexAppServer(
        prepared: prepared,
        config: config
      )
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = networkRecoveryPolicy.firstByteTimeout
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = prepared.encodedBody
    let preparedRequest = request

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await performWithTimeout(
        seconds: networkRecoveryPolicy.resourceTimeout,
        timeoutError: .resourceTimedOut(networkRecoveryPolicy.resourceTimeout)
      ) {
        try await performPreparedDataTransport(
          prepared: prepared,
          config: config,
          apiKey: apiKey,
          request: preparedRequest
        )
      }
      try BoundedHTTPResponseLoader.validate(
        data,
        response: response,
        maximumByteCount: URLSessionAIChatTransport.maximumResponseByteCount
      )
    } catch let error as HTTPResponseLimitError {
      throw AIChatCompletionClientError.responseTooLarge(
        maximumBytes: error.maximumByteCount
      )
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AIChatCompletionClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = HTTPErrorResponseSanitizer.sanitize(
        data: data,
        sensitiveValues: [apiKey].compactMap { $0 }
      )
      throw httpError(statusResponse: httpResponse, body: body)
    }

    let payload = try decoder.decode(AIChatCompletionResponse.self, from: data)
    guard let message = payload.choices.first?.message else {
      throw AIChatCompletionClientError.emptyContent
    }
    let content = message.contentText
    let toolCalls = message.toolCalls ?? []
    guard content.nilIfEmpty != nil || !toolCalls.isEmpty else {
      throw AIChatCompletionClientError.emptyContent
    }
    return AIChatCompletionResult(
      content: content,
      toolCalls: toolCalls,
      rawModel: payload.model,
      tokenUsage: payload.usage?.tokenUsage
    )
  }

  private func performPreparedDataTransport(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    request: URLRequest
  ) async throws -> (Data, URLResponse) {
    // Revalidate immediately before crossing into the transport. The request
    // may have been waiting for task scheduling or a timeout race after the
    // initial validation/one-shot consumption above.
    try validatePrepared(prepared, against: config, apiKey: apiKey)
    return try await transport.data(for: request)
  }
  func httpError(
    statusResponse: HTTPURLResponse,
    body: String
  ) -> AIChatCompletionClientError {
    .httpStatus(
      statusResponse.statusCode,
      body,
      retryAfterSeconds: Self.retryAfterInterval(
        from: statusResponse.value(forHTTPHeaderField: "Retry-After")
      )
    )
  }

  static func retryAfterInterval(
    from headerValue: String?,
    now: Date = Date()
  ) -> TimeInterval? {
    guard let value = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    if let seconds = TimeInterval(value), seconds >= 0 {
      return seconds
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, date.timeIntervalSince(now))
  }

  func validatedRequestURL(config: AIProviderConfig, apiKey: String?) throws -> URL {
    guard let url = config.chatCompletionsURL else {
      throw AIChatCompletionClientError.invalidBaseURL(config.normalizedBaseURL)
    }
    guard
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        url,
        hasCredential: apiKey?.nilIfEmpty != nil
      )
    else {
      throw AIChatCompletionClientError.insecureCredentialURL
    }
    return url
  }

  private func configurationFingerprint(for config: AIProviderConfig) throws -> String {
    let data = try encoder.encode(config)
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func capabilitySupportSnapshot(
    for config: AIProviderConfig
  ) -> [AIProviderCapabilityProbeKind: AIProviderCapabilitySupport] {
    Dictionary(
      uniqueKeysWithValues: AIProviderCapabilityProbeKind.allCases.map { kind in
        let support: AIProviderCapabilitySupport
        switch kind {
        case .chat:
          support = config.capabilitySupport(for: .chat)
        case .streamingResponse:
          support = config.capabilitySupport(for: .streamingResponse)
        case .toolCalling:
          support = config.capabilitySupport(for: .toolCalling)
        case .structuredOutput:
          support = config.capabilitySupport(for: .structuredOutput)
        case .visionInput:
          support = config.capabilitySupport(for: .visionInput)
        }
        return (kind, support)
      })
  }

  func makeURLRequest(
    from prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) throws -> URLRequest {
    let url = try validatedRequestURL(config: config, apiKey: apiKey)
    guard url == prepared.endpointURL else {
      throw AIChatCompletionClientError.preparedRequestConfigurationMismatch
    }
    var request = URLRequest(url: prepared.endpointURL)
    request.timeoutInterval = networkRecoveryPolicy.firstByteTimeout
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = prepared.encodedBody
    return request
  }

  func makeNonStreamingVariant(
    from prepared: AIPreparedAIChatCompletionRequest
  ) throws -> AIPreparedAIChatCompletionRequest {
    var normalized = prepared.normalizedRequest
    normalized.stream = nil
    normalized.streamOptions = nil
    return AIPreparedAIChatCompletionRequest(
      normalizedRequest: normalized,
      endpointIdentity: prepared.endpointIdentity,
      endpointURL: prepared.endpointURL,
      encodedBody: try encoder.encode(normalized),
      mode: .nonStreaming,
      purpose: prepared.purpose,
      capabilitySupportSnapshot: prepared.capabilitySupportSnapshot,
      capabilityEvidenceSnapshot: prepared.capabilityEvidenceSnapshot,
      configurationFingerprint: prepared.configurationFingerprint,
      authorizationExpiresAt: prepared.authorizationExpiresAt
    )
  }

  func allowsAutomaticReplay(for purpose: AIProviderRequestPurpose) -> Bool {
    switch purpose {
    case .interactiveChat:
      return networkRecoveryPolicy.automaticReplay == .beforeContent
    case .utilityTask, .connectionTest, .capabilityProbe:
      return networkRecoveryPolicy.nonInteractiveAutomaticReplay == .beforeContent
    }
  }

  func validatePrepared(
    _ prepared: AIPreparedAIChatCompletionRequest,
    against config: AIProviderConfig,
    apiKey: String?
  ) throws {
    let url = try validatedRequestURL(config: config, apiKey: apiKey)
    guard prepared.endpointIdentity == config.capabilityEndpointIdentity,
      prepared.endpointURL == url,
      prepared.configurationFingerprint == (try configurationFingerprint(for: config))
    else {
      throw AIChatCompletionClientError.preparedRequestConfigurationMismatch
    }

    guard
      prepared.purpose == .capabilityProbe
        || prepared.capabilitySupportSnapshot == capabilitySupportSnapshot(for: config)
    else {
      throw AIChatCompletionClientError.preparedRequestConfigurationMismatch
    }
    guard prepared.capabilityEvidenceSnapshot == (config.capabilityProbeEvidence ?? [:]) else {
      throw AIChatCompletionClientError.preparedRequestConfigurationMismatch
    }
    if let authorizationExpiresAt = prepared.authorizationExpiresAt,
      Date() >= authorizationExpiresAt
    {
      throw AIChatCompletionClientError.preparedRequestAuthorizationExpired
    }
    if prepared.purpose != .capabilityProbe {
      let now = Date()
      for evidence in prepared.capabilityEvidenceSnapshot.values {
        guard
          evidence.isCurrent(
            at: now,
            schemaVersion: evidence.key.probeSchemaVersion
          )
        else {
          throw AIChatCompletionClientError.preparedRequestCapabilityExpired
        }
      }
    }
  }

}
