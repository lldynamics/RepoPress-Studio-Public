import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderPresetModelsTests: XCTestCase {
  func testProviderCategoriesPreserveRawValuesOrderIdentityAndDisplayNames() {
    XCTAssertEqual(
      AIProviderCategory.allCases.map(\.rawValue),
      ["chatGPTAccount", "apiService"]
    )

    for category in AIProviderCategory.allCases {
      XCTAssertEqual(category.id, category.rawValue)
      XCTAssertFalse(category.displayName.isEmpty)
    }
  }

  func testProviderPresetsPreserveCaseOrderIdentityCategoriesAndProtocolRouting() {
    let expectedPresets: [AIProviderPreset] = [
      .codexAppServer,
      .openAICompatible,
      .deepSeek,
      .anthropic,
      .gemini,
      .siliconFlow,
      .moonshot,
      .zhipu,
      .openRouter,
      .local,
      .custom,
    ]
    let expectedRawValues = [
      "codexAppServer",
      "openAICompatible",
      "deepSeek",
      "anthropic",
      "gemini",
      "siliconFlow",
      "moonshot",
      "zhipu",
      "openRouter",
      "local",
      "custom",
    ]

    XCTAssertEqual(AIProviderPreset.allCases, expectedPresets)
    XCTAssertEqual(AIProviderPreset.allCases.map(\.rawValue), expectedRawValues)

    for preset in AIProviderPreset.allCases {
      XCTAssertEqual(preset.id, preset.rawValue)
      if preset == .codexAppServer {
        XCTAssertEqual(preset.category, .chatGPTAccount)
        XCTAssertFalse(preset.usesOpenAICompatibleProtocol)
      } else {
        XCTAssertEqual(preset.category, .apiService)
        XCTAssertTrue(preset.usesOpenAICompatibleProtocol)
      }
    }

    XCTAssertEqual(AIProviderPreset.deepSeekHighQualityModel, "deepseek-v4-pro")
    XCTAssertEqual(AIProviderPreset.codexDefaultModel, "codex-default")
  }

  func testProviderPresetDefaultsAndDisplayNamesRemainStable() {
    let expectations: [(
      preset: AIProviderPreset,
      baseURL: String,
      model: String
    )] = [
      (
        .codexAppServer,
        "http://127.0.0.1/__repopress_codex_app_server__",
        "codex-default"
      ),
      (.openAICompatible, "https://api.openai.com/v1", "gpt-4.1-mini"),
      (.deepSeek, "https://api.deepseek.com", "deepseek-v4-flash"),
      (.anthropic, "https://api.anthropic.com/v1", "claude-sonnet-4-6"),
      (
        .gemini,
        "https://generativelanguage.googleapis.com/v1beta/openai",
        "gemini-2.0-flash"
      ),
      (
        .siliconFlow,
        "https://api.siliconflow.cn/v1",
        "deepseek-ai/DeepSeek-V3"
      ),
      (.moonshot, "https://api.moonshot.cn/v1", "moonshot-v1-auto"),
      (.zhipu, "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash"),
      (.openRouter, "https://openrouter.ai/api/v1", ""),
      (.local, "http://127.0.0.1:11434/v1", "llama3.1"),
      (.custom, "", ""),
    ]

    for expectation in expectations {
      XCTAssertEqual(expectation.preset.defaultBaseURL, expectation.baseURL)
      XCTAssertEqual(expectation.preset.defaultModel, expectation.model)
      XCTAssertFalse(expectation.preset.displayName.isEmpty)
    }
  }

  func testProviderPresetCodablePreservesCanonicalValuesAndMigratesLegacyAndUnknownValues()
    throws
  {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for preset in AIProviderPreset.allCases {
      let encoded = try encoder.encode(preset)
      XCTAssertEqual(
        String(decoding: encoded, as: UTF8.self),
        "\"\(preset.rawValue)\""
      )
      XCTAssertEqual(try decoder.decode(AIProviderPreset.self, from: encoded), preset)
    }

    let legacy = try decoder.decode(
      AIProviderPreset.self,
      from: Data(#""deepSeekPro""#.utf8)
    )
    XCTAssertEqual(legacy, .deepSeek)
    XCTAssertEqual(
      String(decoding: try encoder.encode(legacy), as: UTF8.self),
      #""deepSeek""#
    )

    let unknown = try decoder.decode(
      AIProviderPreset.self,
      from: Data(#""futureProvider""#.utf8)
    )
    XCTAssertEqual(unknown, .custom)
    XCTAssertEqual(
      String(decoding: try encoder.encode(unknown), as: UTF8.self),
      #""custom""#
    )
  }
}
