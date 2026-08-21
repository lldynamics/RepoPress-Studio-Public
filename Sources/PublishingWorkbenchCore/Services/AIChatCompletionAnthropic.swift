import Foundation

/// The native Claude Messages request is deliberately kept separate from the
/// OpenAI-compatible request model.  A prepared request is encoded once with
/// this shape and the exact bytes are later attached to the URLRequest.
struct AnthropicMessagesRequest: Encodable {
  let model: String
  let messages: [AnthropicMessage]
  let system: String?
  let maxTokens: Int
  let temperature: Double?
  let tools: [AnthropicTool]?
  let toolChoice: AnthropicToolChoice?
  let stream: Bool?

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case system
    case maxTokens = "max_tokens"
    case temperature
    case tools
    case toolChoice = "tool_choice"
    case stream
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encodeIfPresent(system, forKey: .system)
    try container.encode(maxTokens, forKey: .maxTokens)
    try container.encodeIfPresent(temperature, forKey: .temperature)
    try container.encodeIfPresent(tools, forKey: .tools)
    try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
    try container.encodeIfPresent(stream, forKey: .stream)
  }
}

struct AnthropicMessage: Encodable {
  let role: String
  let content: [AnthropicContentBlock]
}

struct AnthropicImageSource: Encodable {
  let type = "base64"
  let mediaType: String
  let data: String

  private enum CodingKeys: String, CodingKey {
    case type
    case mediaType = "media_type"
    case data
  }
}

/// One of the content blocks accepted by the native Messages API.  The
/// optional fields make the encoder safe to review: no OpenAI-only keys can
/// leak into a native request.
struct AnthropicContentBlock: Encodable {
  let type: String
  let text: String?
  let source: AnthropicImageSource?
  let id: String?
  let name: String?
  let input: AIStructuredOutputJSONValue?
  let toolUseID: String?
  let content: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case source
    case id
    case name
    case input
    case toolUseID = "tool_use_id"
    case content
  }

  static func text(_ value: String) -> AnthropicContentBlock {
    AnthropicContentBlock(
      type: "text",
      text: value,
      source: nil,
      id: nil,
      name: nil,
      input: nil,
      toolUseID: nil,
      content: nil
    )
  }

  static func image(_ source: AnthropicImageSource) -> AnthropicContentBlock {
    AnthropicContentBlock(
      type: "image",
      text: nil,
      source: source,
      id: nil,
      name: nil,
      input: nil,
      toolUseID: nil,
      content: nil
    )
  }

  static func toolUse(
    id: String,
    name: String,
    input: AIStructuredOutputJSONValue
  ) -> AnthropicContentBlock {
    AnthropicContentBlock(
      type: "tool_use",
      text: nil,
      source: nil,
      id: id,
      name: name,
      input: input,
      toolUseID: nil,
      content: nil
    )
  }

  static func toolResult(
    toolUseID: String,
    content: String?
  ) -> AnthropicContentBlock {
    AnthropicContentBlock(
      type: "tool_result",
      text: nil,
      source: nil,
      id: nil,
      name: nil,
      input: nil,
      toolUseID: toolUseID,
      content: content
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(text, forKey: .text)
    try container.encodeIfPresent(source, forKey: .source)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(input, forKey: .input)
    try container.encodeIfPresent(toolUseID, forKey: .toolUseID)
    try container.encodeIfPresent(content, forKey: .content)
  }
}

struct AnthropicTool: Encodable {
  let name: String
  let description: String?
  let inputSchema: AIStructuredOutputJSONValue

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case inputSchema = "input_schema"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(inputSchema, forKey: .inputSchema)
  }
}

enum AnthropicToolChoice: Encodable {
  case auto
  case any
  case tool(String)

  private enum CodingKeys: String, CodingKey {
    case type
    case name
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .auto:
      try container.encode("auto", forKey: .type)
    case .any:
      try container.encode("any", forKey: .type)
    case .tool(let name):
      try container.encode("tool", forKey: .type)
      try container.encode(name, forKey: .name)
    }
  }
}

enum AIChatNonStreamingAttemptError: Error, Sendable {
  /// The request did not receive a successful response or decoded content.
  /// A caller may replay this only when its explicit policy allows it.
  case beforeResponse(AIChatCompletionClientError)
  /// A response was received successfully enough that replay could duplicate
  /// work, even when decoding it failed.
  case afterResponse(AIChatCompletionClientError)
}

func makeAnthropicMessagesRequest(
  from request: AIChatCompletionRequest
) throws -> AnthropicMessagesRequest {
  guard request.responseFormat == nil else {
    // Do not silently drop a structured-output probe.  Native Messages has a
    // separate structured-output contract, so pretending the OpenAI field was
    // sent would turn an unconstrained JSON-looking answer into false support.
    throw AIChatCompletionClientError.unsupportedAnthropicStructuredOutput
  }

  var systemParts: [String] = []
  var messages: [AnthropicMessage] = []

  for message in request.messages {
    let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch role {
    case "system", "developer":
      let text = try anthropicPlainText(from: message.content)
      if !text.isEmpty {
        systemParts.append(text)
      }

    case "tool":
      guard let toolUseID = message.toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
        !toolUseID.isEmpty
      else {
        throw AIChatCompletionClientError.invalidResponse
      }
      let resultText = try anthropicPlainText(from: message.content)
      // A tool result is a user message in the native protocol.  Keeping the
      // result block first is required when a caller also retains text around
      // the tool result in its history.
      messages.append(
        AnthropicMessage(
          role: "user",
          content: [
            .toolResult(toolUseID: toolUseID, content: resultText.nilIfEmpty)
          ]
        )
      )

    case "user", "assistant":
      var blocks = try anthropicContentBlocks(from: message.content)
      if role == "assistant", let toolCalls = message.toolCalls {
        // An empty text placeholder is common in the shared OpenAI model when
        // the assistant turn consists only of tool calls.  Native Messages
        // requires useful content blocks, so do not send that placeholder
        // beside the actual tool_use blocks.
        blocks.removeAll { $0.type == "text" && $0.text?.isEmpty == true }
        for toolCall in toolCalls {
          let id = toolCall.id.trimmingCharacters(in: .whitespacesAndNewlines)
          let name = toolCall.function.name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !id.isEmpty, !name.isEmpty else {
            throw AIChatCompletionClientError.invalidResponse
          }
          blocks.append(
            .toolUse(
              id: id,
              name: name,
              input: try anthropicToolInput(from: toolCall.function.arguments)
            )
          )
        }
      }
      if blocks.isEmpty {
        blocks = [.text("")]
      }
      messages.append(AnthropicMessage(role: role, content: blocks))

    default:
      throw AIChatCompletionClientError.invalidResponse
    }
  }

  let shouldSendTools: Bool
  if case .some(.none) = request.toolChoice {
    // The native Messages API has no OpenAI-style `none` mode.  Sending the
    // tools while omitting tool_choice would silently restore the provider's
    // default auto mode, which could trigger an unintended tool call.
    shouldSendTools = false
  } else {
    shouldSendTools = true
  }
  let tools =
    shouldSendTools
    ? request.tools?.map {
      AnthropicTool(
        name: $0.function.name,
        description: $0.function.description,
        inputSchema: $0.function.parameters
      )
    } : nil
  let toolChoice: AnthropicToolChoice?
  if tools?.isEmpty == false {
    switch request.toolChoice {
    case .some(.none), nil:
      toolChoice = nil
    case .auto:
      toolChoice = .auto
    case .required:
      toolChoice = .any
    case .function(let name):
      toolChoice = .tool(name)
    }
  } else {
    toolChoice = nil
  }

  return AnthropicMessagesRequest(
    model: request.model,
    messages: messages,
    system: systemParts.joined(separator: "\n\n").nilIfEmpty,
    maxTokens: max(1, request.maximumOutputTokens ?? 4_096),
    temperature: try anthropicTemperature(from: request.temperature),
    tools: tools?.isEmpty == false ? tools : nil,
    toolChoice: toolChoice,
    stream: request.stream
  )
}

private func anthropicTemperature(from value: Double?) throws -> Double? {
  guard let value else { return nil }
  guard value.isFinite else {
    throw AIChatCompletionClientError.invalidResponse
  }
  // The shared workbench setting permits 0...2, while Messages accepts only
  // 0...1.  Normalize in the native builder so the prepared canonical body
  // and the bytes sent to Anthropic carry the same provider-safe value.
  return min(1, max(0, value))
}

private func anthropicContentBlocks(
  from content: AIChatMessageContent?
) throws -> [AnthropicContentBlock] {
  guard let content else { return [] }
  switch content {
  case .text(let text):
    return [.text(text)]
  case .parts(let parts):
    return try parts.compactMap { part in
      switch part.type {
      case .text:
        return part.text.map(AnthropicContentBlock.text)
      case .imageURL:
        guard let url = part.imageURL?.url else {
          throw AIChatCompletionClientError.invalidResponse
        }
        return .image(try anthropicImageSource(from: url))
      }
    }
  }
}

private func anthropicPlainText(
  from content: AIChatMessageContent?
) throws -> String {
  guard let content else { return "" }
  switch content {
  case .text(let text):
    return text
  case .parts(let parts):
    var values: [String] = []
    for part in parts {
      switch part.type {
      case .text:
        if let text = part.text {
          values.append(text)
        }
      case .imageURL:
        // System prompts and tool results cannot contain image blocks.  Do
        // not silently drop an image that the caller thought it had sent.
        throw AIChatCompletionClientError.invalidResponse
      }
    }
    return values.joined()
  }
}

private func anthropicImageSource(from rawURL: String) throws -> AnthropicImageSource {
  guard rawURL.lowercased().hasPrefix("data:") else {
    // Native Anthropic URLs would make the provider fetch caller-controlled
    // remote content.  The workbench's image contract is explicitly data URL
    // based, so fail closed rather than changing that privacy boundary.
    throw AIChatCompletionClientError.invalidResponse
  }
  guard let comma = rawURL.firstIndex(of: ",") else {
    throw AIChatCompletionClientError.invalidResponse
  }
  let metadata = String(rawURL[rawURL.index(rawURL.startIndex, offsetBy: 5)..<comma])
  let components = metadata.split(separator: ";", omittingEmptySubsequences: true)
  guard let rawMediaType = components.first else {
    throw AIChatCompletionClientError.invalidResponse
  }
  let mediaType = String(rawMediaType)
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  guard
    ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mediaType),
    components.dropFirst().contains(where: { $0.lowercased() == "base64" })
  else {
    throw AIChatCompletionClientError.invalidResponse
  }
  let encoded = String(rawURL[rawURL.index(after: comma)...])
  guard !encoded.isEmpty, let data = Data(base64Encoded: encoded), !data.isEmpty else {
    throw AIChatCompletionClientError.invalidResponse
  }
  return AnthropicImageSource(
    mediaType: mediaType,
    data: data.base64EncodedString()
  )
}

private func anthropicToolInput(from rawArguments: String) throws -> AIStructuredOutputJSONValue {
  let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    return .object([:])
  }
  guard let data = trimmed.data(using: .utf8) else {
    throw AIChatCompletionClientError.invalidResponse
  }
  do {
    let value = try JSONDecoder().decode(AIStructuredOutputJSONValue.self, from: data)
    guard case .object = value else {
      throw AIChatCompletionClientError.invalidResponse
    }
    return value
  } catch {
    if let error = error as? AIChatCompletionClientError {
      throw error
    }
    throw AIChatCompletionClientError.invalidResponse
  }
}

struct AnthropicMessagesResponse: Decodable {
  let id: String?
  let model: String?
  let content: [AnthropicResponseContentBlock]
  let usage: AnthropicUsage?

  private enum CodingKeys: String, CodingKey {
    case id
    case model
    case content
    case usage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    content =
      try container.decodeIfPresent(
        [AnthropicResponseContentBlock].self,
        forKey: .content
      ) ?? []
    usage = try container.decodeIfPresent(AnthropicUsage.self, forKey: .usage)
  }

  func result(using encoder: SerializedJSONEncoder) throws -> AIChatCompletionResult {
    let text = content.compactMap { block -> String? in
      guard block.type == "text" else { return nil }
      return block.text
    }.joined()
    let toolCalls = try content.enumerated().compactMap { index, block -> AIToolCall? in
      guard block.type == "tool_use",
        let id = block.id?.nilIfEmpty,
        let name = block.name?.nilIfEmpty
      else {
        return nil
      }
      if let input = block.input {
        guard case .object = input else {
          throw AIChatCompletionClientError.invalidResponse
        }
      }
      let input = block.input ?? .object([:])
      let arguments =
        String(
          data: try encoder.encode(input),
          encoding: .utf8
        ) ?? "{}"
      return AIToolCall(
        id: id,
        function: AIToolFunctionCall(name: name, arguments: arguments)
      )
    }
    guard text.nilIfEmpty != nil || !toolCalls.isEmpty else {
      throw AIChatCompletionClientError.emptyContent
    }
    return AIChatCompletionResult(
      content: text,
      toolCalls: toolCalls,
      rawModel: model,
      tokenUsage: usage?.tokenUsage
    )
  }
}

struct AnthropicResponseContentBlock: Decodable {
  let type: String
  let text: String?
  let id: String?
  let name: String?
  let input: AIStructuredOutputJSONValue?
}

struct AnthropicUsage: Codable {
  let inputTokens: Int?
  let outputTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
  }

  var tokenUsage: AIChatTokenUsage {
    let total: Int?
    if let inputTokens, let outputTokens {
      total = inputTokens + outputTokens
    } else {
      total = nil
    }
    return AIChatTokenUsage(
      promptTokens: inputTokens,
      completionTokens: outputTokens,
      totalTokens: total
    )
  }
}

struct AnthropicStreamPayload: Decodable {
  let type: String
  let message: AnthropicStreamMessageStart?
  let index: Int?
  let contentBlock: AnthropicStreamContentBlock?
  let delta: AnthropicStreamDelta?
  let usage: AnthropicUsage?
  let error: AnthropicStreamError?

  private enum CodingKeys: String, CodingKey {
    case type
    case message
    case index
    case contentBlock = "content_block"
    case delta
    case usage
    case error
  }
}

struct AnthropicStreamMessageStart: Decodable {
  let usage: AnthropicUsage?
}

struct AnthropicStreamContentBlock: Decodable {
  let type: String
  let id: String?
  let name: String?
  let input: AIStructuredOutputJSONValue?
}

struct AnthropicStreamDelta: Decodable {
  let type: String?
  let text: String?
  let partialJSON: String?
  let stopReason: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case partialJSON = "partial_json"
    case stopReason = "stop_reason"
  }
}

struct AnthropicStreamError: Decodable {
  let type: String?
  let message: String?
}

func anthropicEventType(from data: Data) -> String? {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return nil
  }
  return object["type"] as? String
}

func isAnthropicStreamEventType(_ type: String) -> Bool {
  [
    "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
    "ping",
    "error",
  ].contains(type)
}

struct AnthropicStreamState: Sendable {
  struct PartialTool: Sendable {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
  }

  var toolsByIndex: [Int: PartialTool] = [:]
  var inputTokens: Int?
  var outputTokens: Int?

  mutating func apply(usage: AnthropicUsage?) {
    if let inputTokens = usage?.inputTokens {
      self.inputTokens = inputTokens
    }
    if let outputTokens = usage?.outputTokens {
      self.outputTokens = outputTokens
    }
  }

  mutating func startTool(index: Int, id: String?, name: String?) -> AIToolCallDelta? {
    var tool = toolsByIndex[index] ?? PartialTool()
    if let id {
      tool.id = id
    }
    if let name {
      tool.name = name
    }
    toolsByIndex[index] = tool
    guard !tool.id.isEmpty || !tool.name.isEmpty else { return nil }
    return AIToolCallDelta(
      index: index,
      id: tool.id.nilIfEmpty,
      type: "function",
      function: AIToolFunctionCallDelta(name: tool.name.nilIfEmpty)
    )
  }

  mutating func appendToolInput(index: Int, partialJSON: String?) -> AIToolCallDelta? {
    guard let partialJSON, !partialJSON.isEmpty else { return nil }
    var tool = toolsByIndex[index] ?? PartialTool()
    tool.arguments.append(partialJSON)
    toolsByIndex[index] = tool
    return AIToolCallDelta(
      index: index,
      function: AIToolFunctionCallDelta(arguments: partialJSON)
    )
  }

  func validateToolInput(at index: Int) throws {
    guard let tool = toolsByIndex[index] else { return }
    _ = try anthropicToolInput(from: tool.arguments)
  }

  func validateToolInputs() throws {
    for index in toolsByIndex.keys {
      try validateToolInput(at: index)
    }
  }

  var toolCalls: [AIToolCall] {
    toolsByIndex.keys.sorted().compactMap { index in
      guard let tool = toolsByIndex[index], !tool.id.isEmpty, !tool.name.isEmpty else {
        return nil
      }
      return AIToolCall(
        id: tool.id,
        function: AIToolFunctionCall(
          name: tool.name,
          arguments: tool.arguments.nilIfEmpty ?? "{}"
        )
      )
    }
  }

  var tokenUsage: AIChatTokenUsage? {
    guard inputTokens != nil || outputTokens != nil else { return nil }
    let total: Int?
    if let inputTokens, let outputTokens {
      total = inputTokens + outputTokens
    } else {
      total = nil
    }
    return AIChatTokenUsage(
      promptTokens: inputTokens,
      completionTokens: outputTokens,
      totalTokens: total
    )
  }
}
