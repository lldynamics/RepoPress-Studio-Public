import Foundation
import XCTest
@testable import PublishingAICore

final class AIProviderPresetMigrationTests: XCTestCase {
  func testLegacyDeepSeekProConfigDecodesAsDeepSeek() throws {
    let legacyData = Data(
      #"{"preset":"deepSeekPro","baseURL":"https://api.deepseek.com","model":"deepseek-v4-pro","requiresAPIKey":true}"#
        .utf8
    )

    let config = try JSONDecoder().decode(AIProviderConfig.self, from: legacyData)

    XCTAssertEqual(config.preset, .deepSeek)
    XCTAssertEqual(config.model, "deepseek-v4-pro")
    XCTAssertEqual(config.normalizedRequestModel, AIProviderPreset.deepSeekHighQualityModel)
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

  func testCodexPresetUsesManagedAccountWithoutTreatingLocalProcessAsLocalAI() {
    var config = AIProviderConfig(preset: .codexAppServer)

    config.applyPresetDefaults()

    XCTAssertTrue(config.usesCodexAppServer)
    XCTAssertFalse(config.requiresAPIKey)
    XCTAssertEqual(config.model, AIProviderPreset.codexDefaultModel)
    XCTAssertEqual(config.dataSharingDestination, "Codex / ChatGPT")
    XCTAssertFalse(config.isLocalEndpoint)
    XCTAssertEqual(config.dataSharingConsentIdentifier, "codexAppServer|chatgpt")
    XCTAssertNotNil(config.chatCompletionsURL)
  }

  func testConnectionTemplatesContainOneUnbrandedCustomCloudEndpoint() throws {
    XCTAssertEqual(AIConnectionProfile.templates.count, 4)
    XCTAssertFalse(AIConnectionProfile.templates.contains { $0.name.contains("RepoPress") })

    let codex = try XCTUnwrap(
      AIConnectionProfile.templates.first { $0.config.preset == .codexAppServer }
    )
    XCTAssertFalse(codex.config.requiresAPIKey)

    let custom = try XCTUnwrap(
      AIConnectionProfile.templates.first { $0.config.preset == .custom }
    )
    XCTAssertEqual(custom.config.baseURL, "")
    XCTAssertEqual(custom.config.model, "")
  }

}
