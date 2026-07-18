import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIChatCompletionClientTests: XCTestCase {
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

  func testDecodesStringArrayContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":["A","B"]}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "A\nB")
  }

  func testDecodesTextPartContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":[{"type":"text","text":"First"},{"type":"text","text":"Second"}]}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
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
      config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.rawModel, "test-model")
    XCTAssertEqual(
      result.tokenUsage,
      AIChatTokenUsage(promptTokens: 12, completionTokens: 5, totalTokens: 17)
    )
    XCTAssertEqual(result.tokenUsage?.displayText, "17 tokens · 输入 12 · 输出 5")
  }

  func testDecodesReasoningContentWhenFinalContentIsNull() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":null,"reasoning_content":"先给一个简短回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "先给一个简短回复。")
  }

  func testPrefersFinalContentOverReasoningContent() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","reasoning_content":"这是思考过程。","content":"这是最终回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)

    let result = try await client.complete(
      request: AIChatCompletionRequest(model: "model", messages: []),
      config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "model", requiresAPIKey: false),
      apiKey: nil
    )

    XCTAssertEqual(result.content, "这是最终回复。")
  }

  func testDeepSeekInteractiveChatUsesThinkingAndMapsLegacyModel() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"已按 DeepSeek 接口回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://api.deepseek.com",
      model: "deepseek-reasoner",
      requiresAPIKey: false
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
    XCTAssertEqual(payload["model"] as? String, "deepseek-v4-pro")
    XCTAssertNil(payload["temperature"])
    XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
    let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "enabled")
  }

  func testExplicitQuickReasoningOverridesDeepSeekInteractiveDefaults() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"快速回复。"}"#),
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://api.deepseek.com",
      model: AIProviderPreset.deepSeek.defaultModel,
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
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )

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
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [AIChatMessage(role: "user", content: "打个招呼。")],
        temperature: 0.4
      ),
      config: config,
      apiKey: nil
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

  func testThrowsOnHTTPError() async {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"bad"}"#.utf8),
      statusCode: 401
    )
    let client = AIChatCompletionClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(
        request: AIChatCompletionRequest(model: "model", messages: []),
        config: AIProviderConfig(),
        apiKey: "bad"
      )
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .httpStatus(401, #"{"error":"bad"}"#))
    }
  }

  func testHTTPErrorBodyIsBoundedAndRedactsAPIKey() async {
    let apiKey = "sk-super-secret-value-123456789"
    let responseBody = #"{"error":"Bearer \#(apiKey)","api_key":"\#(apiKey)","detail":""#
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
        config: AIProviderConfig(),
        apiKey: apiKey
      )
    ) { error in
      guard case .httpStatus(401, let body) = error as? AIChatCompletionClientError else {
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
      config: AIProviderConfig(),
      apiKey: apiKey
    )

    do {
      for try await _ in stream {}
      XCTFail("Expected sanitized streaming error")
    } catch let error as AIChatCompletionClientError {
      guard case .httpStatus(200, let body) = error else {
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
      preset: .openAICompatible,
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
      preset: .openAICompatible,
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
        CredentialedEndpointPolicy.isAllowedAIRequestURL(try XCTUnwrap(URL(string: value)), hasCredential: false),
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
        CredentialedEndpointPolicy.isAllowedAIRequestURL(try XCTUnwrap(URL(string: value)), hasCredential: false),
        value
      )
    }
  }

  private func responseData(content: String, usage: String? = nil) -> Data {
    let usageFragment = usage.map { #","usage":"# + $0 } ?? ""
    return Data("""
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
}
