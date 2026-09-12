import XCTest

@testable import PublishingAICore

final class AIProviderSetupGuideTests: XCTestCase {
  func testBundledCloudPresetsExposeOnlyHTTPSOfficialDestinations() {
    let presets: [AIProviderPreset] = [
      .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu,
      .openRouter,
    ]

    for preset in presets {
      let config = AIProviderConfig(
        preset: preset, baseURL: preset.defaultBaseURL, model: preset.defaultModel)
      let guide = assertNotNilValue(AIProviderSetupGuide.guide(for: config), "(preset)")
      XCTAssertEqual(guide.provider, preset)
      XCTAssertTrue(guide.accountURL.scheme == "https")
      XCTAssertTrue(guide.modelsURL.scheme == "https")
      XCTAssertEqual(guide.apiKeyURL?.scheme, "https")
    }
  }

  func testChangedPresetGatewayDoesNotExposePresetKeyPage() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://gateway.example.com/v1",
      model: "deepseek-v4-flash"
    )

    XCTAssertNil(AIProviderSetupGuide.guide(for: config))
  }

  func testCustomAndLocalConnectionsHaveNoCloudOnboardingGuide() {
    XCTAssertNil(
      AIProviderSetupGuide.guide(
        for: AIProviderConfig(
          preset: .custom, baseURL: "https://gateway.example.com/v1", model: "model")))
    XCTAssertNil(
      AIProviderSetupGuide.guide(
        for: AIProviderConfig(
          preset: .local, baseURL: AIProviderPreset.local.defaultBaseURL, model: "llama3.1",
          requiresAPIKey: false)))
  }

  private func assertNotNilValue<T>(_ value: T?, _ message: String) -> T {
    XCTAssertNotNil(value, message)
    return value!
  }
}
