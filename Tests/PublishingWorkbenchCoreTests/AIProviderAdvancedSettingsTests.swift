import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIProviderAdvancedSettingsTests: XCTestCase {
  func testLegacyConfigDecodesWithDefaultAdvancedSettings() throws {
    let data = Data(
      #"{"preset":"custom","baseURL":"","model":"","requiresAPIKey":true}"#.utf8
    )

    let config = try JSONDecoder().decode(AIProviderConfig.self, from: data)

    XCTAssertNil(config.advancedSettings)
    XCTAssertTrue(config.resolvedAdvancedSettings.isDefault)
    XCTAssertTrue(config.resolvedAdvancedSettings.resolvedAllowsApplicationTools)
  }

  func testMissingAgentToolsFieldKeepsLegacyEnabledBehaviour() throws {
    let data = Data(
      #"{"systemPrompt":"legacy","reasoningPreference":"automatic"}"#.utf8
    )

    let settings = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: data)

    XCTAssertNil(settings.allowsApplicationTools)
    XCTAssertTrue(settings.resolvedAllowsApplicationTools)
  }

  func testExplicitAgentToolsSettingRoundTripsAndIsNotDefault() throws {
    let disabled = AIProviderAdvancedSettings(allowsApplicationTools: false)
    let data = try JSONEncoder().encode(disabled)
    let decoded = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: data)

    XCTAssertFalse(decoded.resolvedAllowsApplicationTools)
    XCTAssertFalse(decoded.isDefault)
  }

  func testNewConnectionTemplatesDisableAgentToolsExplicitly() {
    let template = AIConnectionProfile.template(named: "New", preset: .custom)

    XCTAssertFalse(template.config.resolvedAdvancedSettings.resolvedAllowsApplicationTools)
    XCTAssertFalse(
      SiteProfile(name: "New Site")
        .aiProviderConfig.resolvedAdvancedSettings.resolvedAllowsApplicationTools
    )
  }

  func testAdvancedSettingsNormalizeUserControlledBounds() {
    let settings = AIProviderAdvancedSettings(
      systemPrompt: "  " + String(repeating: "a", count: 8_100) + "  ",
      temperature: 4,
      maximumOutputTokens: 999_999,
      reasoningPreference: .high
    )

    XCTAssertEqual(
      settings.normalizedSystemPrompt.count,
      AIProviderAdvancedSettings.maximumSystemPromptLength
    )
    XCTAssertEqual(settings.normalizedTemperature, 2)
    XCTAssertEqual(
      settings.normalizedMaximumOutputTokens,
      AIProviderAdvancedSettings.maximumOutputTokenLimit
    )
    XCTAssertFalse(settings.isDefault)
  }

  func testInteractiveChatAppliesAdvancedOverridesAndStripsUnknownReasoning() async throws {
    let transport = RecordingAIChatTransport(
      data: successfulResponseData,
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "test-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        systemPrompt: "Use concise answers.",
        temperature: 0.7,
        maximumOutputTokens: 1_234,
        reasoningPreference: .medium
      )
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.model,
        messages: [
          AIChatMessage(role: "system", content: "Base prompt."),
          AIChatMessage(role: "user", content: "Hello"),
        ],
        temperature: 0.2
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["temperature"] as? Double, 0.7)
    XCTAssertEqual(payload["max_tokens"] as? Int, 1_234)
    // A custom endpoint has no static reasoning contract. Advanced reasoning
    // preferences must therefore be stripped until a concrete probe proves
    // support, even though temperature and max_tokens remain valid overrides.
    XCTAssertNil(payload["reasoning_effort"])
    XCTAssertNil(payload["thinking"])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["content"] as? String, "Base prompt.\n\nUse concise answers.")
  }

  func testTrustedDeepSeekPresetSendsAdvancedReasoningOverride() async throws {
    let transport = RecordingAIChatTransport(
      data: successfulResponseData,
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        maximumOutputTokens: 1_234,
        reasoningPreference: .medium
      )
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, AIProviderPreset.deepSeek.defaultModel)
    XCTAssertNil(payload["temperature"])
    XCTAssertEqual(payload["max_tokens"] as? Int, 1_234)
    let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "enabled")
    XCTAssertEqual(payload["reasoning_effort"] as? String, "medium")
  }

  func testUtilityTaskKeepsInternalRequestOptions() async throws {
    let transport = RecordingAIChatTransport(
      data: successfulResponseData,
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "test-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        systemPrompt: "Do not affect structured tasks.",
        temperature: 1.5,
        maximumOutputTokens: 64,
        reasoningPreference: .high
      )
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "system", content: "Return JSON.")],
        temperature: 0.1
      ),
      config: config,
      apiKey: nil,
      purpose: .utilityTask
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["temperature"] as? Double, 0.1)
    XCTAssertNil(payload["max_tokens"])
    XCTAssertNil(payload["reasoning_effort"])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["content"] as? String, "Return JSON.")
  }

  func testDeepSeekRemovesUnsupportedAdvancedTemperatureAndKeepsConversationReasoning() async throws
  {
    let transport = RecordingAIChatTransport(
      data: successfulResponseData,
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        temperature: 0.9,
        reasoningPreference: .high
      )
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")],
        temperature: 0.2,
        thinking: AIProviderThinkingOption(type: "disabled")
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(payload["temperature"])
    XCTAssertNil(payload["reasoning_effort"])
    let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "disabled")
  }

  func testProviderWithoutReasoningSupportDoesNotSendPersistedFallback() async throws {
    let transport = RecordingAIChatTransport(
      data: successfulResponseData,
      statusCode: 200
    )
    let client = AIChatCompletionClient(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://example.com/v1",
      model: "text-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(reasoningPreference: .high)
    )

    _ = try await client.complete(
      request: AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")],
        thinking: AIProviderThinkingOption(type: "enabled"),
        reasoningEffort: "high"
      ),
      config: config,
      apiKey: nil,
      purpose: .interactiveChat
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(payload["thinking"])
    XCTAssertNil(payload["reasoning_effort"])
  }

  private var successfulResponseData: Data {
    Data(
      #"{"model":"test-model","choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8
    )
  }
}
