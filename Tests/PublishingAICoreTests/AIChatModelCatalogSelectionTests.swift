import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatModelCatalogSelectionTests: XCTestCase {
  func testTaskGradesPreserveExplicitModelsAcrossProviderPresets() {
    for preset in AIProviderPreset.allCases {
      let config = AIProviderConfig(
        preset: preset,
        baseURL: preset.defaultBaseURL,
        model: "  user-selected-model  "
      )
      for task in AIModelTaskKind.allCases {
        let resolved = AIChatModelCatalog.config(for: task, baseConfig: config)
        XCTAssertEqual(resolved.normalizedModel, "user-selected-model", "\(preset) / \(task)")
        XCTAssertEqual(resolved.baseURL, config.baseURL)
      }
    }
  }

  func testCustomGatewaysDoNotReceiveInventedProviderModelNames() {
    for preset in AIProviderPreset.allCases where !preset.defaultModel.isEmpty {
      let config = AIProviderConfig(
        preset: preset,
        baseURL: "https://gateway.example.com/v1",
        model: preset.defaultModel
      )
      for task in [AIModelTaskKind.prePublishReview, .batchMetadataRepair] {
        XCTAssertEqual(
          AIChatModelCatalog.config(for: task, baseConfig: config).normalizedModel,
          preset.defaultModel,
          "\(preset) / \(task)"
        )
      }
    }
  }

  func testBundledDeepSeekGradesAndLegacyAliasesRemainAvailable() {
    for selectedModel in [AIProviderPreset.deepSeek.defaultModel, "deepseek-chat"] {
      let config = AIProviderConfig(
        preset: .deepSeek, baseURL: "https://API.DEEPSEEK.COM:443/", model: selectedModel
      )
      XCTAssertEqual(
        AIChatModelCatalog.config(for: .prePublishReview, baseConfig: config).normalizedModel,
        AIProviderPreset.deepSeekHighQualityModel
      )
      XCTAssertEqual(
        AIChatModelCatalog.config(for: .batchMetadataRepair, baseConfig: config).normalizedModel,
        AIProviderPreset.deepSeek.defaultModel
      )
    }
  }

  func testDifferentPathOnProviderHostPreservesConfiguredModel() {
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/other-proxy/v1",
      model: AIProviderPreset.openAICompatible.defaultModel
    )
    XCTAssertEqual(
      AIChatModelCatalog.config(for: .prePublishReview, baseConfig: config).normalizedModel,
      config.normalizedModel
    )
  }

  func testGeminiDefaultsAndTaskCandidatesDoNotSelectRetiredModels() {
    var config = AIProviderConfig(preset: .gemini)
    config.applyPresetDefaults()
    XCTAssertEqual(config.normalizedModel, "gemini-3.6-flash")
    let candidates = AIChatModelCatalog.modelCandidates(activeModel: config.model, config: config)
    XCTAssertFalse(candidates.contains("gemini-1.5-pro"))
    XCTAssertFalse(candidates.contains("gemini-2.0-flash"))
    for task in AIModelTaskKind.allCases {
      XCTAssertEqual(
        AIChatModelCatalog.config(for: task, baseConfig: config).normalizedModel,
        config.normalizedModel
      )
    }
  }

  func testCustomGradeRemainsAnExplicitOverride() {
    var config = AIProviderConfig(preset: .gemini)
    config.applyPresetDefaults()
    XCTAssertEqual(
      AIChatModelCatalog.model(for: .custom, config: config, currentModel: " selected-model "),
      "selected-model"
    )
  }
}
