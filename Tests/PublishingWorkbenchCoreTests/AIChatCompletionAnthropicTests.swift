import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIChatCompletionAnthropicTests: XCTestCase {
  func testAnthropicCompleteUsesNativeMessagesHeadersAndCanonicalBody() async throws {
    let response = Data(
      #"{"id":"msg_1","model":"claude-test","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":3,"output_tokens":5}}"#
        .utf8
    )
    let transport = RecordingAIChatTransport(data: response, statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let config = anthropicConfig(vision: true)
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "lookup",
        description: "Look up a value",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "q": .object(["type": .string("string")])
          ]),
        ])
      )
    )
    let request = AIChatCompletionRequest(
      model: "claude-test",
      messages: [
        AIChatMessage(role: "system", content: "System rule"),
        AIChatMessage(
          role: "user",
          content: .parts([
            .text("Read this image"),
            .imageURL("data:image/png;base64,aGVsbG8="),
          ])
        ),
        AIChatMessage(
          role: "assistant",
          content: "",
          toolCalls: [
            AIToolCall(
              id: "call_1",
              function: AIToolFunctionCall(name: "lookup", arguments: #"{"q":"swift"}"#)
            )
          ]
        ),
        AIChatMessage(
          role: "tool",
          content: "result",
          toolCallID: "call_1"
        ),
      ],
      temperature: 0.2,
      maximumOutputTokens: 128,
      tools: [tool],
      toolChoice: .auto
    )

    let prepared = try client.prepareRequest(
      request,
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let result = try await client.complete(
      request: request,
      config: config,
      apiKey: "anthropic-secret",
      purpose: .interactiveChat
    )

    XCTAssertEqual(result.content, "done")
    XCTAssertEqual(result.tokenUsage?.promptTokens, 3)
    XCTAssertEqual(result.tokenUsage?.completionTokens, 5)
    let capturedRequest = await transport.capturedRequest()
    let captured = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(captured.url?.path, "/v1/messages")
    XCTAssertEqual(captured.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
    XCTAssertEqual(captured.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(captured.httpBody, prepared.encodedBody)
    XCTAssertFalse(
      String(data: prepared.encodedBody, encoding: .utf8)?.contains("anthropic-secret") == true
    )

    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as? [String: Any]
    )
    XCTAssertEqual(json["model"] as? String, "claude-test")
    XCTAssertEqual(json["max_tokens"] as? Int, 128)
    XCTAssertEqual(json["system"] as? String, "System rule")
    XCTAssertNil(json["stream"])
    let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    let userBlocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
    XCTAssertEqual(userBlocks[0]["type"] as? String, "text")
    XCTAssertEqual(userBlocks[1]["type"] as? String, "image")
    let source = try XCTUnwrap(userBlocks[1]["source"] as? [String: Any])
    XCTAssertEqual(source["type"] as? String, "base64")
    XCTAssertEqual(source["media_type"] as? String, "image/png")
    XCTAssertEqual(source["data"] as? String, "aGVsbG8=")
    let resultBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
    XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
    XCTAssertEqual(resultBlocks.first?["tool_use_id"] as? String, "call_1")
    let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.first?["name"] as? String, "lookup")
    XCTAssertNotNil(tools.first?["input_schema"] as? [String: Any])
  }

  func testAnthropicNonStreamingResponseMapsToolUseAndUsage() async throws {
    let response = Data(
      #"{"id":"msg_2","model":"claude-test","content":[{"type":"text","text":"I need a tool"},{"type":"tool_use","id":"tool_1","name":"lookup","input":{"q":"swift"}}],"usage":{"input_tokens":7,"output_tokens":11}}"#
        .utf8
    )
    let transport = RecordingAIChatTransport(data: response, statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    XCTAssertEqual(result.content, "I need a tool")
    XCTAssertEqual(result.toolCalls.count, 1)
    XCTAssertEqual(result.toolCalls[0].id, "tool_1")
    XCTAssertEqual(result.toolCalls[0].function.name, "lookup")
    XCTAssertEqual(result.toolCalls[0].function.arguments, #"{"q":"swift"}"#)
    XCTAssertEqual(result.tokenUsage?.totalTokens, 18)
  }

  func testAnthropicToolChoiceNoneOmitsToolsInsteadOfAccidentallyUsingAuto() throws {
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "lookup",
        parameters: .object(["type": .string("object")])
      )
    )
    let client = AIChatCompletionClient()
    let config = anthropicConfig()
    let disabled = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "claude-test",
        messages: [AIChatMessage(role: "user", content: "hi")],
        tools: [tool],
        toolChoice: AIToolChoice.none
      ),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let disabledJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: disabled.encodedBody) as? [String: Any]
    )
    XCTAssertNil(disabledJSON["tools"])
    XCTAssertNil(disabledJSON["tool_choice"])

    let automatic = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "claude-test",
        messages: [AIChatMessage(role: "user", content: "hi")],
        tools: [tool]
      ),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let automaticJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: automatic.encodedBody) as? [String: Any]
    )
    XCTAssertNotNil(automaticJSON["tools"])
    XCTAssertNil(automaticJSON["tool_choice"])
  }

  func testAnthropicTemperatureIsNormalizedToMessagesRange() throws {
    let client = AIChatCompletionClient()
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "claude-test",
        messages: [AIChatMessage(role: "user", content: "hi")],
        temperature: 1.5
      ),
      config: anthropicConfig(),
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: prepared.encodedBody) as? [String: Any]
    )
    XCTAssertEqual(json["temperature"] as? Double, 1.0)
  }

  func testAnthropicToolUseInputMustBeJSONObject() {
    let client = AIChatCompletionClient()
    XCTAssertThrowsError(
      try client.prepareRequest(
        AIChatCompletionRequest(
          model: "claude-test",
          messages: [
            AIChatMessage(
              role: "assistant",
              content: "",
              toolCalls: [
                AIToolCall(
                  id: "call_1",
                  function: AIToolFunctionCall(name: "lookup", arguments: "[]")
                )
              ]
            )
          ]
        ),
        config: anthropicConfig(),
        purpose: .interactiveChat,
        mode: .nonStreaming
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .invalidResponse)
    }
  }

  func testAnthropicStructuredOutputIsRejectedInsteadOfSilentlyDropped() {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    XCTAssertThrowsError(
      try client.prepareRequest(
        AIChatCompletionRequest(
          model: "claude-test",
          messages: [AIChatMessage(role: "user", content: "return JSON")],
          responseFormat: .jsonObject
        ),
        config: anthropicConfig(),
        purpose: .capabilityProbe,
        mode: .nonStreaming
      )
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .unsupportedAnthropicStructuredOutput
      )
    }
  }

  func testAnthropicRemoteImageURLFailsClosedBeforeTransport() {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    var config = anthropicConfig()
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: config)
    config.capabilityProbeEvidence = [
      .visionInput: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .visionInput,
        outcome: .supported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      )
    ]
    XCTAssertThrowsError(
      try client.prepareRequest(
        AIChatCompletionRequest(
          model: "claude-test",
          messages: [
            AIChatMessage(
              role: "user",
              content: .parts([.imageURL("https://example.com/remote.png")])
            )
          ]
        ),
        config: config,
        purpose: .interactiveChat,
        mode: .nonStreaming
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .invalidResponse)
    }
  }

  func testAnthropicStreamRequiresMessageStopAndMapsTextUsage() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"event: message_start"#,
        #"data: {"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}"#,
        "",
        #"event: content_block_start"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        "",
        #"event: content_block_delta"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        "",
        #"event: message_delta"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}"#,
        "",
        #"event: message_stop"#,
        #"data: {"type":"message_stop"}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    var content = ""
    var finished = false
    var usage: AIChatTokenUsage?
    for try await update in stream {
      content += update.contentDelta
      finished = finished || update.isFinished
      usage = update.tokenUsage ?? usage
    }
    XCTAssertEqual(content, "Hello")
    XCTAssertTrue(finished)
    XCTAssertEqual(usage?.promptTokens, 4)
    XCTAssertEqual(usage?.completionTokens, 6)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testAnthropicUnknownStreamEventIsIgnoredUntilMessageStop() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"type":"future_event","payload":{"new_field":true}}"#,
        "",
        #"data: {"type":"message_stop"}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    var finished = false
    for try await update in stream {
      finished = finished || update.isFinished
    }
    XCTAssertTrue(finished)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testAnthropicUnknownStreamEventCannotCompleteStream() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"type":"future_event","payload":{"new_field":true}}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected an unknown event without message_stop to be incomplete")
    } catch let error as AIChatCompletionClientError {
      XCTAssertEqual(error, .incompleteStream)
    }
  }

  func testAnthropicDoneMarkerCannotReplaceMessageStop() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: ["data: [DONE]", ""]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected native Anthropic streams to require message_stop")
    } catch let error as AIChatCompletionClientError {
      XCTAssertEqual(error, .incompleteStream)
    }
  }

  func testAnthropicPartialStreamNeverReplaysAndMissingMessageStopIsIncomplete() async throws {
    let transport = ScriptedAnthropicDataAndStreamTransport(
      attempts: [
        .stream(
          lines: [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#,
            "",
          ]
        ),
        .stream(lines: [#"data: {"type":"message_stop"}"#, ""]),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 2,
        automaticRetryBaseDelay: 0
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .connectionTest
    )

    var content = ""
    do {
      for try await update in stream {
        content += update.contentDelta
      }
      XCTFail("Expected the missing message_stop marker to fail")
    } catch let error as AIChatCompletionClientError {
      XCTAssertTrue(error.didReceivePartialContent)
    }
    XCTAssertEqual(content, "partial")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testAnthropicStreamMapsToolUseInputJSONDeltasUntilMessageStop() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"type":"message_start","message":{"usage":{"input_tokens":2,"output_tokens":0}}}"#,
        "",
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"lookup","input":{}}}"#,
        "",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#,
        "",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#,
        "",
        #"data: {"type":"content_block_stop","index":0}"#,
        "",
        #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}"#,
        "",
        #"data: {"type":"message_stop"}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    var finalToolCalls: [AIToolCall] = []
    var partialArguments = ""
    var finished = false
    for try await update in stream {
      partialArguments += update.toolCallDeltas
        .compactMap { $0.function?.arguments }
        .joined()
      finalToolCalls = update.toolCalls
      finished = finished || update.isFinished
    }
    XCTAssertTrue(finished)
    XCTAssertEqual(partialArguments, #"{"q":"swift"}"#)
    XCTAssertEqual(finalToolCalls.count, 1)
    XCTAssertEqual(finalToolCalls[0].id, "tool_1")
    XCTAssertEqual(finalToolCalls[0].function.name, "lookup")
    XCTAssertEqual(finalToolCalls[0].function.arguments, #"{"q":"swift"}"#)
  }

  func testAnthropicPingDoesNotSatisfyFirstByteTimeout() async throws {
    let transport = ScriptedAnthropicDataAndStreamTransport(
      attempts: [
        .stream(
          lines: [
            #"data: {"type":"ping"}"#,
            "",
          ],
          lineDelayNanoseconds: 100_000_000
        )
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 0.02,
        resourceTimeout: 1,
        maximumAutomaticRetryCount: 0
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .interactiveChat
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected the ping-only stream to time out before content")
    } catch let error as AIChatCompletionClientError {
      guard case .streamInterruptedAfterPartialContent(let detail) = error else {
        XCTFail("Expected the ping to remain outside the first-byte boundary: \(error)")
        return
      }
      XCTAssertTrue(detail.contains("0.0 秒"))
    }
  }

  func testAnthropicConnectionTestRetriesHTTPBeforeResponseOnly() async throws {
    let success = Data(
      #"{"model":"claude-test","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#
        .utf8
    )
    let transport = ScriptedAnthropicDataAndStreamTransport(
      attempts: [
        .data(Data(#"{"error":"busy"}"#.utf8), statusCode: 503),
        .data(success, statusCode: 200),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 1,
        automaticRetryBaseDelay: 0,
        maximumAutomaticRetryAfterDelay: 2
      )
    )
    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "claude-test", messages: []),
      config: anthropicConfig(),
      apiKey: "key",
      purpose: .connectionTest
    )
    XCTAssertEqual(result.content, "ok")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testAnthropicInteractiveAndSuccessfulResponseDecodeFailureDoNotRetry() async throws {
    let transport = ScriptedAnthropicDataAndStreamTransport(
      attempts: [
        .data(Data(#"{"error":"busy"}"#.utf8), statusCode: 503),
        .data(
          Data(#"{"model":"claude-test","content":[{"type":"text","text":"duplicate"}]}"#.utf8),
          statusCode: 200),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 2,
        automaticRetryBaseDelay: 0
      )
    )
    do {
      _ = try await client.complete(
        request: AIChatCompletionRequest(model: "claude-test", messages: []),
        config: anthropicConfig(),
        apiKey: "key",
        purpose: .interactiveChat
      )
      XCTFail("Expected interactive requests to remain one-shot")
    } catch let error as AIChatCompletionClientError {
      guard case .httpStatus(503, _, _) = error else {
        XCTFail("Unexpected error: \(error)")
        return
      }
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)

    let invalidResponseTransport = ScriptedAnthropicDataAndStreamTransport(
      attempts: [
        .data(Data("{}".utf8), statusCode: 200),
        .data(
          Data(#"{"model":"claude-test","content":[{"type":"text","text":"duplicate"}]}"#.utf8),
          statusCode: 200),
      ]
    )
    let retryClient = AIChatCompletionClient(
      transport: invalidResponseTransport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 2,
        automaticRetryBaseDelay: 0
      )
    )
    do {
      _ = try await retryClient.complete(
        request: AIChatCompletionRequest(model: "claude-test", messages: []),
        config: anthropicConfig(),
        apiKey: "key",
        purpose: .capabilityProbe
      )
      XCTFail("Expected invalid successful response")
    } catch let error as AIChatCompletionClientError {
      XCTAssertEqual(error, .emptyContent)
    }
    let invalidResponseRequestCount = await invalidResponseTransport.capturedRequestCount()
    XCTAssertEqual(invalidResponseRequestCount, 1)
  }

  private func anthropicConfig(vision: Bool = false) -> AIProviderConfig {
    var config = AIProviderConfig(
      preset: .anthropic,
      baseURL: "https://api.anthropic.com/v1",
      model: "claude-test",
      requiresAPIKey: true
    )
    if vision {
      let now = Date()
      let key = AIProviderCapabilityCacheKey(config: config)
      config.capabilityProbeEvidence = [
        .visionInput: AIProviderCapabilityProbeEvidence(
          key: key,
          capability: .visionInput,
          outcome: .supported,
          observedAt: now,
          expiresAt: now.addingTimeInterval(60)
        )
      ]
    }
    return config
  }
}

private enum ScriptedAnthropicAttempt: Sendable {
  case data(Data, statusCode: Int, headerFields: [String: String]? = nil)
  case stream(lines: [String], lineDelayNanoseconds: UInt64 = 0)
}

private actor ScriptedAnthropicDataAndStreamTransport: AIChatStreamingTransport {
  private let attempts: [ScriptedAnthropicAttempt]
  private var requestCount = 0

  init(attempts: [ScriptedAnthropicAttempt]) {
    self.attempts = attempts
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let attempt = nextAttempt()
    guard case .data(let data, let statusCode, let headerFields) = attempt else {
      throw URLError(.badServerResponse)
    }
    return (data, response(for: request, statusCode: statusCode, headerFields: headerFields))
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    let attempt = nextAttempt()
    guard case .stream(let lines, let delay) = attempt else {
      throw URLError(.badServerResponse)
    }
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for line in lines {
            if delay > 0 {
              try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            continuation.yield(line)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response(for: request, statusCode: 200, headerFields: nil))
  }

  func capturedRequestCount() -> Int {
    requestCount
  }

  private func nextAttempt() -> ScriptedAnthropicAttempt {
    let index = requestCount
    requestCount += 1
    guard !attempts.isEmpty else {
      return .data(Data(), statusCode: 500)
    }
    return attempts[min(index, attempts.count - 1)]
  }

  private func response(
    for request: URLRequest,
    statusCode: Int,
    headerFields: [String: String]?
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headerFields
    )!
  }
}
