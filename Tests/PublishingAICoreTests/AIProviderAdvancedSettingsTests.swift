import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderAdvancedSettingsTests: XCTestCase {
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
