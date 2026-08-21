import CoreFoundation
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIChatCompletionClientTests: XCTestCase {
  func testCompleteRejectsOversizedResponseBeforeDecoding() async {
    let maximumByteCount = URLSessionAIChatTransport.maximumResponseByteCount
    let transport = RecordingAIChatTransport(
      data: Data(repeating: 0x41, count: maximumByteCount + 1),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .local,
          baseURL: "http://127.0.0.1:11434/v1",
          model: "model",
          requiresAPIKey: false
        ),
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .responseTooLarge(maximumBytes: maximumByteCount)
      )
    }
  }

  func testStreamRejectsOversizedSingleLine() async throws {
    let maximumLineByteCount = URLSessionAIChatTransport.maximumStreamingLineByteCount
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [String(repeating: "a", count: maximumLineByteCount + 1)]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "model",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    await XCTAssertThrowsErrorAsync(
      try await consume(stream)
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .responseTooLarge(maximumBytes: URLSessionAIChatTransport.maximumStreamingResponseByteCount)
      )
    }
  }

  func testBuildsOpenAICompatibleRequestWithAuthorization() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"Done"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    var config = AIProviderConfig()
    config.baseURL = "https://api.deepseek.com"
    config.model = "deepseek-v4-flash"

    let result = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: config,
      apiKey: "secret"
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(result.content, "Done")
  }

  func testDefaultClientBindsProfileProxyToItsURLSessionTransport() throws {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        proxyURL: "socks5://127.0.0.1:1080"
      )
    )

    let selected = try XCTUnwrap(
      try client.transport(for: config) as? URLSessionAIChatTransport
    )
    let dictionary = try XCTUnwrap(selected.sessionConfiguration.connectionProxyDictionary)
    XCTAssertEqual(
      dictionary[kCFStreamPropertySOCKSProxyHost as String] as? String,
      "127.0.0.1"
    )
    XCTAssertEqual(
      dictionary[kCFStreamPropertySOCKSProxyPort as String] as? Int,
      1080
    )

    let selectedAgain = try XCTUnwrap(
      try client.transport(for: config) as? URLSessionAIChatTransport
    )
    XCTAssertEqual(selected.sessionIdentity, selectedAgain.sessionIdentity)
    let copiedClient = client
    let selectedFromCopy = try XCTUnwrap(
      try copiedClient.transport(for: config) as? URLSessionAIChatTransport
    )
    XCTAssertEqual(selected.sessionIdentity, selectedFromCopy.sessionIdentity)

    let otherConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        proxyURL: "http://127.0.0.1:8080"
      )
    )
    let other = try XCTUnwrap(
      try client.transport(for: otherConfig) as? URLSessionAIChatTransport
    )
    XCTAssertNotEqual(selected.sessionIdentity, other.sessionIdentity)
  }

  func testDefaultClientRejectsInvalidProfileProxyBeforeTransport() {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        proxyURL: "http://proxy.example:70000"
      )
    )

    XCTAssertThrowsError(try client.transport(for: config)) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .invalidProxyURL)
    }
  }

  func testLegacyRequestOmitsAllOptionalToolAndStructuredOutputFields() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"Done"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: "legacy-model",
        messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://example.com/v1",
        model: "legacy-model",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(Set(payload.keys), Set(["model", "messages"]))
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(Set(messages[0].keys), Set(["role", "content"]))
    XCTAssertEqual(messages[0]["role"] as? String, "user")
    XCTAssertEqual(messages[0]["content"] as? String, "Hello")
  }

  func testUnknownCapabilityRequestStripsVisionToolsAndStructuredOutputFields() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"Done"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "draft.read",
        parameters: .object(["type": .string("object")])
      )
    )
    let attachment = AIChatImageAttachment(
      filename: "secret.png",
      mimeType: "image/png",
      data: Data("user-image-bytes".utf8)
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "unknown-model",
      requiresAPIKey: false
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [
          AIChatMessage(
            role: "user",
            content: .parts([
              .text("Review this."),
              .imageURL(attachment.dataURL),
            ])
          )
        ],
        tools: [tool],
        toolChoice: .required,
        responseFormat: .jsonObject
      ),
      config: config,
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(payload["tools"])
    XCTAssertNil(payload["tool_choice"])
    XCTAssertNil(payload["response_format"])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
    XCTAssertEqual(userContent.count, 1)
    XCTAssertEqual(userContent[0]["type"] as? String, "text")
    XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("user-image-bytes") ?? true)
  }

  func testUnknownToolHistoryFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"must not send"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "unknown-model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(
          model: config.model,
          messages: [
            AIChatMessage(
              role: "assistant",
              toolCalls: [
                AIToolCall(
                  id: "call_1",
                  function: AIToolFunctionCall(name: "draft.read", arguments: "{}")
                )
              ]),
            AIChatMessage(role: "tool", content: "result", toolCallID: "call_1"),
          ]
        ),
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .unsupportedToolHistory)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testUnknownVisionImageOnlyMessageFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"must not send"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "unknown-model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(
          model: config.model,
          messages: [
            AIChatMessage(
              role: "user",
              content: .parts([.imageURL("data:image/png;base64,fixture")])
            )
          ]
        ),
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .imageContentRequiresVisionCapability
      )
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testEncodesToolsChoiceStructuredSchemaAndToolResultMessages() async throws {
    let toolCall = AIToolCall(
      id: "call_read_1",
      function: AIToolFunctionCall(
        name: "draft.read",
        arguments: #"{"path":"posts/example.md"}"#
      )
    )
    let parameterSchema: AIStructuredOutputJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "path": .object(["type": .string("string")])
      ]),
      "required": .array([.string("path")]),
      "additionalProperties": .bool(false),
    ])
    let responseSchema: AIStructuredOutputJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "answer": .object(["type": .string("string")])
      ]),
      "required": .array([.string("answer")]),
      "additionalProperties": .bool(false),
    ])
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"Done"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: "protocol-model",
        messages: [
          AIChatMessage(role: "user", content: "Read the draft."),
          AIChatMessage(role: "assistant", toolCalls: [toolCall]),
          AIChatMessage(
            role: "tool",
            content: #"{"status":"ok"}"#,
            toolCallID: toolCall.id
          ),
        ],
        tools: [
          AIToolDefinition(
            function: AIToolFunctionDefinition(
              name: "draft.read",
              description: "Read a draft without modifying it.",
              parameters: parameterSchema,
              strict: true
            )
          )
        ],
        toolChoice: .function(name: "draft.read"),
        responseFormat: .jsonSchema(
          AIStructuredOutputJSONSchema(
            name: "draft_answer",
            description: "A structured answer.",
            schema: responseSchema,
            strict: true
          )
        )
      ),
      config: protocolCapabilityEvidenceConfig,
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 3)
    XCTAssertEqual(Set(messages[1].keys), Set(["role", "tool_calls"]))
    let encodedCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
    XCTAssertEqual(encodedCalls.count, 1)
    XCTAssertEqual(encodedCalls[0]["id"] as? String, "call_read_1")
    XCTAssertEqual(encodedCalls[0]["type"] as? String, "function")
    let encodedCallFunction = try XCTUnwrap(encodedCalls[0]["function"] as? [String: Any])
    XCTAssertEqual(encodedCallFunction["name"] as? String, "draft.read")
    XCTAssertEqual(encodedCallFunction["arguments"] as? String, #"{"path":"posts/example.md"}"#)
    XCTAssertEqual(Set(messages[2].keys), Set(["role", "content", "tool_call_id"]))
    XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_read_1")

    let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 1)
    XCTAssertEqual(tools[0]["type"] as? String, "function")
    let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
    XCTAssertEqual(Set(function.keys), Set(["name", "description", "parameters", "strict"]))
    XCTAssertEqual(function["name"] as? String, "draft.read")
    XCTAssertEqual(function["strict"] as? Bool, true)
    let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
    XCTAssertEqual(parameters["type"] as? String, "object")
    XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)

    let toolChoice = try XCTUnwrap(payload["tool_choice"] as? [String: Any])
    XCTAssertEqual(toolChoice["type"] as? String, "function")
    let selectedFunction = try XCTUnwrap(toolChoice["function"] as? [String: Any])
    XCTAssertEqual(selectedFunction["name"] as? String, "draft.read")

    let responseFormat = try XCTUnwrap(payload["response_format"] as? [String: Any])
    XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
    let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
    XCTAssertEqual(Set(jsonSchema.keys), Set(["name", "description", "schema", "strict"]))
    XCTAssertEqual(jsonSchema["name"] as? String, "draft_answer")
    XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
    let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
    XCTAssertEqual(schema["type"] as? String, "object")
    XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
  }

  func testNonStreamingResponseReturnsMultipleToolCallsWithoutText() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(
        content:
          #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"knowledge.search","arguments":"{\"query\":\"RepoPress\"}"}},{"id":"call_2","type":"function","function":{"name":"draft.read","arguments":"{\"path\":\"posts/example.md\"}"}}]}"#,
        usage: #"{"prompt_tokens":20,"completion_tokens":8,"total_tokens":28}"#
      ),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "model",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "")
    XCTAssertEqual(
      result.toolCalls,
      [
        AIToolCall(
          id: "call_1",
          function: AIToolFunctionCall(
            name: "knowledge.search",
            arguments: #"{"query":"RepoPress"}"#
          )
        ),
        AIToolCall(
          id: "call_2",
          function: AIToolFunctionCall(
            name: "draft.read",
            arguments: #"{"path":"posts/example.md"}"#
          )
        ),
      ]
    )
    XCTAssertEqual(result.tokenUsage?.totalTokens, 28)
  }

  func testDecodesStringArrayContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":["A","B"]}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "A\nB")
  }

  func testDecodesTextPartContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(
        content:
          #"{"role":"assistant","content":[{"type":"text","text":"First"},{"type":"text","text":"Second"}]}"#
      ),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "First\nSecond")
  }

  func testDecodesModelAndTokenUsage() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(
        content: #"{"role":"assistant","content":"Done"}"#,
        usage: #"{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}"#
      ),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.rawModel, "test-model")
    XCTAssertEqual(
      result.tokenUsage,
      AIChatTokenUsage(promptTokens: 12, completionTokens: 5, totalTokens: 17)
    )
    XCTAssertEqual(result.tokenUsage?.displayText, "17 tokens · 输入 12 · 输出 5")
  }

  func testRejectsReasoningContentWhenFinalContentIsNull() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(
        content: #"{"role":"assistant","content":null,"reasoning_content":"先给一个简短回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    do {
      _ = try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model",
          requiresAPIKey: false),
        apiKey: nil
      )
      XCTFail("Reasoning content must never be exposed as the final assistant reply.")
    } catch {
      XCTAssertEqual(error as? AIChatCompletionClientError, .emptyContent)
    }
  }

  func testPrefersFinalContentOverReasoningContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(
        content: #"{"role":"assistant","reasoning_content":"这是思考过程。","content":"这是最终回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "这是最终回复。")
  }

  func testStreamingIgnoresReasoningContentAndEmitsOnlyFinalContent() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"reasoning_content":"这是思考过程。"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"这是最终回复。"},"finish_reason":"stop"}]}"#,
        "",
        "data: [DONE]",
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "model",
      requiresAPIKey: false
    )

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "请直接回答。")]
      ),
      config: config,
      apiKey: nil
    )

    var visibleContent = ""
    for try await update in stream {
      visibleContent += update.contentDelta
    }

    XCTAssertEqual(visibleContent, "这是最终回复。")
    XCTAssertFalse(visibleContent.contains("思考过程"))
  }

  func testDeepSeekInteractiveChatUsesThinkingAndMapsLegacyModel() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"已按 OpenAI 兼容接口回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [AIChatMessage(role: "user", content: "Hello")],
        temperature: 0.4
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "gpt-4.1-mini")
    XCTAssertEqual(payload["temperature"] as? Double, 0.4)
  }

  func testExplicitQuickReasoningOverridesInteractiveDefaults() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"快速回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      requiresAPIKey: false
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [AIChatMessage(role: "user", content: "Hello")],
        thinking: AIProviderThinkingOption(type: "disabled")
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(payload["reasoning_effort"])
    let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "disabled")
  }

  func testBuildsOpenAICompatibleRequestWithImageContentParts() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"图片看起来适合作为封面。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let attachment = AIChatImageAttachment(
      filename: "cover.png",
      mimeType: "image/png",
      data: Data("image-bytes".utf8)
    )
    var config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    let evidenceNow = Date()
    let evidenceKey = AIProviderCapabilityCacheKey(config: config)
    config.capabilityProbeEvidence = [
      .visionInput: AIProviderCapabilityProbeEvidence(
        key: evidenceKey,
        capability: .visionInput,
        outcome: .supported,
        observedAt: evidenceNow,
        expiresAt: evidenceNow.addingTimeInterval(60)
      )
    ]

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [
          AIChatMessage(role: "system", content: "你是图片发布助手。"),
          AIChatMessage(role: "user", content: "上一条纯文本。"),
          AIChatMessage(
            role: "user",
            content: .parts([
              .text("帮我看看这张封面图。"),
              .imageURL(attachment.dataURL),
            ])
          ),
        ]
      ),
      config: config,
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 3)
    XCTAssertEqual(messages[0]["content"] as? String, "你是图片发布助手。")
    XCTAssertEqual(messages[1]["content"] as? String, "上一条纯文本。")

    let imageMessageContent = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
    XCTAssertEqual(imageMessageContent.count, 2)
    XCTAssertEqual(imageMessageContent[0]["type"] as? String, "text")
    XCTAssertEqual(imageMessageContent[0]["text"] as? String, "帮我看看这张封面图。")
    XCTAssertEqual(imageMessageContent[1]["type"] as? String, "image_url")
    let imageURL = try XCTUnwrap(imageMessageContent[1]["image_url"] as? [String: Any])
    XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,aW1hZ2UtYnl0ZXM=")
  }

  func testStreamsOpenAICompatibleResponseDeltasAndUsage() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"好。"}}],"#
          + #""usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#,
        "",
        "data: [DONE]",
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = streamingSupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "gpt-4.1",
        requiresAPIKey: false
      ))

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [AIChatMessage(role: "user", content: "打个招呼。")],
        temperature: 0.4
      ),
      config: config,
      apiKey: nil,
      purpose: .connectionTest
    )

    var updates: [AIChatStreamUpdate] = []
    for try await update in stream {
      updates.append(update)
      if update.isFinished {
        break
      }
    }

    XCTAssertEqual(updates.map(\.contentDelta), ["你", "好。", ""])
    XCTAssertEqual(updates[1].tokenUsage?.totalTokens, 5)
    XCTAssertTrue(updates[2].isFinished)

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
    let streamOptions = try XCTUnwrap(payload["stream_options"] as? [String: Any])
    XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
  }

  func testStreamingAggregatesMultipleToolCallsByIndexAcrossChunks() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"reasoning_content":"hidden reasoning","content":"Working. ","tool_calls":[{"index":1,"id":"call_","type":"function","function":{"name":"read_","arguments":"{\"path\":\""}},{"index":0,"id":"call_0","type":"function","function":{"name":"search","arguments":"{\"query\":\""}}]}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"RepoPress\"}"}},{"index":1,"id":"1","function":{"name":"draft","arguments":"posts/example.md\"}"}}]}}]}"#,
        "",
        #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9,"completion_tokens":7,"total_tokens":16}}"#,
        "",
        "data: [DONE]",
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "model",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    var updates: [AIChatStreamUpdate] = []
    for try await update in stream {
      updates.append(update)
    }

    XCTAssertEqual(updates.map(\.contentDelta).joined(), "Working.")
    XCTAssertFalse(updates.map(\.contentDelta).joined().contains("hidden reasoning"))
    XCTAssertEqual(updates.flatMap(\.toolCallDeltas).map(\.index), [1, 0, 0, 1])
    let finishedUpdate = try XCTUnwrap(updates.last(where: { $0.isFinished }))
    XCTAssertEqual(
      finishedUpdate.toolCalls,
      [
        AIToolCall(
          id: "call_0",
          function: AIToolFunctionCall(
            name: "search",
            arguments: #"{"query":"RepoPress"}"#
          )
        ),
        AIToolCall(
          id: "call_1",
          function: AIToolFunctionCall(
            name: "read_draft",
            arguments: #"{"path":"posts/example.md"}"#
          )
        ),
      ]
    )
    XCTAssertEqual(updates.first(where: { $0.tokenUsage != nil })?.tokenUsage?.totalTokens, 16)
  }

  func testCompatibilityStreamRejectionFallsBackExactlyOnceToNonStreaming() async throws {
    for statusCode in [400, 404] {
      let transport = CompatibilityFallbackAIChatTransport(
        streamingStatusCode: statusCode,
        streamingErrorBody: #"{"error":{"message":"stream parameter is not supported"}}"#,
        fallbackData: Data(
          """
          {
            "model": "fallback-model",
            "choices": [
              { "message": {"role":"assistant","content":"fallback"} }
            ],
            "usage": {"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}
          }
          """.utf8)
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
      let config = streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false,
          advancedSettings: AIProviderAdvancedSettings(
            systemPrompt: "Keep exactly one system instruction."
          )
        ))

      let stream = try await client.stream(
        request: AIChatCompletionRequest(
          model: "model",
          messages: [
            AIChatMessage(role: "system", content: "Keep exactly one system instruction."),
            AIChatMessage(role: "user", content: "hello"),
          ]
        ),
        config: config,
        apiKey: nil,
        purpose: .connectionTest
      )
      var content = ""
      var usage: AIChatTokenUsage?
      for try await update in stream {
        content += update.contentDelta
        usage = update.tokenUsage ?? usage
      }

      XCTAssertEqual(content, "fallback", "HTTP \(statusCode)")
      XCTAssertEqual(usage?.totalTokens, 5, "HTTP \(statusCode)")
      let requests = await transport.capturedRequests()
      XCTAssertEqual(requests.count, 2, "HTTP \(statusCode)")
      let firstBody = try XCTUnwrap(requests[0].httpBody)
      let secondBody = try XCTUnwrap(requests[1].httpBody)
      let firstPayload = try XCTUnwrap(
        JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
      let secondPayload = try XCTUnwrap(
        JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
      XCTAssertEqual(firstPayload["stream"] as? Bool, true, "HTTP \(statusCode)")
      XCTAssertNil(secondPayload["stream"], "HTTP \(statusCode)")
      XCTAssertNil(secondPayload["stream_options"], "HTTP \(statusCode)")
      let firstMessages = try XCTUnwrap(firstPayload["messages"] as? [[String: Any]])
      let secondMessages = try XCTUnwrap(secondPayload["messages"] as? [[String: Any]])
      let firstMessagesData = try JSONSerialization.data(
        withJSONObject: firstMessages,
        options: [.sortedKeys]
      )
      let secondMessagesData = try JSONSerialization.data(
        withJSONObject: secondMessages,
        options: [.sortedKeys]
      )
      XCTAssertEqual(firstMessagesData, secondMessagesData, "HTTP \(statusCode)")
      XCTAssertEqual(
        firstMessages.filter { $0["role"] as? String == "system" }.count,
        1,
        "HTTP \(statusCode)"
      )
    }
  }

  func testInteractiveCompatibilityRejectionDoesNotHiddenFallback() async throws {
    let transport = CompatibilityFallbackAIChatTransport(
      streamingStatusCode: 400,
      streamingErrorBody: #"{"error":{"message":"stream parameter is not supported"}}"#,
      fallbackData: Data(
        #"{"choices":[{"message":{"role":"assistant","content":"must not replay"}}]}"#.utf8)
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = streamingSupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://example.com/v1",
        model: "model",
        requiresAPIKey: false
      )
    )

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "hello")]
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    await XCTAssertThrowsErrorAsync(try await consume(stream)) { error in
      guard case .httpStatus(400, _, _) = error as? AIChatCompletionClientError else {
        XCTFail("Expected the original compatibility rejection, got \(error)")
        return
      }
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testGenericEndpointAndModelErrorsDoNotTriggerCompatibilityFallback() async throws {
    let cases: [(Int, String)] = [
      (404, #"{"error":{"message":"route not found"}}"#),
      (400, #"{"error":{"message":"model does not exist"}}"#),
    ]

    for (statusCode, errorBody) in cases {
      let transport = CompatibilityFallbackAIChatTransport(
        streamingStatusCode: statusCode,
        streamingErrorBody: errorBody,
        fallbackData: Data(
          #"{"choices":[{"message":{"role":"assistant","content":"must not replay"}}]}"#.utf8)
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
        request: AIChatCompletionRequest(
          model: "model",
          messages: [AIChatMessage(role: "user", content: "hello")]
        ),
        config: streamingSupportedConfig(
          AIProviderConfig(
            preset: .custom,
            baseURL: "https://example.com/v1",
            model: "model",
            requiresAPIKey: false
          )),
        apiKey: nil,
        purpose: .connectionTest
      )

      do {
        for try await _ in stream {}
        XCTFail("Expected HTTP \(statusCode)")
      } catch let error as AIChatCompletionClientError {
        guard case .httpStatus(let observedStatus, _, _) = error else {
          return XCTFail("Expected HTTP status, got \(error)")
        }
        XCTAssertEqual(observedStatus, statusCode)
      }

      let requestCount = await transport.capturedRequests().count
      XCTAssertEqual(requestCount, 1, "HTTP \(statusCode)")
    }
  }

  func testAnyHTTP2xxResponsePreventsAutomaticReplayAfterReasoningUsageOrSSE() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#,
            "",
          ],
          terminalError: .connectionLost
        ),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"content":"duplicate"}}]}"#,
            "",
          ]
        ),
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
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil,
      purpose: .connectionTest
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected stream interruption")
    } catch let error as AIChatCompletionClientError {
      XCTAssertTrue(error.didReceivePartialContent)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testHTTP2xxWithoutSSEEventsDoesNotRetryOrFallback() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(terminalError: .connectionLost),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"content":"duplicate"}}]}"#,
            "",
          ]
        ),
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )
      ),
      apiKey: nil,
      purpose: .interactiveChat
    )

    await XCTAssertThrowsErrorAsync(try await consume(stream)) { error in
      XCTAssertTrue(error is AIChatCompletionClientError)
      XCTAssertTrue((error as? AIChatCompletionClientError)?.didReceivePartialContent == true)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testSSEDoneMarkerCompletesAfterHeartbeatAndContent() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        ": keep-alive",
        "",
        #"data: {"choices":[{"delta":{"content":"done"}}]}"#,
        "",
        "data: [DONE]",
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil
    )
    var content = ""
    for try await update in stream {
      content += update.contentDelta
    }

    XCTAssertEqual(content, "done")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testSSEFinishReasonCompletesWithoutDoneMarker() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"finished"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil
    )
    var content = ""
    for try await update in stream {
      content += update.contentDelta
    }

    XCTAssertEqual(content, "finished")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testCleanEOFWithoutTerminalMarkerReportsIncompleteResponse() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"partial"}}]}"#,
        "",
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
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil,
      purpose: .connectionTest
    )

    await XCTAssertThrowsErrorAsync(try await consume(stream)) { error in
      guard
        case .streamInterruptedAfterPartialContent(let message) =
          error as? AIChatCompletionClientError
      else {
        XCTFail("Expected incomplete partial response, got \(error)")
        return
      }
      XCTAssertTrue(message.contains("响应不完整"))
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testHeartbeatOnlyEOFReportsIncompleteResponseWithoutPartialBoundary() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [": keep-alive", "", "event: ping", ""]
    )
    let client = AIChatCompletionClient(transport: transport)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil
    )

    await XCTAssertThrowsErrorAsync(try await consume(stream)) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .incompleteStream)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testUnknownUnsupportedAndExpiredStreamingEvidenceFailClosedBeforeTransport() async throws {
    let baseConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: baseConfig)
    var unsupported = baseConfig
    unsupported.capabilityProbeEvidence = [
      .streamingResponse: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .streamingResponse,
        outcome: .unsupported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      )
    ]
    var expired = baseConfig
    expired.capabilityProbeEvidence = [
      .streamingResponse: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .streamingResponse,
        outcome: .supported,
        observedAt: now.addingTimeInterval(-120),
        expiresAt: now.addingTimeInterval(-60)
      )
    ]

    for config in [baseConfig, unsupported, expired] {
      let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
      let client = AIChatCompletionClient(transport: transport)
      await XCTAssertThrowsErrorAsync(
        try await client.stream(
          request: AIChatCompletionRequest(model: "model", messages: []),
          config: config,
          apiKey: nil
        )
      ) { error in
        XCTAssertEqual(error as? AIChatCompletionClientError, .streamingUnsupported)
      }
      let requestCount = await transport.capturedRequestCount()
      XCTAssertEqual(requestCount, 0)
    }
  }

  func testPreparedRequestMatchesCapturedBodyAndNeverContainsAuthorization() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"prepared"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: true,
      advancedSettings: AIProviderAdvancedSettings(
        systemPrompt: "Keep this system instruction once."
      )
    )
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "hello")]
      ),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    _ = try await client.completePrepared(prepared, config: config, apiKey: "secret")

    let capturedRequest = await transport.capturedRequest()
    let captured = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(captured.httpBody, prepared.encodedBody)
    XCTAssertFalse(prepared.encodedBody.contains(Data("secret".utf8)))
    XCTAssertFalse(
      String(data: prepared.encodedBody, encoding: .utf8)?.contains("Authorization") ?? true)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: prepared.encodedBody) as? [String: Any]
    )
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.filter { $0["role"] as? String == "system" }.count, 1)
  }

  func testPreparedStreamingAndNonStreamingVariantsOnlyChangeExpectedFields() throws {
    let config = streamingSupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://example.com/v1",
        model: "model",
        requiresAPIKey: false
      ))
    let client = AIChatCompletionClient()
    let request = AIChatCompletionRequest(
      model: "model",
      messages: [AIChatMessage(role: "user", content: "hello")]
    )
    let streaming = try client.prepareRequest(
      request,
      config: config,
      purpose: .interactiveChat,
      mode: .streaming
    )
    let nonStreaming = try client.prepareRequest(
      request,
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    var streamingPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: streaming.encodedBody) as? [String: Any]
    )
    var nonStreamingPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: nonStreaming.encodedBody) as? [String: Any]
    )
    XCTAssertEqual(streamingPayload.removeValue(forKey: "stream") as? Bool, true)
    XCTAssertNotNil(streamingPayload.removeValue(forKey: "stream_options"))
    XCTAssertNil(nonStreamingPayload.removeValue(forKey: "stream"))
    XCTAssertNil(nonStreamingPayload.removeValue(forKey: "stream_options"))
    XCTAssertEqual(streamingPayload as NSDictionary, nonStreamingPayload as NSDictionary)
  }

  func testPreparedRequestRejectsConfigurationDriftWithoutTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"must not send"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      purpose: .utilityTask,
      mode: .nonStreaming
    )
    var drifted = config
    drifted.model = "different-model"
    await XCTAssertThrowsErrorAsync(
      try await client.completePrepared(prepared, config: drifted, apiKey: nil)
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .preparedRequestConfigurationMismatch
      )
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testPreparedRequestAuthorizationExpiryFailsClosedBeforeCompleteTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"must not send"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let expired = prepared.bindingAuthorizationDeadline(Date(timeIntervalSinceNow: -1))

    await XCTAssertThrowsErrorAsync(
      try await client.completePrepared(expired, config: config, apiKey: nil)
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .preparedRequestAuthorizationExpired
      )
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testPreparedRequestAuthorizationExpiryFailsClosedBeforeStreamTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: ["data: [DONE]", ""]
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = streamingSupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://example.com/v1",
        model: "model",
        requiresAPIKey: false
      ))
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      purpose: .interactiveChat,
      mode: .streaming
    )
    let expired = prepared.bindingAuthorizationDeadline(Date(timeIntervalSinceNow: -1))

    await XCTAssertThrowsErrorAsync(
      try await client.streamPrepared(expired, config: config, apiKey: nil)
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .preparedRequestAuthorizationExpired
      )
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testPreparedRequestAuthorizationDeadlineAllowsOneCurrentTransportAndRemainsOneShot()
    async throws
  {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"prepared"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let authorized = prepared.bindingAuthorizationDeadline(Date(timeIntervalSinceNow: 5))

    _ = try await client.completePrepared(authorized, config: config, apiKey: nil)
    await XCTAssertThrowsErrorAsync(
      try await client.completePrepared(authorized, config: config, apiKey: nil)
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .preparedRequestAlreadyConsumed)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testConsumedPreparedRequestCannotCrossAuthorizationExpiry() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"prepared"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let authorized = prepared.bindingAuthorizationDeadline(Date(timeIntervalSinceNow: 0.05))

    _ = try await client.completePrepared(authorized, config: config, apiKey: nil)
    try await Task.sleep(nanoseconds: 80_000_000)
    await XCTAssertThrowsErrorAsync(
      try await client.completePrepared(authorized, config: config, apiKey: nil)
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .preparedRequestAuthorizationExpired
      )
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testStreamDoesNotRetryAfterReceivingToolCallDelta() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"draft.read","arguments":"{"}}]}}]}"#,
            "",
          ],
          terminalError: .connectionLost
        ),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"duplicate","type":"function","function":{"name":"duplicate","arguments":"{}"}}]}}]}"#,
            "",
          ]
        ),
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
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://example.com/v1",
          model: "model",
          requiresAPIKey: false
        )),
      apiKey: nil,
      purpose: .connectionTest
    )

    var receivedDeltas: [AIToolCallDelta] = []
    do {
      for try await update in stream {
        receivedDeltas.append(contentsOf: update.toolCallDeltas)
      }
      XCTFail("Expected interrupted tool call stream")
    } catch let error as AIChatCompletionClientError {
      XCTAssertTrue(error.didReceivePartialContent)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(receivedDeltas.map(\.id), ["call_1"])
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testToolCallStreamPreservesCancellationError() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"draft.read","arguments":"{}"}}]}}]}"#,
        "",
      ],
      streamFinishesWithCancellation: true
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "model",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected: protocol parsing must not translate cancellation into retry.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testThrowsOnHTTPError() async {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"bad"}"#.utf8),
      statusCode: 401
    )
    let client = AIChatCompletionClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        ),
        apiKey: "bad"
      )
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .httpStatus(401, #"{"error":"bad"}"#, retryAfterSeconds: nil)
      )
    }
  }

  func testCompleteAppliesFirstByteTimeoutAndEnforcesResourceTimeout() async throws {
    let successTransport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"Done"}"#),
      statusCode: 200
    )
    let successClient = AIChatCompletionClient(
      transport: successTransport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 7,
        resourceTimeout: 20,
        maximumAutomaticRetryCount: 0
      )
    )
    _ = try await successClient.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )
      ),
      apiKey: "key",
      purpose: .interactiveChat
    )
    let capturedRequest = await successTransport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.timeoutInterval, 7, accuracy: 0.001)

    let delayedTransport = DelayedAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"late"}"#),
      statusCode: 200,
      delayNanoseconds: 200_000_000
    )
    let timeoutClient = AIChatCompletionClient(
      transport: delayedTransport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 0.02,
        resourceTimeout: 0.04,
        maximumAutomaticRetryCount: 0
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await timeoutClient.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        ),
        apiKey: "key"
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .resourceTimedOut(0.04))
    }
  }

  func testStreamTimesOutWaitingForFirstByte() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"late"}}]}"#, ""],
          lineDelayNanoseconds: 200_000_000
        )
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 0.03,
        resourceTimeout: 0.5,
        maximumAutomaticRetryCount: 0
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )),
      apiKey: "key",
      purpose: .connectionTest
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected first-byte timeout")
    } catch let error as AIChatCompletionClientError {
      guard case .streamInterruptedAfterPartialContent(let detail) = error else {
        XCTFail("Expected the accepted HTTP 2xx attempt to stop without replay, got \(error)")
        return
      }
      XCTAssertTrue(detail.contains("0.0 秒"))
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testInteractiveStreamDoesNotAutomaticallyRetryBeforeContentArrives() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(terminalError: .connectionLost),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"content":"recovered"},"finish_reason":"stop"}]}"#,
            "",
          ]
        ),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 1,
        automaticRetryBaseDelay: 0
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )),
      apiKey: "key"
    )

    await XCTAssertThrowsErrorAsync(
      try await consume(stream)
    ) { error in
      XCTAssertTrue(error is AIChatCompletionClientError)
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testStreamNeverAutomaticallyReplaysAfterPartialContent() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"partial"}}]}"#, ""],
          terminalError: .connectionLost
        ),
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"duplicate"}}]}"#, ""]
        ),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 3,
        automaticRetryBaseDelay: 0
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )),
      apiKey: "key",
      purpose: .connectionTest
    )

    var content = ""
    do {
      for try await update in stream {
        content += update.contentDelta
      }
      XCTFail("Expected interrupted partial stream")
    } catch let error as AIChatCompletionClientError {
      XCTAssertTrue(error.didReceivePartialContent)
      XCTAssertTrue(error.localizedDescription.contains("重复计费"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertEqual(content, "partial")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testRetryAfterHeaderIsPreservedForManualRetryPrompt() async {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"rate limited"}"#.utf8),
      statusCode: 429,
      headerFields: ["Retry-After": "12"]
    )
    let client = AIChatCompletionClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        ),
        apiKey: "key"
      )
    ) { error in
      guard case .httpStatus(429, _, let retryAfter) = error as? AIChatCompletionClientError else {
        XCTFail("Expected HTTP 429 recovery metadata")
        return
      }
      XCTAssertEqual(retryAfter, 12)
      XCTAssertTrue(error.localizedDescription.contains("等待 12 秒"))
    }
  }

  func testStreamDoesNotSilentlyWaitOrRetryLongRetryAfter() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          statusCode: 429,
          headerFields: ["Retry-After": "30"],
          lines: [#"{"error":"rate limited"}"#]
        ),
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"unexpected retry"}}]}"#, ""]
        ),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 3,
        automaticRetryBaseDelay: 0,
        maximumAutomaticRetryAfterDelay: 5
      )
    )
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )),
      apiKey: "key",
      purpose: .connectionTest
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected rate-limit recovery guidance")
    } catch let error as AIChatCompletionClientError {
      XCTAssertEqual(error.retryAfterSeconds, 30)
      XCTAssertTrue(error.localizedDescription.contains("等待 30 秒"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testRetryAfterParsesHTTPDate() {
    let now = Date(timeIntervalSince1970: 784_111_777)
    let parsedInterval = AIChatCompletionClient.retryAfterInterval(
      from: "Sun, 06 Nov 1994 08:49:47 GMT",
      now: now
    )
    XCTAssertEqual(parsedInterval ?? -1, 10, accuracy: 0.001)
  }

  func testHTTPErrorBodyIsBoundedAndRedactsAPIKey() async {
    let apiKey = "sk-super-secret-value-123456789"
    let responseBody =
      #"{"error":"Bearer \#(apiKey)","api_key":"\#(apiKey)","detail":""#
      + String(repeating: "x", count: 4_000)
      + #""}"#
    let transport = RecordingAIChatTransport(
      data: Data(responseBody.utf8),
      statusCode: 401
    )
    let client = AIChatCompletionClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        ),
        apiKey: apiKey
      )
    ) { error in
      guard case .httpStatus(401, let body, nil) = error as? AIChatCompletionClientError else {
        XCTFail("Expected sanitized HTTP error")
        return
      }
      XCTAssertFalse(body.contains(apiKey))
      XCTAssertTrue(body.contains("[REDACTED]"))
      XCTAssertTrue(body.contains("远端响应已截断"))
      XCTAssertLessThan(body.count, 2_100)
    }
  }

  func testStreamErrorPayloadIsBoundedAndRedactsAPIKey() async throws {
    let apiKey = "sk-stream-secret-value-123456789"
    let errorMessage = "Bearer \(apiKey) " + String(repeating: "x", count: 4_000)
    let payload = try JSONSerialization.data(
      withJSONObject: ["error": ["message": errorMessage]]
    )
    let line = try XCTUnwrap(String(data: payload, encoding: .utf8))
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: ["data: \(line)", ""]
    )
    let client = AIChatCompletionClient(transport: transport)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: streamingSupportedConfig(
        AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.openai.com/v1",
          model: "gpt-4.1-mini",
          requiresAPIKey: true
        )),
      apiKey: apiKey,
      purpose: .connectionTest
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected sanitized streaming error")
    } catch let error as AIChatCompletionClientError {
      guard case .streamInterruptedAfterPartialContent(let body) = error else {
        XCTFail("Expected streaming HTTP error, got \(error)")
        return
      }
      XCTAssertFalse(body.contains(apiKey))
      XCTAssertTrue(body.contains("[REDACTED]"))
      XCTAssertTrue(body.contains("远端响应已截断"))
      XCTAssertLessThan(body.count, 2_100)
    }
  }

  func testCompleteRejectsHTTPBeforeSendingAPIKey() async {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: config,
        apiKey: "must-not-be-sent"
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .insecureCredentialURL)
    }
    let capturedRequest = await transport.capturedRequest()
    XCTAssertNil(capturedRequest)
  }

  func testStreamRejectsHTTPBeforeSendingAPIKey() async {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.stream(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: config,
        apiKey: "must-not-be-sent"
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .insecureCredentialURL)
    }
    let capturedRequest = await transport.capturedRequest()
    XCTAssertNil(capturedRequest)
  }

  func testCompleteRejectsRemoteHTTPWithoutAPIKeyBeforeSendingBody() async {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "http://192.0.2.10:8080/v1",
      model: "model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(
          model: "model",
          messages: [AIChatMessage(role: "user", content: "private prompt")]
        ),
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .insecureCredentialURL)
    }
    let capturedRequest = await transport.capturedRequest()
    XCTAssertNil(capturedRequest)
  }

  func testStreamRejectsRemoteHTTPWithoutAPIKeyBeforeSendingBody() async {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "http://ai.internal.example/v1",
      model: "model",
      requiresAPIKey: false
    )

    await XCTAssertThrowsErrorAsync(
      try await client.stream(
        request: AIChatCompletionRequest(
          model: "model",
          messages: [AIChatMessage(role: "user", content: "private prompt")]
        ),
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .insecureCredentialURL)
    }
    let capturedRequest = await transport.capturedRequest()
    XCTAssertNil(capturedRequest)
  }

  func testStreamAllowsLoopbackHTTPWithoutAPIKey() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"local"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://localhost:11434/v1",
      model: "model",
      requiresAPIKey: false
    )

    let stream = try await client.stream(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: config,
      apiKey: nil
    )
    var content = ""
    for try await update in stream {
      content += update.contentDelta
    }

    XCTAssertEqual(content, "local")
    let capturedRequest = await transport.capturedRequest()
    XCTAssertEqual(capturedRequest?.url?.host, "localhost")
    XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
  }

  func testAIRequestPolicyUsesStrictLoopbackHostAllowlist() throws {
    let allowed = [
      "http://localhost:11434/v1/chat/completions",
      "http://127.0.0.1:11434/v1/chat/completions",
      "http://127.42.7.9:11434/v1/chat/completions",
      "http://[::1]:11434/v1/chat/completions",
    ]
    for value in allowed {
      XCTAssertTrue(
        CredentialedEndpointPolicy.isAllowedAIRequestURL(
          try XCTUnwrap(URL(string: value)), hasCredential: false),
        value
      )
    }

    let rejected = [
      "http://localhost.example:11434/v1/chat/completions",
      "http://127.example:11434/v1/chat/completions",
      "http://126.255.255.255:11434/v1/chat/completions",
      "http://[::2]:11434/v1/chat/completions",
      "http://user@localhost:11434/v1/chat/completions",
    ]
    for value in rejected {
      XCTAssertFalse(
        CredentialedEndpointPolicy.isAllowedAIRequestURL(
          try XCTUnwrap(URL(string: value)), hasCredential: false),
        value
      )
    }
  }

  private var protocolCapabilityEvidenceConfig: AIProviderConfig {
    var config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "protocol-model",
      requiresAPIKey: false
    )
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: config)
    config.capabilityProbeEvidence = [
      .toolCalling: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .toolCalling,
        outcome: .supported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
      .structuredOutput: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .structuredOutput,
        outcome: .supported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
    ]
    return config
  }

  private func streamingSupportedConfig(_ base: AIProviderConfig) -> AIProviderConfig {
    var config = base
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: config)
    var evidence = config.capabilityProbeEvidence ?? [:]
    evidence[.streamingResponse] = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .streamingResponse,
      outcome: .supported,
      observedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    config.capabilityProbeEvidence = evidence
    return config
  }

  private func responseData(content: String, usage: String? = nil) -> Data {
    let usageFragment = usage.map { #","usage":"# + $0 } ?? ""
    return Data(
      """
      {
        "model": "test-model",
        "choices": [
          {
            "message": \(content)
          }
        ]\(usageFragment)
      }
      """.utf8)
  }

  private func consume(_ stream: AsyncThrowingStream<AIChatStreamUpdate, Error>) async throws {
    for try await _ in stream {}
  }
}

actor CompatibilityFallbackAIChatTransport: AIChatStreamingTransport {
  private let streamingStatusCode: Int
  private let streamingErrorBody: String
  private let fallbackData: Data
  private var requests: [URLRequest] = []

  init(
    streamingStatusCode: Int,
    streamingErrorBody: String,
    fallbackData: Data
  ) {
    self.streamingStatusCode = streamingStatusCode
    self.streamingErrorBody = streamingErrorBody
    self.fallbackData = fallbackData
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (fallbackData, response)
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    requests.append(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: streamingStatusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    let errorBody = streamingErrorBody
    let stream = AsyncThrowingStream<String, Error> { continuation in
      continuation.yield(errorBody)
      continuation.finish()
    }
    return (stream, response)
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}
