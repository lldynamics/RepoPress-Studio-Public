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

  func testMissingFineGrainedPolicyUsesOnlyMigrationSafeScopes() throws {
    let settings = try JSONDecoder().decode(
      AIProviderAdvancedSettings.self,
      from: Data(#"{"allowsApplicationTools":true}"#.utf8)
    )

    XCTAssertNil(settings.agentPermissionPolicy)
    XCTAssertEqual(
      settings.resolvedAgentPermissionPolicy.enabledScopes,
      [.localRead, .draftCreation]
    )
    XCTAssertFalse(
      settings.resolvedAgentPermissionPolicy.allows(
        .networkAccess,
        masterEnabled: settings.resolvedAllowsApplicationTools
      )
    )
    XCTAssertFalse(
      settings.resolvedAgentPermissionPolicy.allows(
        .contentModification,
        masterEnabled: settings.resolvedAllowsApplicationTools
      )
    )
    XCTAssertFalse(
      settings.resolvedAgentPermissionPolicy.allows(
        .repositoryWrite,
        masterEnabled: settings.resolvedAllowsApplicationTools
      )
    )
    XCTAssertFalse(
      settings.resolvedAgentPermissionPolicy.allows(
        .publishing,
        masterEnabled: settings.resolvedAllowsApplicationTools
      )
    )
  }

  func testMasterSwitchDisablesAllScopesWithoutDiscardingSelections() {
    let policy = AIAgentPermissionPolicy(
      enabledScopes: [.localRead, .draftCreation, .networkAccess, .publishing]
    )
    let enabled = AIProviderAdvancedSettings(
      allowsApplicationTools: true,
      agentPermissionPolicy: policy
    )
    let disabled = AIProviderAdvancedSettings(
      allowsApplicationTools: false,
      agentPermissionPolicy: policy
    )

    XCTAssertEqual(disabled.effectiveAgentPermissionPolicy.enabledScopes, [])
    XCTAssertEqual(
      enabled.effectiveAgentPermissionPolicy.enabledScopes,
      policy.enabledScopes
    )
  }

  func testPolicyRoundTripsUnknownScopesAndResetKeepsSafeBaseline() throws {
    let data = Data(
      #"{"enabledScopes":["localRead","networkAccess","futureScope"]}"#.utf8
    )
    let decoded = try JSONDecoder().decode(AIAgentPermissionPolicy.self, from: data)

    XCTAssertEqual(decoded.enabledScopes, [.localRead, .networkAccess])
    XCTAssertFalse(decoded.isDefault)

    var reset = decoded
    reset.reset()
    XCTAssertEqual(reset, .legacySafeDefault)
    XCTAssertTrue(reset.isDefault)

    let encoded = try JSONEncoder().encode(decoded)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(payload["enabledScopes"] as? [String], ["localRead", "networkAccess"])
  }

  func testExplicitMigrationSafePolicyDoesNotMakeAdvancedSettingsNonDefault() {
    let settings = AIProviderAdvancedSettings(
      agentPermissionPolicy: .legacySafeDefault
    )

    XCTAssertTrue(settings.isDefault)
  }

  func testExplicitAgentToolsSettingRoundTripsAndIsNotDefault() throws {
    let disabled = AIProviderAdvancedSettings(allowsApplicationTools: false)
    let data = try JSONEncoder().encode(disabled)
    let decoded = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: data)

    XCTAssertFalse(decoded.resolvedAllowsApplicationTools)
    XCTAssertFalse(decoded.isDefault)
  }

  func testConnectionOnlyProxyAndFallbackSettingsAreNotDefault() {
    let fallback = UUID()

    XCTAssertFalse(
      AIProviderAdvancedSettings(proxyURL: "http://127.0.0.1:7890").isDefault
    )
    XCTAssertFalse(
      AIProviderAdvancedSettings(fallbackProfileID: fallback).isDefault
    )
  }

  func testResettingSessionParametersPreservesConnectionSafetySettings() {
    let fallback = UUID()
    let original = AIProviderAdvancedSettings(
      systemPrompt: "session prompt",
      temperature: 0.4,
      reasoningPreference: .high,
      allowsApplicationTools: false,
      proxyURL: "socks5://127.0.0.1:1080",
      fallbackProfileID: fallback
    )

    // Mirrors the reset action in AIAdvancedSettingsSection: session-only
    // values are cleared while the connection-level safety choices survive.
    let reset = AIProviderAdvancedSettings(
      allowsApplicationTools: original.allowsApplicationTools,
      proxyURL: original.proxyURL,
      fallbackProfileID: original.fallbackProfileID
    )

    XCTAssertTrue(reset.normalizedSystemPrompt.isEmpty)
    XCTAssertNil(reset.temperature)
    XCTAssertEqual(reset.reasoningPreference, .automatic)
    XCTAssertEqual(reset.allowsApplicationTools, false)
    XCTAssertEqual(reset.proxyURL, original.proxyURL)
    XCTAssertEqual(reset.fallbackProfileID, fallback)
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

  func testReasoningEffortOverrideIsTrimmedAndBackwardCompatible() throws {
    let settings = AIProviderAdvancedSettings(reasoningEffortOverride: "  xhigh  ")
    XCTAssertEqual(settings.reasoningEffortOverride, "xhigh")
    XCTAssertEqual(settings.normalizedReasoningEffortOverride, "xhigh")
    XCTAssertFalse(settings.isDefault)

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: encoded)
    XCTAssertEqual(decoded.reasoningEffortOverride, "xhigh")

    let empty = try JSONDecoder().decode(
      AIProviderAdvancedSettings.self,
      from: Data(#"{"reasoningEffortOverride":"  "}"#.utf8)
    )
    XCTAssertNil(empty.reasoningEffortOverride)
    XCTAssertTrue(empty.isDefault)
  }

  func testCodexReasoningEffortOverrideEntersInteractiveNormalizedRequest() throws {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .codexAppServer,
      baseURL: AIProviderPreset.codexAppServer.defaultBaseURL,
      model: AIProviderPreset.codexDefaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(reasoningEffortOverride: " high ")
    )

    let normalized = try client.normalizedRequest(
      AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: config,
      purpose: .interactiveChat
    )

    XCTAssertEqual(normalized.reasoningEffort, "high")
  }

  func testExplicitSessionReasoningEffortWinsOverCodexPersistedOverride() throws {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .codexAppServer,
      baseURL: AIProviderPreset.codexAppServer.defaultBaseURL,
      model: AIProviderPreset.codexDefaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(reasoningEffortOverride: "high")
    )

    let normalized = try client.normalizedRequest(
      AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")],
        reasoningEffort: "low"
      ),
      config: config,
      purpose: .interactiveChat
    )

    XCTAssertEqual(normalized.reasoningEffort, "low")
  }

  func testCodexPersistedReasoningEffortIsInteractiveOnly() throws {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .codexAppServer,
      baseURL: AIProviderPreset.codexAppServer.defaultBaseURL,
      model: AIProviderPreset.codexDefaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(reasoningEffortOverride: "high")
    )

    let normalized = try client.normalizedRequest(
      AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Return JSON")]
      ),
      config: config,
      purpose: .utilityTask
    )

    XCTAssertNil(normalized.reasoningEffort)
  }

  func testCodexLegacyReasoningPreferenceDoesNotCompeteWithAccountEffort() throws {
    let client = AIChatCompletionClient()
    let config = AIProviderConfig(
      preset: .codexAppServer,
      baseURL: AIProviderPreset.codexAppServer.defaultBaseURL,
      model: AIProviderPreset.codexDefaultModel,
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(reasoningPreference: .high)
    )

    let normalized = try client.normalizedRequest(
      AIChatCompletionRequest(
        model: config.model,
        messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: config,
      purpose: .interactiveChat
    )

    XCTAssertNil(normalized.reasoningEffort)
    XCTAssertNil(normalized.thinking)
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
