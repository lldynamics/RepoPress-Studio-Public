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
  public var thinking: AIProviderThinkingOption?
  public var reasoningEffort: String?
  public var stream: Bool?
  public var streamOptions: AIChatStreamOptions?

  public init(
    model: String,
    messages: [AIChatMessage],
    temperature: Double? = nil,
    thinking: AIProviderThinkingOption? = nil,
    reasoningEffort: String? = nil,
    stream: Bool? = nil,
    streamOptions: AIChatStreamOptions? = nil
  ) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
    self.stream = stream
    self.streamOptions = streamOptions
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
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

public protocol AIChatTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol AIChatStreamingTransport: AIChatTransport {
  func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

public struct URLSessionAIChatTransport: AIChatTransport, AIChatStreamingTransport {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? CredentialSafeURLSession.make()
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for try await line in bytes.lines {
            try Task.checkCancellation()
            continuation.yield(line)
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

public struct AIChatCompletionClient: Sendable {
  private let transport: AIChatTransport
  private let encoder: SerializedJSONEncoder
  private let decoder: SerializedJSONDecoder

  public init(
    transport: AIChatTransport = URLSessionAIChatTransport(),
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder()
  ) {
    self.transport = transport
    self.encoder = SerializedJSONEncoder(encoder)
    self.decoder = SerializedJSONDecoder(decoder)
  }

  public func complete(
    request completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    purpose: AIProviderRequestPurpose = .utilityTask
  ) async throws -> AIChatCompletionResult {
    let url = try validatedRequestURL(config: config, apiKey: apiKey)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try encoder.encode(
      normalizedRequest(completionRequest, config: config, purpose: purpose)
    )

    let (data, response) = try await transport.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AIChatCompletionClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = HTTPErrorResponseSanitizer.sanitize(
        data: data,
        sensitiveValues: [apiKey].compactMap { $0 }
      )
      throw AIChatCompletionClientError.httpStatus(httpResponse.statusCode, body)
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
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = apiKey?.nilIfEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    var normalized = normalizedRequest(completionRequest, config: config, purpose: purpose)
    normalized.stream = true
    normalized.streamOptions = AIChatStreamOptions(includeUsage: true)
    request.httpBody = try encoder.encode(normalized)

    let (lines, response) = try await streamingTransport.lines(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AIChatCompletionClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = HTTPErrorResponseSanitizer.sanitize(
        text: try await responseBody(from: lines),
        sensitiveValues: [apiKey].compactMap { $0 }
      )
      throw AIChatCompletionClientError.httpStatus(httpResponse.statusCode, body)
    }

    return streamUpdates(
      from: lines,
      sensitiveValues: [apiKey].compactMap { $0 }
    )
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
    let requestOptions = config.chatRequestOptions(
      temperature: request.temperature,
      purpose: purpose
    )
    return AIChatCompletionRequest(
      model: config.requestModel(resolving: request.model),
      messages: request.messages,
      temperature: requestOptions.temperature,
      thinking: requestOptions.thinking,
      reasoningEffort: requestOptions.reasoningEffort,
      stream: request.stream,
      streamOptions: request.streamOptions
    )
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
              continue
            }
            if trimmed.hasPrefix(":") || trimmed.hasPrefix("event:") {
              continue
            }
            if isRawStreamPayloadLine(trimmed) {
              dataLines.append(trimmed)
              continue
            }
            guard trimmed.hasPrefix("data:") else {
              continue
            }

            let payload = trimmed.dropFirst("data:".count)
              .trimmingCharacters(in: .whitespaces)
            dataLines.append(String(payload))
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
      throw AIChatCompletionClientError.httpStatus(200, sanitizedMessage)
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

public enum AIChatCompletionClientError: LocalizedError, Equatable {
  case invalidBaseURL(String)
  case insecureCredentialURL
  case invalidResponse
  case streamingUnsupported
  case httpStatus(Int, String)
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
    case .httpStatus(let status, let body):
      return "AI 请求失败：HTTP \(status)\n\(body)"
    case .emptyContent:
      return "AI 服务没有返回可用内容。"
    }
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
      if let contentText = content?.text.nilIfEmpty {
        return contentText
      }
      return reasoningContent?.text ?? ""
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
