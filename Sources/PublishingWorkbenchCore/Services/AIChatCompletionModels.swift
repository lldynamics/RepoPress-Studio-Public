import Foundation

public struct AIChatMessage: Codable, Hashable, Sendable {
  public var role: String
  public var content: AIChatMessageContent?
  public var toolCalls: [AIToolCall]?
  public var toolCallID: String?

  public init(
    role: String,
    content: String,
    toolCalls: [AIToolCall]? = nil,
    toolCallID: String? = nil
  ) {
    self.role = role
    self.content = .text(content)
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  public init(
    role: String,
    content: AIChatMessageContent? = nil,
    toolCalls: [AIToolCall]? = nil,
    toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case content
    case toolCalls = "tool_calls"
    case toolCallID = "tool_call_id"
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
  public var tools: [AIToolDefinition]?
  public var toolChoice: AIToolChoice?
  public var responseFormat: AIStructuredOutputFormat?

  public init(
    model: String,
    messages: [AIChatMessage],
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    thinking: AIProviderThinkingOption? = nil,
    reasoningEffort: String? = nil,
    stream: Bool? = nil,
    streamOptions: AIChatStreamOptions? = nil,
    tools: [AIToolDefinition]? = nil,
    toolChoice: AIToolChoice? = nil,
    responseFormat: AIStructuredOutputFormat? = nil
  ) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
    self.stream = stream
    self.streamOptions = streamOptions
    self.tools = tools
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
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
    case tools
    case toolChoice = "tool_choice"
    case responseFormat = "response_format"
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
  public var toolCalls: [AIToolCall]
  public var rawModel: String?
  public var tokenUsage: AIChatTokenUsage?

  public init(
    content: String,
    toolCalls: [AIToolCall] = [],
    rawModel: String? = nil,
    tokenUsage: AIChatTokenUsage? = nil
  ) {
    self.content = content
    self.toolCalls = toolCalls
    self.rawModel = rawModel
    self.tokenUsage = tokenUsage
  }
}

public struct AIChatStreamUpdate: Hashable, Sendable {
  public var contentDelta: String
  public var toolCallDeltas: [AIToolCallDelta]
  /// Complete accumulated snapshots, ordered by the provider's tool-call index.
  public var toolCalls: [AIToolCall]
  public var tokenUsage: AIChatTokenUsage?
  public var isFinished: Bool

  public init(
    contentDelta: String,
    toolCallDeltas: [AIToolCallDelta] = [],
    toolCalls: [AIToolCall] = [],
    tokenUsage: AIChatTokenUsage? = nil,
    isFinished: Bool = false
  ) {
    self.contentDelta = contentDelta
    self.toolCallDeltas = toolCallDeltas
    self.toolCalls = toolCalls
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

public enum AIChatAutomaticReplayPolicy: String, Codable, Equatable, Sendable {
  case never
  case beforeContent
}

public struct AIChatNetworkRecoveryPolicy: Equatable, Sendable {
  public var firstByteTimeout: TimeInterval
  public var resourceTimeout: TimeInterval
  public var maximumAutomaticRetryCount: Int
  public var automaticRetryBaseDelay: TimeInterval
  public var maximumAutomaticRetryAfterDelay: TimeInterval
  /// Interactive requests allow one network attempt per automatic authorization.
  /// Re-enabling replay must be an explicit caller policy decision.
  public var automaticReplay: AIChatAutomaticReplayPolicy
  /// Connection tests and capability probes have their own non-interactive
  /// policy so changing interactive authorization semantics is not global.
  public var nonInteractiveAutomaticReplay: AIChatAutomaticReplayPolicy

  public init(
    firstByteTimeout: TimeInterval = 45,
    resourceTimeout: TimeInterval = 300,
    maximumAutomaticRetryCount: Int = 1,
    automaticRetryBaseDelay: TimeInterval = 0.5,
    maximumAutomaticRetryAfterDelay: TimeInterval = 5,
    automaticReplay: AIChatAutomaticReplayPolicy = .never,
    nonInteractiveAutomaticReplay: AIChatAutomaticReplayPolicy = .beforeContent
  ) {
    self.firstByteTimeout = max(0.001, firstByteTimeout)
    self.resourceTimeout = max(self.firstByteTimeout, resourceTimeout)
    self.maximumAutomaticRetryCount = max(0, maximumAutomaticRetryCount)
    self.automaticRetryBaseDelay = max(0, automaticRetryBaseDelay)
    self.maximumAutomaticRetryAfterDelay = max(0, maximumAutomaticRetryAfterDelay)
    self.automaticReplay = automaticReplay
    self.nonInteractiveAutomaticReplay = nonInteractiveAutomaticReplay
  }

  public static let `default` = AIChatNetworkRecoveryPolicy()
}
