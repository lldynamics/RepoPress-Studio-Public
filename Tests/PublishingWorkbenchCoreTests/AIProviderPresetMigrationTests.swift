import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIProviderPresetMigrationTests: XCTestCase {
  func testLegacyDeepSeekProConfigDecodesAsDeepSeekWithoutChangingModel() throws {
    let legacyData = Data(
      #"{"preset":"deepSeekPro","baseURL":"https://api.deepseek.com","model":"deepseek-v4-pro","requiresAPIKey":true}"#.utf8
    )

    let config = try JSONDecoder().decode(AIProviderConfig.self, from: legacyData)

    XCTAssertEqual(config.preset, .deepSeek)
    XCTAssertEqual(config.model, AIProviderPreset.deepSeekHighQualityModel)
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

  func testDeepSeekHighQualityGradeUsesProModel() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIChatModelCatalog.model(
        for: .highQuality,
        config: config,
        currentModel: config.normalizedModel
      ),
      AIProviderPreset.deepSeekHighQualityModel
    )
  }
}
