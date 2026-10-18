import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderAdvancedSettingsTests: XCTestCase {
  func testRetiredAgentToolFieldsAreIgnoredAndDroppedOnSave() throws {
    let data = Data(
      #"{"systemPrompt":"legacy","allowsApplicationTools":false,"agentPermissionPolicy":{"enabledScopes":["localRead"]}}"#
        .utf8
    )

    let settings = try JSONDecoder().decode(AIProviderAdvancedSettings.self, from: data)
    let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)

    XCTAssertEqual(settings.normalizedSystemPrompt, "legacy")
    XCTAssertFalse(encoded.contains("allowsApplicationTools"))
    XCTAssertFalse(encoded.contains("agentPermissionPolicy"))
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
      proxyURL: "socks5://127.0.0.1:1080",
      fallbackProfileID: fallback
    )

    // Mirrors the reset action in AIAdvancedSettingsSection: session-only
    // values are cleared while the connection-level choices survive.
    let reset = AIProviderAdvancedSettings(
      proxyURL: original.proxyURL,
      fallbackProfileID: original.fallbackProfileID
    )

    XCTAssertTrue(reset.normalizedSystemPrompt.isEmpty)
    XCTAssertNil(reset.temperature)
    XCTAssertEqual(reset.reasoningPreference, .automatic)
    XCTAssertEqual(reset.proxyURL, original.proxyURL)
    XCTAssertEqual(reset.fallbackProfileID, fallback)
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
}
