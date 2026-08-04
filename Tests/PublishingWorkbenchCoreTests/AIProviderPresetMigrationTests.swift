import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIProviderPresetMigrationTests: XCTestCase {
  func testLegacyDeepSeekProConfigDecodesAsDeepSeek() throws {
    let legacyData = Data(
      #"{"preset":"deepSeekPro","baseURL":"https://api.deepseek.com","model":"deepseek-v4-pro","requiresAPIKey":true}"#.utf8
    )

    let config = try JSONDecoder().decode(AIProviderConfig.self, from: legacyData)

    XCTAssertEqual(config.preset, .deepSeek)
    XCTAssertEqual(config.model, "deepseek-v4-pro")
    XCTAssertEqual(config.normalizedRequestModel, AIProviderPreset.deepSeekHighQualityModel)
  }

  func testMigratedDeepSeekConfigEncodesWithCanonicalPreset() throws {
    let legacyPreset = try JSONDecoder().decode(
      AIProviderPreset.self,
      from: Data(#""deepSeekPro""#.utf8)
    )

    let encodedPreset = try JSONEncoder().encode(legacyPreset)

    XCTAssertEqual(legacyPreset, .deepSeek)
    XCTAssertEqual(String(decoding: encodedPreset, as: UTF8.self), #""deepSeek""#)
    XCTAssertEqual(AIProviderPreset.allCases.filter { $0 == .deepSeek }.count, 1)
  }

  func testCustomPresetPreservesConfiguredModelForHighQualityGrade() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIChatModelCatalog.model(
        for: .highQuality,
        config: config,
        currentModel: config.normalizedModel
      ),
      "custom-model"
    )
  }

  func testNewConfigurationIsCustomAndKeepsEndpointAndModelBlank() {
    let config = AIProviderConfig()

    XCTAssertEqual(config.preset, .custom)
    XCTAssertEqual(config.baseURL, "")
    XCTAssertEqual(config.model, "")
    XCTAssertEqual(config.normalizedBaseURL, "")
    XCTAssertEqual(config.normalizedModel, "")
    XCTAssertEqual(config.normalizedRequestModel, "")
    XCTAssertEqual(config.dataSharingDestination, "")
    XCTAssertNil(config.chatCompletionsURL)
  }

  func testPresetInitializerDoesNotImplicitlyApplyEndpointOrModelDefaults() {
    let config = AIProviderConfig(preset: .deepSeek)

    XCTAssertEqual(config.baseURL, "")
    XCTAssertEqual(config.model, "")
    XCTAssertEqual(config.normalizedBaseURL, "")
    XCTAssertEqual(config.normalizedModel, "")
    XCTAssertEqual(
      AIChatModelCatalog.model(for: .standard, config: config, currentModel: ""),
      ""
    )
    XCTAssertEqual(AIChatModelCatalog.modelCandidates(activeModel: "", config: config), [])
  }

  func testExplicitPresetDefaultsPopulateFieldsAndClearedValuesStayBlank() {
    var config = AIProviderConfig(preset: .deepSeek)

    config.applyPresetDefaults()

    XCTAssertEqual(config.baseURL, AIProviderPreset.deepSeek.defaultBaseURL)
    XCTAssertEqual(config.model, AIProviderPreset.deepSeek.defaultModel)

    config.baseURL = "  "
    config.model = "\n"

    XCTAssertEqual(config.normalizedBaseURL, "")
    XCTAssertEqual(config.normalizedModel, "")
    XCTAssertEqual(config.dataSharingDestination, "")
    XCTAssertNil(config.chatCompletionsURL)
    XCTAssertEqual(
      AIChatModelCatalog.model(for: .highQuality, config: config, currentModel: ""),
      ""
    )
  }

  func testLocalPresetDefaultsAreAppliedOnlyByExplicitAction() {
    var config = AIProviderConfig(preset: .local)

    XCTAssertEqual(config.baseURL, "")
    XCTAssertEqual(config.model, "")

    config.applyPresetDefaults()

    XCTAssertEqual(config.baseURL, AIProviderPreset.local.defaultBaseURL)
    XCTAssertEqual(config.model, AIProviderPreset.local.defaultModel)
    XCTAssertEqual(config.normalizedModel, AIProviderPreset.local.defaultModel)
    XCTAssertEqual(config.normalizedRequestModel, AIProviderPreset.local.defaultModel)
  }

  func testConnectionTemplatesContainOneUnbrandedCustomCloudEndpoint() throws {
    XCTAssertEqual(AIConnectionProfile.templates.count, 3)
    XCTAssertFalse(AIConnectionProfile.templates.contains { $0.name.contains("RepoPress") })

    let custom = try XCTUnwrap(
      AIConnectionProfile.templates.first { $0.config.preset == .custom }
    )
    XCTAssertEqual(custom.config.baseURL, "")
    XCTAssertEqual(custom.config.model, "")
  }

  func testOpenAICompatibleEndpointNameIsLocalizedForChineseAndEnglish() {
    XCTAssertEqual(
      CoreL10n.text("OpenAI 兼容", locale: Locale(identifier: "zh-Hans")),
      "开放AI兼容接口"
    )
    XCTAssertEqual(
      CoreL10n.text("OpenAI 兼容", locale: Locale(identifier: "en")),
      "OpenAI-compatible endpoint"
    )
    XCTAssertEqual(
      CoreL10n.text("自定义云端接口", locale: Locale(identifier: "en")),
      "Custom cloud endpoint"
    )
  }
}
