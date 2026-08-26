import Foundation
import PublishingCoreSupport

package struct AIChatCompletionResponse: Decodable, Hashable {
  package var model: String?
  package var choices: [Choice]
  package var usage: Usage?

  package struct Usage: Decodable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    package var tokenUsage: AIChatTokenUsage {
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

  package struct Choice: Decodable, Hashable {
    package var message: Message
  }

  package struct Message: Decodable, Hashable {
    var content: AIResponseContent?
    var reasoningContent: AIResponseContent?
    package var toolCalls: [AIToolCall]?

    package var contentText: String {
      content?.text ?? ""
    }

    private enum CodingKeys: String, CodingKey {
      case content
      case reasoningContent = "reasoning_content"
      case toolCalls = "tool_calls"
    }
  }
}

package struct AIChatCompletionStreamChunk: Decodable, Hashable {
  var choices: [Choice]
  package var usage: AIChatCompletionResponse.Usage?
  var responseDelta: AIResponseContent?
  var responseText: AIResponseContent?
  package var error: APIError?

  package var contentDelta: String {
    let choiceText =
      choices
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

  package var toolCallDeltas: [AIToolCallDelta] {
    choices.flatMap { choice in
      if let deltas = choice.delta?.toolCalls {
        return deltas
      }
      return (choice.message?.toolCalls ?? []).enumerated().map { index, toolCall in
        AIToolCallDelta(
          index: index,
          id: toolCall.id,
          type: toolCall.type,
          function: AIToolFunctionCallDelta(
            name: toolCall.function.name,
            arguments: toolCall.function.arguments
          )
        )
      }
    }
  }

  package var isFinished: Bool {
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

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    usage = try container.decodeIfPresent(AIChatCompletionResponse.Usage.self, forKey: .usage)
    responseDelta = try container.decodeIfPresent(AIResponseContent.self, forKey: .responseDelta)
    responseText = try container.decodeIfPresent(AIResponseContent.self, forKey: .responseText)
    error = try container.decodeIfPresent(APIError.self, forKey: .error)
  }

  struct Choice: Decodable, Hashable {
    var delta: Delta?
    var message: AIChatCompletionResponse.Message?
    var finishReason: String?

    private enum CodingKeys: String, CodingKey {
      case delta
      case message
      case finishReason = "finish_reason"
    }
  }

  struct Delta: Decodable, Hashable {
    var content: AIResponseContent?
    var reasoningContent: AIResponseContent?
    var toolCalls: [AIToolCallDelta]?

    var contentText: String {
      content?.text ?? ""
    }

    private enum CodingKeys: String, CodingKey {
      case content
      case reasoningContent = "reasoning_content"
      case toolCalls = "tool_calls"
    }
  }

  package struct APIError: Decodable, Hashable {
    var message: String?
    var code: String?

    package var displayMessage: String {
      if let message = message?.nilIfEmpty {
        return message
      }
      return code ?? ""
    }

    package init(from decoder: Decoder) throws {
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
      DecodingError.Context(
        codingPath: decoder.codingPath, debugDescription: "Unsupported AI response content shape")
    )
  }
}
