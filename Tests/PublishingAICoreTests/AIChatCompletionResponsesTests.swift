import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatCompletionResponsesTests: XCTestCase {
  func testResponseContentDecodesSupportedShapesAndRejectsInvalidObject() throws {
    let decoder = JSONDecoder()

    let stringContent = try decoder.decode(
      AIResponseContent.self,
      from: Data(#""plain""#.utf8)
    )
    let stringArrayContent = try decoder.decode(
      AIResponseContent.self,
      from: Data(#"["A","B"]"#.utf8)
    )
    let partsContent = try decoder.decode(
      AIResponseContent.self,
      from: Data(
        #"[{"type":"text","text":"First"},{"type":"image_url"},{"type":"text","text":"Second"}]"#.utf8
      )
    )

    XCTAssertEqual(stringContent.text, "plain")
    XCTAssertEqual(stringArrayContent.text, "A\nB")
    XCTAssertEqual(partsContent.text, "First\nSecond")
    XCTAssertThrowsError(
      try decoder.decode(
        AIResponseContent.self,
        from: Data(#"{"text":"unsupported"}"#.utf8)
      )
    ) { error in
      XCTAssertTrue(error is DecodingError)
    }
  }

  func testCompletionResponseDecodesEnvelopeUsageReasoningAndToolCalls() throws {
    let data = Data(
      #"{"model":"test-model","choices":[{"message":{"content":"final","reasoning_content":["hidden","trace"],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"draft.read","arguments":"{\"path\":\"post.md\"}"}}]}}],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}"#.utf8
    )

    let response = try JSONDecoder().decode(AIChatCompletionResponse.self, from: data)
    let message = try XCTUnwrap(response.choices.first?.message)

    XCTAssertEqual(response.model, "test-model")
    XCTAssertEqual(message.contentText, "final")
    XCTAssertEqual(message.reasoningContent?.text, "hidden\ntrace")
    XCTAssertEqual(
      message.toolCalls,
      [
        AIToolCall(
          id: "call_1",
          function: AIToolFunctionCall(
            name: "draft.read",
            arguments: #"{"path":"post.md"}"#
          )
        )
      ]
    )
    XCTAssertEqual(
      response.usage?.tokenUsage,
      AIChatTokenUsage(promptTokens: 12, completionTokens: 5, totalTokens: 17)
    )
  }

  func testStreamChunkResolvesChoiceAndRootContentInPriorityOrder() throws {
    let decoder = JSONDecoder()
    let choiceChunk = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(
        #"{"choices":[{"delta":{"content":"A","reasoning_content":"hidden"},"message":{"content":"ignored"}},{"message":{"content":"B"},"finish_reason":"stop"}],"response_delta":"ignored-root","content":"ignored-root-content","usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#.utf8
      )
    )
    let responseDeltaChunk = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(#"{"response_delta":["R1","R2"],"content":"ignored"}"#.utf8)
    )
    let rootContentChunk = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(
        #"{"response_delta":[],"content":[{"type":"text","text":"Root"}]}"#.utf8
      )
    )

    XCTAssertEqual(choiceChunk.contentDelta, "AB")
    XCTAssertEqual(choiceChunk.choices.first?.delta?.reasoningContent?.text, "hidden")
    XCTAssertTrue(choiceChunk.isFinished)
    XCTAssertEqual(
      choiceChunk.usage?.tokenUsage,
      AIChatTokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5)
    )
    XCTAssertEqual(responseDeltaChunk.choices, [])
    XCTAssertEqual(responseDeltaChunk.contentDelta, "R1\nR2")
    XCTAssertFalse(responseDeltaChunk.isFinished)
    XCTAssertEqual(rootContentChunk.contentDelta, "Root")
  }

  func testStreamChunkDecodesDeltaAndMessageToolCallVariants() throws {
    let decoder = JSONDecoder()
    let deltaChunk = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(
        #"{"choices":[{"delta":{"tool_calls":[{"index":2,"id":"call_2","type":"function","function":{"name":"draft.read","arguments":"{}"}}]}}]}"#.utf8
      )
    )
    let messageChunk = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(
        #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_0","type":"function","function":{"name":"knowledge.search","arguments":"{\"query\":\"RepoPress\"}"}},{"id":"call_1","type":"function","function":{"name":"draft.read","arguments":"{\"path\":\"post.md\"}"}}]}}]}"#.utf8
      )
    )

    XCTAssertEqual(
      deltaChunk.toolCallDeltas,
      [
        AIToolCallDelta(
          index: 2,
          id: "call_2",
          type: "function",
          function: AIToolFunctionCallDelta(name: "draft.read", arguments: "{}")
        )
      ]
    )
    XCTAssertEqual(
      messageChunk.toolCallDeltas,
      [
        AIToolCallDelta(
          index: 0,
          id: "call_0",
          type: "function",
          function: AIToolFunctionCallDelta(
            name: "knowledge.search",
            arguments: #"{"query":"RepoPress"}"#
          )
        ),
        AIToolCallDelta(
          index: 1,
          id: "call_1",
          type: "function",
          function: AIToolFunctionCallDelta(
            name: "draft.read",
            arguments: #"{"path":"post.md"}"#
          )
        ),
      ]
    )
  }

  func testStreamChunkDecodesStringObjectAndCodeOnlyErrors() throws {
    let decoder = JSONDecoder()
    let stringError = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(#"{"error":"busy"}"#.utf8)
    )
    let objectError = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(#"{"error":{"message":"provider busy","code":"rate_limit"}}"#.utf8)
    )
    let codeOnlyError = try decoder.decode(
      AIChatCompletionStreamChunk.self,
      from: Data(#"{"error":{"code":"rate_limit"}}"#.utf8)
    )

    XCTAssertEqual(stringError.error?.displayMessage, "busy")
    XCTAssertEqual(objectError.error?.displayMessage, "provider busy")
    XCTAssertEqual(codeOnlyError.error?.displayMessage, "rate_limit")
  }
}
