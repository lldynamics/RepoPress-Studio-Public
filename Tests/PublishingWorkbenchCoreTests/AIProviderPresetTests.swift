import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIProviderPresetTests: XCTestCase {
  func testNewPresetsHaveCorrectDefaults() {
    let presets: [AIProviderPreset] = [
      .anthropic,
      .gemini,
      .siliconFlow,
      .moonshot,
      .zhipu,
    ]

    for preset in presets {
      var config = AIProviderConfig(preset: preset)
      config.applyPresetDefaults()

      XCTAssertFalse(config.baseURL.isEmpty, "Preset \(preset) should have a default baseURL")
      XCTAssertFalse(config.model.isEmpty, "Preset \(preset) should have a default model")
      XCTAssertTrue(config.requiresAPIKey, "Preset \(preset) should require API key")
      XCTAssertNotNil(
        config.chatCompletionsURL, "Preset \(preset) should produce a valid chat completions URL")
    }
  }

  func testAnthropicAPIIdentification() {
    let anthropicConfig = AIProviderConfig(
      preset: .anthropic,
      baseURL: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-6",
      requiresAPIKey: true
    )
    XCTAssertTrue(anthropicConfig.usesAnthropicAPI)
    XCTAssertFalse(anthropicConfig.usesDeepSeekAPI)

    let customAnthropicConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-6",
      requiresAPIKey: true
    )
    XCTAssertTrue(customAnthropicConfig.usesAnthropicAPI)
  }

  func testAnthropicPresetUsesActiveBaselineAndConservativeCompatibilityCapabilities() {
    XCTAssertEqual(AIProviderPreset.anthropic.defaultModel, "claude-sonnet-4-6")
    XCTAssertEqual(
      AIProviderPreset.anthropic.capabilitySupport(for: .reasoningControl),
      .unknown
    )
    XCTAssertEqual(
      AIProviderPreset.anthropic.capabilitySupport(for: .structuredOutput),
      .unknown
    )
  }

  func testModelDiscoveryServiceParsesOpenAIFormat() throws {
    let service = AIModelDiscoveryService()
    let json = """
      {
        "data": [
          {"id": "deepseek-ai/DeepSeek-V3"},
          {"id": "deepseek-ai/DeepSeek-R1"},
          {"id": "gpt-4o"}
        ]
      }
      """
    let data = Data(json.utf8)
    let models = service.parseModels(from: data)

    XCTAssertEqual(models.count, 3)
    let r1 = models.first { $0.id.contains("R1") }
    XCTAssertNotNil(r1)
    XCTAssertTrue(r1?.isReasoning == true)
  }

  func testModelDiscoveryServiceParsesOllamaFormat() throws {
    let service = AIModelDiscoveryService()
    let json = """
      {
        "models": [
          {"name": "llama3.2:latest"},
          {"name": "deepseek-r1:8b"}
        ]
      }
      """
    let data = Data(json.utf8)
    let models = service.parseModels(from: data)

    XCTAssertEqual(models.count, 2)
    let r1 = models.first { $0.id.contains("deepseek-r1") }
    XCTAssertNotNil(r1)
    XCTAssertTrue(r1?.isReasoning == true)
  }

  func testAdvancedSettingsProxySerialization() throws {
    let settings = AIProviderAdvancedSettings(
      systemPrompt: "You are a helpful writing assistant.",
      temperature: 0.8,
      maximumOutputTokens: 2048,
      proxyURL: "http://127.0.0.1:7890"
    )

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: encoded)

    XCTAssertEqual(decoded.proxyURL, "http://127.0.0.1:7890")
    XCTAssertEqual(decoded.temperature, 0.8)
    XCTAssertEqual(decoded.maximumOutputTokens, 2048)
  }

  func testWritingStylePresetsHaveNonEmptyDefaults() {
    for preset in AIWritingStylePreset.allCases where preset != .custom {
      var config = AIWritingStyleConfig(preset: preset)
      XCTAssertFalse(config.tone.isEmpty, "Preset \(preset) should have a default tone")
      XCTAssertFalse(config.audience.isEmpty, "Preset \(preset) should have a default audience")
      XCTAssertFalse(
        config.summaryGuidance.isEmpty, "Preset \(preset) should have summary guidance")
      XCTAssertFalse(config.tagGuidance.isEmpty, "Preset \(preset) should have tag guidance")
      XCTAssertFalse(config.seoGuidance.isEmpty, "Preset \(preset) should have SEO guidance")
    }
  }
}
