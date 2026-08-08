import Foundation

public struct AIChatMessage: Codable, Hashable, Sendable {
  public var role: String
  public var content: AIChatMessageContent

  public init(role: String, content: String) {
    self.role = role
    self.content = .text(content)
  }

  public init(role: String, content: AIChatMessageContent) {
    self.role = role
    self.content = content
  }
}

public enum AIChatMessageContent: Codable, Hashable, Sendable {
  case text(String)
  case parts([AIChatMessageContentPart])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
      return
    }
    if let parts = try? container.decode([AIChatMessageContentPart].self) {
      self = .parts(parts)
      return
    }
    throw DecodingError.typeMismatch(
      AIChatMessageContent.self,
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Expected string content or OpenAI-compatible content parts."
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .text(let text):
      var container = encoder.singleValueContainer()
      try container.encode(text)
    case .parts(let parts):
      var container = encoder.singleValueContainer()
      try container.encode(parts)
    }
  }
}

public struct AIChatMessageContentPart: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case text
    case imageURL = "image_url"
  }

  public var type: Kind
  public var text: String?
  public var imageURL: AIChatImageURL?

  public init(type: Kind, text: String? = nil, imageURL: AIChatImageURL? = nil) {
    self.type = type
    self.text = text
    self.imageURL = imageURL
  }

  public static func text(_ text: String) -> AIChatMessageContentPart {
    AIChatMessageContentPart(type: .text, text: text)
  }

  public static func imageURL(_ url: String) -> AIChatMessageContentPart {
    AIChatMessageContentPart(type: .imageURL, imageURL: AIChatImageURL(url: url))
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
  }
}

public struct AIChatImageURL: Codable, Hashable, Sendable {
  public var url: String

  public init(url: String) {
    self.url = url
  }
}

public struct AIChatImageAttachment: Codable, Hashable, Sendable {
  public var filename: String
  public var mimeType: String
  public var data: Data
  /// SHA-256 addressed blob filename, persisted instead of embedding `data` in JSON.
  public var storageReference: String?
  public var thumbnailReference: String?
  public var byteCount: Int64

  public init(
    filename: String,
    mimeType: String,
    data: Data,
    storageReference: String? = nil,
    thumbnailReference: String? = nil,
    byteCount: Int64? = nil
  ) {
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.storageReference = storageReference
    self.thumbnailReference = thumbnailReference
    self.byteCount = byteCount ?? Int64(data.count)
  }

  public var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }

  private enum CodingKeys: String, CodingKey {
    case filename
    case mimeType
    case data
    case storageReference
    case thumbnailReference
    case byteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    filename = try container.decode(String.self, forKey: .filename)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    storageReference = try container.decodeIfPresent(String.self, forKey: .storageReference)
    thumbnailReference = try container.decodeIfPresent(String.self, forKey: .thumbnailReference)
    data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
    byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount) ?? Int64(data.count)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(filename, forKey: .filename)
    try container.encode(mimeType, forKey: .mimeType)
    try container.encodeIfPresent(storageReference, forKey: .storageReference)
    try container.encodeIfPresent(thumbnailReference, forKey: .thumbnailReference)
    try container.encode(byteCount, forKey: .byteCount)
    // Backwards-compatible snapshots retain inline data only until the next
    // WorkbenchPersistence save migrates it into the content-addressed store.
    if storageReference == nil {
      try container.encode(data, forKey: .data)
    }
  }
}

public struct AIChatCompletionRequest: Codable, Hashable, Sendable {
  public var model: String
  public var messages: [AIChatMessage]
  public var temperature: Double?
  public var maximumOutputTokens: Int?
  public var thinking: AIProviderThinkingOption?
  public var reasoningEffort: String?
  public var stream: Bool?
  public var streamOptions: AIChatStreamOptions?

  public init(
    model: String,
    messages: [AIChatMessage],
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    thinking: AIProviderThinkingOption? = nil,
    reasoningEffort: String? = nil,
    stream: Bool? = nil,
    streamOptions: AIChatStreamOptions? = nil
  ) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
    self.stream = stream
    self.streamOptions = streamOptions
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maximumOutputTokens = "max_tokens"
    case thinking
    case reasoningEffort = "reasoning_effort"
    case stream
    case streamOptions = "stream_options"
  }
}

public struct AIChatStreamOptions: Codable, Hashable, Sendable {
  public var includeUsage: Bool

  public init(includeUsage: Bool) {
    self.includeUsage = includeUsage
  }

  private enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

public struct AIChatCompletionResult: Hashable, Sendable {
  public var content: String
  public var rawModel: String?
  public var tokenUsage: AIChatTokenUsage?

  public init(
    content: String,
    rawModel: String? = nil,
    tokenUsage: AIChatTokenUsage? = nil
  ) {
    self.content = content
    self.rawModel = rawModel
    self.tokenUsage = tokenUsage
  }
}

public struct AIChatStreamUpdate: Hashable, Sendable {
  public var contentDelta: String
  public var tokenUsage: AIChatTokenUsage?
  public var isFinished: Bool

  public init(
    contentDelta: String,
    tokenUsage: AIChatTokenUsage? = nil,
    isFinished: Bool = false
  ) {
    self.contentDelta = contentDelta
    self.tokenUsage = tokenUsage
    self.isFinished = isFinished
  }
}

public struct AIChatTokenUsage: Codable, Hashable, Sendable {
  public var promptTokens: Int?
  public var completionTokens: Int?
  public var totalTokens: Int?

  public init(
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }

  public var displayText: String {
    if let totalTokens, let promptTokens, let completionTokens {
      return "\(totalTokens) tokens · 输入 \(promptTokens) · 输出 \(completionTokens)"
    }
    if let totalTokens {
      return "\(totalTokens) tokens"
    }
    if let completionTokens {
      return "输出 \(completionTokens) tokens"
    }
    if let promptTokens {
      return "输入 \(promptTokens) tokens"
    }
    return "token 统计不可用"
  }
}

public struct AIChatNetworkRecoveryPolicy: Equatable, Sendable {
  public var firstByteTimeout: TimeInterval
  public var resourceTimeout: TimeInterval
  public var maximumAutomaticRetryCount: Int
  public var automaticRetryBaseDelay: TimeInterval
  public var maximumAutomaticRetryAfterDelay: TimeInterval

  public init(
    firstByteTimeout: TimeInterval = 45,
    resourceTimeout: TimeInterval = 300,
    maximumAutomaticRetryCount: Int = 1,
    automaticRetryBaseDelay: TimeInterval = 0.5,
    maximumAutomaticRetryAfterDelay: TimeInterval = 5
  ) {
    self.firstByteTimeout = max(0.001, firstByteTimeout)
    self.resourceTimeout = max(self.firstByteTimeout, resourceTimeout)
    self.maximumAutomaticRetryCount = max(0, maximumAutomaticRetryCount)
    self.automaticRetryBaseDelay = max(0, automaticRetryBaseDelay)
    self.maximumAutomaticRetryAfterDelay = max(0, maximumAutomaticRetryAfterDelay)
  }

  public static let `default` = AIChatNetworkRecoveryPolicy()
}

public protocol AIChatTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol AIChatStreamingTransport: AIChatTransport {
  func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

public struct URLSessionAIChatTransport: AIChatTransport, AIChatStreamingTransport {
  static let maximumResponseByteCount = 16 * 1_024 * 1_024
  static let maximumStreamingResponseByteCount = 32 * 1_024 * 1_024
  static let maximumStreamingLineByteCount = 1 * 1_024 * 1_024

  private let session: URLSession

  public init(
    session: URLSession? = nil,
    firstByteTimeout: TimeInterval = AIChatNetworkRecoveryPolicy.default.firstByteTimeout,
    resourceTimeout: TimeInterval = AIChatNetworkRecoveryPolicy.default.resourceTimeout
  ) {
    self.session = session ?? CredentialSafeURLSession.make(
      timeoutIntervalForRequest: firstByteTimeout,
      timeoutIntervalForResource: resourceTimeout
    )
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: Self.maximumResponseByteCount
    )
  }

  public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    try BoundedHTTPResponseLoader.validateExpectedLength(
      response,
      maximumByteCount: Self.maximumStreamingResponseByteCount
    )
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          var lineBytes: [UInt8] = []
          lineBytes.reserveCapacity(4 * 1_024)
          var totalByteCount = 0
          for try await byte in bytes {
            try Task.checkCancellation()
            totalByteCount += 1
            guard totalByteCount <= Self.maximumStreamingResponseByteCount else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: Self.maximumStreamingResponseByteCount
              )
            }
            if byte == 0x0A {
              if lineBytes.last == 0x0D {
                lineBytes.removeLast()
              }
              continuation.yield(String(decoding: lineBytes, as: UTF8.self))
              lineBytes.removeAll(keepingCapacity: true)
              continue
            }
            guard lineBytes.count < Self.maximumStreamingLineByteCount else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: Self.maximumStreamingLineByteCount
              )
            }
            lineBytes.append(byte)
          }
          if !lineBytes.isEmpty {
            continuation.yield(String(decoding: lineBytes, as: UTF8.self))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    return (stream, response)
  }
}

private struct AIChatSendableError: Sendable {
  let value: AIChatCompletionClientError
}

private enum AIChatLineEvent: Sendable {
  case line(String)
  case finished
  case cancelled
  case failed(AIChatSendableError)
  case firstByteTimedOut
  case resourceTimedOut
}

public struct AIChatCompletionClient: Sendable {
  static let maximumSSEEventByteCount = 2 * 1_024 * 1_024

  private let transport: AIChatTransport
  private let encoder: SerializedJSONEncoder
  private let decoder: SerializedJSONDecoder
  private let networkRecoveryPolicy: AIChatNetworkRecoveryPolicy

  public init(
    transport: AIChatTransport? = nil,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    networkRecoveryPolicy: AIChatNetworkRecoveryPolicy = .default
  ) {
    self.transport = transport ?? URLSessionAIChatTransport(
      firstByteTimeout: networkRecoveryPolicy.firstByteTimeout,
      resourceTimeout: networkRecoveryPolicy.resourceTimeout
    )
    self.encoder = SerializedJSONEncoder(encoder)
    self.decoder = SerializedJSONDecoder(decoder)
    self.networkRecoveryPolicy = networkRecoveryPolicy
  }

  public func complete(
    request completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    purpose: AIProviderRequestPurpose = .utilityTask
  ) async throws -> AIChatCompletionResult {
    let url = try validatedRequestURL(config: config, apiKey: apiKey)

    var request = URLRequest(url: url)
    request.timeoutInterval = networkRecoveryPolicy.firstByteTimeout
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try encoder.encode(
      normalizedRequest(completionRequest, config: config, purpose: purpose)
    )
    let preparedRequest = request

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await performWithTimeout(
        seconds: networkRecoveryPolicy.resourceTimeout,
        timeoutError: .resourceTimedOut(networkRecoveryPolicy.resourceTimeout)
      ) {
        try await transport.data(for: preparedRequest)
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
    guard let content = payload.choices.first?.message.contentText.nilIfEmpty else {
      throw AIChatCompletionClientError.emptyContent
    }
    return AIChatCompletionResult(
      content: content,
      rawModel: payload.model,
      tokenUsage: payload.usage?.tokenUsage
    )
  }

  public func stream(
    request completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    purpose: AIProviderRequestPurpose = .interactiveChat
  ) async throws -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    let url = try validatedRequestURL(config: config, apiKey: apiKey)
    guard let streamingTransport = transport as? AIChatStreamingTransport else {
      throw AIChatCompletionClientError.streamingUnsupported
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = networkRecoveryPolicy.firstByteTimeout
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    var normalized = normalizedRequest(completionRequest, config: config, purpose: purpose)
    normalized.stream = true
    normalized.streamOptions = AIChatStreamOptions(includeUsage: true)
    request.httpBody = try encoder.encode(normalized)

    return recoveredStreamUpdates(
      request: request,
      transport: streamingTransport,
      sensitiveValues: [apiKey].compactMap { $0 }
    )
  }

  private func recoveredStreamUpdates(
    request: URLRequest,
    transport: AIChatStreamingTransport,
    sensitiveValues: [String]
  ) -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    return AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        var completedRetryCount = 0

        while !Task.isCancelled {
          var receivedContent = false
          do {
            let attemptStartedAt = Date()
            let (lines, response) = try await performWithTimeout(
              seconds: networkRecoveryPolicy.firstByteTimeout,
              timeoutError: .firstByteTimedOut(networkRecoveryPolicy.firstByteTimeout)
            ) {
              try await transport.lines(for: request)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
              throw AIChatCompletionClientError.invalidResponse
            }

            let boundedLines = timedLines(
              from: lines,
              firstByteTimeout: remainingTimeout(
                networkRecoveryPolicy.firstByteTimeout,
                since: attemptStartedAt
              ),
              resourceTimeout: remainingTimeout(
                networkRecoveryPolicy.resourceTimeout,
                since: attemptStartedAt
              )
            )
            guard (200..<300).contains(httpResponse.statusCode) else {
              let body = HTTPErrorResponseSanitizer.sanitize(
                text: try await responseBody(from: boundedLines),
                sensitiveValues: sensitiveValues
              )
              throw httpError(statusResponse: httpResponse, body: body)
            }

            let updates = streamUpdates(
              from: boundedLines,
              sensitiveValues: sensitiveValues
            )
            for try await update in updates {
              try Task.checkCancellation()
              if !update.contentDelta.isEmpty {
                receivedContent = true
              }
              continuation.yield(update)
            }
            continuation.finish()
            return
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
            return
          } catch {
            let normalizedError = Self.normalizedTransportError(
              error,
              policy: networkRecoveryPolicy
            )
            if receivedContent {
              continuation.finish(
                throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                  normalizedError.localizedDescription
                )
              )
              return
            }

            guard shouldAutomaticallyRetry(
              normalizedError,
              completedRetryCount: completedRetryCount
            ) else {
              continuation.finish(throwing: normalizedError)
              return
            }

            let delay = automaticRetryDelay(
              for: normalizedError,
              completedRetryCount: completedRetryCount
            )
            completedRetryCount += 1
            do {
              try await sleep(seconds: delay)
            } catch {
              continuation.finish(throwing: CancellationError())
              return
            }
          }
        }

        continuation.finish(throwing: CancellationError())
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func timedLines(
    from lines: AsyncThrowingStream<String, Error>,
    firstByteTimeout: TimeInterval,
    resourceTimeout: TimeInterval
  ) -> AsyncThrowingStream<String, Error> {
    let recoveryPolicy = networkRecoveryPolicy
    return AsyncThrowingStream { continuation in
      let (events, eventContinuation) = AsyncStream<AIChatLineEvent>.makeStream()
      let sourceTask = Task(priority: .userInitiated) {
        do {
          var cumulativeByteCount = 0
          for try await line in lines {
            try Task.checkCancellation()
            let lineByteCount = line.utf8.count
            guard lineByteCount <= URLSessionAIChatTransport.maximumStreamingLineByteCount,
                  cumulativeByteCount <= URLSessionAIChatTransport.maximumStreamingResponseByteCount - lineByteCount else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: URLSessionAIChatTransport.maximumStreamingResponseByteCount
              )
            }
            cumulativeByteCount += lineByteCount
            eventContinuation.yield(.line(line))
          }
          eventContinuation.yield(.finished)
        } catch is CancellationError {
          eventContinuation.yield(.cancelled)
        } catch {
          eventContinuation.yield(
            .failed(
              AIChatSendableError(
                value: Self.normalizedTransportError(error, policy: recoveryPolicy)
              )
            )
          )
        }
      }
      let firstByteTimeoutTask = Task {
        do {
          try await sleep(seconds: firstByteTimeout)
          eventContinuation.yield(.firstByteTimedOut)
        } catch {
          // Cancellation means a line or terminal event won the race.
        }
      }
      let resourceTimeoutTask = Task {
        do {
          try await sleep(seconds: resourceTimeout)
          eventContinuation.yield(.resourceTimedOut)
        } catch {
          // Cancellation means the stream completed before its resource limit.
        }
      }
      let coordinatorTask = Task(priority: .userInitiated) {
        var receivedFirstLine = false
        defer {
          sourceTask.cancel()
          firstByteTimeoutTask.cancel()
          resourceTimeoutTask.cancel()
          eventContinuation.finish()
        }

        for await event in events {
          guard !Task.isCancelled else { break }
          switch event {
          case .line(let line):
            if !receivedFirstLine {
              receivedFirstLine = true
              firstByteTimeoutTask.cancel()
            }
            continuation.yield(line)
          case .finished:
            continuation.finish()
            return
          case .cancelled:
            continuation.finish(throwing: CancellationError())
            return
          case .failed(let error):
            continuation.finish(throwing: error.value)
            return
          case .firstByteTimedOut:
            guard !receivedFirstLine else { continue }
            continuation.finish(
              throwing: AIChatCompletionClientError.firstByteTimedOut(firstByteTimeout)
            )
            return
          case .resourceTimedOut:
            continuation.finish(
              throwing: AIChatCompletionClientError.resourceTimedOut(resourceTimeout)
            )
            return
          }
        }
      }

      continuation.onTermination = { _ in
        coordinatorTask.cancel()
        sourceTask.cancel()
        firstByteTimeoutTask.cancel()
        resourceTimeoutTask.cancel()
        eventContinuation.finish()
      }
    }
  }

  private func performWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    timeoutError: AIChatCompletionClientError,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await sleep(seconds: seconds)
        throw timeoutError
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }

  private func sleep(seconds: TimeInterval) async throws {
    guard seconds > 0 else {
      try Task.checkCancellation()
      return
    }
    let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private func remainingTimeout(
    _ timeout: TimeInterval,
    since startDate: Date
  ) -> TimeInterval {
    max(0.001, timeout - Date().timeIntervalSince(startDate))
  }

  private static func normalizedTransportError(
    _ error: Error,
    policy: AIChatNetworkRecoveryPolicy
  ) -> AIChatCompletionClientError {
    if let clientError = error as? AIChatCompletionClientError {
      return clientError
    }
    if error is DecodingError {
      return .invalidResponse
    }
    if let responseLimitError = error as? HTTPResponseLimitError {
      return .responseTooLarge(maximumBytes: responseLimitError.maximumByteCount)
    }
    if let urlError = error as? URLError {
      if urlError.code == .timedOut {
        return .resourceTimedOut(policy.resourceTimeout)
      }
      return .networkFailure(urlError.localizedDescription)
    }
    return .networkFailure(error.localizedDescription)
  }

  private func shouldAutomaticallyRetry(
    _ error: AIChatCompletionClientError,
    completedRetryCount: Int
  ) -> Bool {
    guard completedRetryCount < networkRecoveryPolicy.maximumAutomaticRetryCount,
          error.isAutomaticallyRetryable else {
      return false
    }
    if let retryAfter = error.retryAfterSeconds {
      return retryAfter <= networkRecoveryPolicy.maximumAutomaticRetryAfterDelay
    }
    return true
  }

  private func automaticRetryDelay(
    for error: AIChatCompletionClientError,
    completedRetryCount: Int
  ) -> TimeInterval {
    if let retryAfter = error.retryAfterSeconds {
      return retryAfter
    }
    return networkRecoveryPolicy.automaticRetryBaseDelay
      * pow(2, Double(completedRetryCount))
  }

  private func httpError(
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
          !value.isEmpty else {
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

  private func validatedRequestURL(config: AIProviderConfig, apiKey: String?) throws -> URL {
    guard let url = config.chatCompletionsURL else {
      throw AIChatCompletionClientError.invalidBaseURL(config.normalizedBaseURL)
    }
    guard CredentialedEndpointPolicy.isAllowedAIRequestURL(
      url,
      hasCredential: apiKey?.nilIfEmpty != nil
    ) else {
      throw AIChatCompletionClientError.insecureCredentialURL
    }
    return url
  }

  private func normalizedRequest(
    _ request: AIChatCompletionRequest,
    config: AIProviderConfig,
    purpose: AIProviderRequestPurpose
  ) -> AIChatCompletionRequest {
    let advancedSettings = config.resolvedAdvancedSettings
    let appliesInteractiveOverrides = purpose == .interactiveChat
    let requestedTemperature = appliesInteractiveOverrides
      ? (advancedSettings.normalizedTemperature ?? request.temperature)
      : request.temperature
    let requestOptions = config.chatRequestOptions(
      temperature: requestedTemperature,
      purpose: purpose
    )
    let reasoningSupport = config.capabilitySupport(for: .reasoningControl)
    let explicitThinking = reasoningSupport == .unsupported ? nil : request.thinking
    let explicitReasoningEffort = reasoningSupport == .unsupported
      ? nil
      : request.reasoningEffort
    let hasExplicitReasoningOptions = explicitThinking != nil || explicitReasoningEffort != nil
    let advancedReasoningPreference = reasoningSupport == .unsupported
      ? AIProviderReasoningPreference.automatic
      : advancedSettings.reasoningPreference
    let reasoningOptions = normalizedReasoningOptions(
      explicitThinking: explicitThinking,
      explicitReasoningEffort: explicitReasoningEffort,
      fallback: requestOptions,
      preference: appliesInteractiveOverrides
        ? advancedReasoningPreference
        : .automatic,
      config: config
    )
    return AIChatCompletionRequest(
      model: config.requestModel(resolving: request.model),
      messages: appliesInteractiveOverrides
        ? messages(
          request.messages,
          appendingSystemPrompt: advancedSettings.normalizedSystemPrompt
        )
        : request.messages,
      temperature: requestOptions.temperature,
      maximumOutputTokens: request.maximumOutputTokens
        ?? (appliesInteractiveOverrides
          ? advancedSettings.normalizedMaximumOutputTokens
          : nil),
      thinking: reasoningOptions.thinking,
      reasoningEffort: hasExplicitReasoningOptions
        ? explicitReasoningEffort
        : reasoningOptions.reasoningEffort,
      stream: request.stream,
      streamOptions: request.streamOptions
    )
  }

  private func messages(
    _ messages: [AIChatMessage],
    appendingSystemPrompt systemPrompt: String
  ) -> [AIChatMessage] {
    guard !systemPrompt.isEmpty else { return messages }
    var updated = messages
    if let index = updated.firstIndex(where: { $0.role == "system" }),
       case .text(let existingPrompt) = updated[index].content {
      updated[index].content = .text(
        [existingPrompt.trimmedForPublishing, systemPrompt]
          .filter { !$0.isEmpty }
          .joined(separator: "\n\n")
      )
    } else {
      updated.insert(AIChatMessage(role: "system", content: systemPrompt), at: 0)
    }
    return updated
  }

  private func normalizedReasoningOptions(
    explicitThinking: AIProviderThinkingOption?,
    explicitReasoningEffort: String?,
    fallback: AIProviderChatRequestOptions,
    preference: AIProviderReasoningPreference,
    config: AIProviderConfig
  ) -> AIProviderChatRequestOptions {
    if explicitThinking != nil || explicitReasoningEffort != nil {
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: explicitThinking ?? fallback.thinking,
        reasoningEffort: explicitReasoningEffort
      )
    }

    switch preference {
    case .automatic:
      return fallback
    case .disabled:
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: config.usesDeepSeekAPI
          ? AIProviderThinkingOption(type: "disabled")
          : nil,
        reasoningEffort: nil
      )
    case .low, .medium, .high:
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: config.usesDeepSeekAPI
          ? AIProviderThinkingOption(type: "enabled")
          : nil,
        reasoningEffort: preference.rawValue
      )
    }
  }

  private func streamUpdates(
    from lines: AsyncThrowingStream<String, Error>,
    sensitiveValues: [String]
  )
    -> AsyncThrowingStream<AIChatStreamUpdate, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        var dataLines: [String] = []
        var eventByteCount = 0
        do {
          for try await line in lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
              try emitSSEEvent(
                dataLines,
                sensitiveValues: sensitiveValues,
                continuation: continuation
              )
              dataLines.removeAll()
              eventByteCount = 0
              continue
            }
            if trimmed.hasPrefix(":") || trimmed.hasPrefix("event:") {
              continue
            }
            if isRawStreamPayloadLine(trimmed) {
              try validateSSELine(trimmed, currentEventByteCount: &eventByteCount)
              dataLines.append(trimmed)
              continue
            }
            guard trimmed.hasPrefix("data:") else {
              continue
            }

            let payload = trimmed.dropFirst("data:".count)
              .trimmingCharacters(in: .whitespaces)
            let payloadText = String(payload)
            try validateSSELine(payloadText, currentEventByteCount: &eventByteCount)
            dataLines.append(payloadText)
          }

          if !dataLines.isEmpty {
            try emitSSEEvent(
              dataLines,
              sensitiveValues: sensitiveValues,
              continuation: continuation
            )
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func emitSSEEvent(
    _ dataLines: [String],
    sensitiveValues: [String],
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws {
    guard !dataLines.isEmpty else {
      return
    }

    for payload in normalizedSSEPayloads(from: dataLines) {
      try emitSSEPayload(
        payload,
        sensitiveValues: sensitiveValues,
        continuation: continuation
      )
    }
  }

  private func validateSSELine(
    _ line: String,
    currentEventByteCount: inout Int
  ) throws {
    let lineByteCount = line.utf8.count
    guard lineByteCount <= Self.maximumSSEEventByteCount,
          currentEventByteCount <= Self.maximumSSEEventByteCount - lineByteCount else {
      throw AIChatCompletionClientError.responseTooLarge(
        maximumBytes: Self.maximumSSEEventByteCount
      )
    }
    currentEventByteCount += lineByteCount
  }

  private func emitSSEPayload(
    _ rawPayload: String,
    sensitiveValues: [String],
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws {
    let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else {
      return
    }

    if payload == "[DONE]" {
      continuation.yield(AIChatStreamUpdate(contentDelta: "", isFinished: true))
      return
    }

    guard let data = payload.data(using: .utf8) else {
      throw AIChatCompletionClientError.invalidResponse
    }
    let decoded = try decoder.decode(AIChatCompletionStreamChunk.self, from: data)
    if let errorMessage = decoded.error?.displayMessage.nilIfEmpty {
      let sanitizedMessage = HTTPErrorResponseSanitizer.sanitize(
        text: errorMessage,
        sensitiveValues: sensitiveValues
      )
      throw AIChatCompletionClientError.httpStatus(
        200,
        sanitizedMessage,
        retryAfterSeconds: nil
      )
    }

    let content = decoded.contentDelta
    if !content.isEmpty || decoded.usage != nil || decoded.isFinished {
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: content,
          tokenUsage: decoded.usage?.tokenUsage,
          isFinished: decoded.isFinished
        )
      )
    }
  }

  private func normalizedSSEPayloads(from dataLines: [String]) -> [String] {
    let payload = dataLines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else {
      return []
    }
    if payload == "[DONE]" || isSingleJSONPayload(payload) {
      return [payload]
    }

    let splitPayloads = dataLines
      .flatMap { $0.components(separatedBy: .newlines) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return splitPayloads.isEmpty ? [payload] : splitPayloads
  }

  private func isSingleJSONPayload(_ payload: String) -> Bool {
    guard let data = payload.data(using: .utf8) else {
      return false
    }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }

  private func isRawStreamPayloadLine(_ line: String) -> Bool {
    line == "[DONE]" || line.hasPrefix("{") || line.hasPrefix("[")
  }

  private func responseBody(from lines: AsyncThrowingStream<String, Error>) async throws -> String {
    var body = ""
    for try await line in lines {
      try Task.checkCancellation()
      let remainingCount = HTTPErrorResponseSanitizer.maximumCharacterCount - body.count
      guard remainingCount > 0 else { break }
      if !body.isEmpty {
        body.append("\n")
      }
      body.append(contentsOf: line.prefix(remainingCount))
      if line.count > remainingCount || body.count >= HTTPErrorResponseSanitizer.maximumCharacterCount {
        body.append("\n[远端响应已截断]")
        break
      }
    }
    return body
  }
}

public enum AIChatCompletionClientError: LocalizedError, Equatable, Sendable {
  case invalidBaseURL(String)
  case insecureCredentialURL
  case invalidResponse
  case streamingUnsupported
  case httpStatus(Int, String, retryAfterSeconds: TimeInterval?)
  case firstByteTimedOut(TimeInterval)
  case resourceTimedOut(TimeInterval)
  case responseTooLarge(maximumBytes: Int)
  case networkFailure(String)
  case streamInterruptedAfterPartialContent(String)
  case emptyContent

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "AI Base URL 无效：\(value)"
    case .insecureCredentialURL:
      return "AI 请求仅允许 HTTPS，或无 API Key 时的本机回环 HTTP 端点；本次未发起请求。"
    case .invalidResponse:
      return "AI 服务返回了无效响应。"
    case .streamingUnsupported:
      return "当前 AI 连接不支持流式回复。"
    case .httpStatus(let status, let body, let retryAfterSeconds):
      let retryHint = retryAfterSeconds.map {
        "\n服务器建议等待 \(Self.durationText($0))后再手动重试。"
      } ?? ""
      return "AI 请求失败：HTTP \(status)\n\(body)\(retryHint)"
    case .firstByteTimedOut(let timeout):
      return "等待 AI 返回首字节超过 \(Self.durationText(timeout))，请求已停止。可以检查网络后手动重试。"
    case .resourceTimedOut(let timeout):
      return "AI 请求超过 \(Self.durationText(timeout))的资源时限，已停止读取。可以检查网络后手动重试。"
    case .responseTooLarge(let maximumBytes):
      return "AI 响应超过 \(maximumBytes) 字节的安全上限，已停止读取。"
    case .networkFailure(let message):
      return "AI 网络连接中断：\(message)\n可以检查网络后手动重试。"
    case .streamInterruptedAfterPartialContent(let message):
      return "流式回复在返回部分内容后中断。为避免重复生成和重复计费，未自动重试；已保留现有内容。请确认后再手动重新生成。\n\(message)"
    case .emptyContent:
      return "AI 服务没有返回可用内容。"
    }
  }

  public var retryAfterSeconds: TimeInterval? {
    guard case .httpStatus(_, _, let retryAfterSeconds) = self else { return nil }
    return retryAfterSeconds
  }

  public var didReceivePartialContent: Bool {
    if case .streamInterruptedAfterPartialContent = self {
      return true
    }
    return false
  }

  public var isAutomaticallyRetryable: Bool {
    switch self {
    case .firstByteTimedOut, .resourceTimedOut, .networkFailure:
      return true
    case .httpStatus(let status, _, _):
      return [408, 425, 429, 500, 502, 503, 504].contains(status)
    case .invalidBaseURL, .insecureCredentialURL, .invalidResponse, .responseTooLarge,
         .streamingUnsupported, .streamInterruptedAfterPartialContent, .emptyContent:
      return false
    }
  }

  public var supportsManualRetry: Bool {
    didReceivePartialContent || isAutomaticallyRetryable
  }

  private static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 1 {
      return String(format: "%.1f 秒", seconds)
    }
    return "\(Int(ceil(seconds))) 秒"
  }
}

struct AIChatCompletionResponse: Decodable, Hashable {
  var model: String?
  var choices: [Choice]
  var usage: Usage?

  struct Usage: Decodable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    var tokenUsage: AIChatTokenUsage {
      AIChatTokenUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens
      )
    }

    private enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }
  }

  struct Choice: Decodable, Hashable {
    var message: Message
  }

  struct Message: Decodable, Hashable {
    var content: AIResponseContent?
    var reasoningContent: AIResponseContent?

    var contentText: String {
      content?.text ?? ""
    }

    private enum CodingKeys: String, CodingKey {
      case content
      case reasoningContent = "reasoning_content"
    }
  }
}

struct AIChatCompletionStreamChunk: Decodable, Hashable {
  var choices: [Choice]
  var usage: AIChatCompletionResponse.Usage?
  var responseDelta: AIResponseContent?
  var responseText: AIResponseContent?
  var error: APIError?

  var contentDelta: String {
    let choiceText = choices
      .map { choice in
        choice.delta?.contentText.nilIfEmpty
          ?? choice.message?.contentText.nilIfEmpty
          ?? ""
      }
      .filter { !$0.isEmpty }
      .joined()
    if !choiceText.isEmpty {
      return choiceText
    }
    return responseDelta?.text.nilIfEmpty ?? responseText?.text ?? ""
  }

  var isFinished: Bool {
    choices.contains { choice in
      choice.finishReason?.nilIfEmpty != nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case choices
    case usage
    case responseDelta = "response_delta"
    case responseText = "content"
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    usage = try container.decodeIfPresent(AIChatCompletionResponse.Usage.self, forKey: .usage)
    responseDelta = try container.decodeIfPresent(AIResponseContent.self, forKey: .responseDelta)
    responseText = try container.decodeIfPresent(AIResponseContent.self, forKey: .responseText)
    error = try container.decodeIfPresent(APIError.self, forKey: .error)
  }

  struct Choice: Decodable, Hashable {
    var delta: AIChatCompletionResponse.Message?
    var message: AIChatCompletionResponse.Message?
    var finishReason: String?

    private enum CodingKeys: String, CodingKey {
      case delta
      case message
      case finishReason = "finish_reason"
    }
  }

  struct APIError: Decodable, Hashable {
    var message: String?
    var code: String?

    var displayMessage: String {
      if let message = message?.nilIfEmpty {
        return message
      }
      return code ?? ""
    }

    init(from decoder: Decoder) throws {
      if let text = try? decoder.singleValueContainer().decode(String.self) {
        message = text
        code = nil
        return
      }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      message = try container.decodeIfPresent(String.self, forKey: .message)
      code = try container.decodeIfPresent(String.self, forKey: .code)
    }

    private enum CodingKeys: String, CodingKey {
      case message
      case code
    }
  }
}

enum AIResponseContent: Decodable, Hashable {
  case string(String)
  case strings([String])
  case parts([Part])

  struct Part: Decodable, Hashable {
    var type: String?
    var text: String?
  }

  var text: String {
    switch self {
    case .string(let value):
      return value
    case .strings(let values):
      return values.joined(separator: "\n")
    case .parts(let parts):
      return parts.compactMap(\.text).joined(separator: "\n")
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let values = try? container.decode([String].self) {
      self = .strings(values)
      return
    }
    if let parts = try? container.decode([Part].self) {
      self = .parts(parts)
      return
    }
    throw DecodingError.typeMismatch(
      AIResponseContent.self,
      DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported AI response content shape")
    )
  }
}
