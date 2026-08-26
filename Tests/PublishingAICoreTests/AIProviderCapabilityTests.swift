import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderCapabilityTests: XCTestCase {
  func testCustomDeepSeekEndpointUsesKnownCapabilityBoundary() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-v4-flash",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .visionInput), .unsupported)
    XCTAssertEqual(config.capabilitySupport(for: .reasoningControl), .supported)
    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .structuredOutput), .unknown)
  }

  func testCustomLocalEndpointDoesNotOverstateModelDependentCapabilities() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "http://127.0.0.1:8080/v1",
      model: "custom-local-model",
      requiresAPIKey: false
    )

    XCTAssertEqual(config.capabilitySupport(for: .localService), .supported)
    XCTAssertEqual(config.capabilitySupport(for: .visionInput), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .reasoningControl), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .modelDiscovery), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .structuredOutput), .unknown)
  }

  func testExplicitRemoteCustomEndpointIsNotDescribedAsLocal() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .localService), .unsupported)
    XCTAssertEqual(config.capabilitySupport(for: .visionInput), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .reasoningControl), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .structuredOutput), .unknown)
  }

  func testUnresolvedCustomEndpointKeepsLocalServiceSupportUnknown() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "not a URL",
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .localService), .unknown)
  }

  func testLocalPresetWithExplicitRemoteEndpointIsNotDescribedAsLocal() {
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "https://example.com/v1",
      model: "remote-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .localService), .unsupported)
    XCTAssertEqual(config.capabilitySupport(for: .modelDiscovery), .unsupported)
  }

  func testUnconfiguredConnectionDoesNotClaimChatReadiness() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "",
      model: "",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .chat), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .streamingResponse), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .unknown)
    XCTAssertEqual(config.capabilitySupport(for: .structuredOutput), .unknown)
  }

  func testConfiguredDeepSeekPresetCanClaimKnownToolCallingSupport() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .supported)
    XCTAssertEqual(config.capabilitySupport(for: .structuredOutput), .unknown)
  }

  func testConfiguredCodexPresetUsesAppServerForModelDiscovery() {
    let config = AIProviderConfig(
      preset: .codexAppServer,
      baseURL: AIProviderPreset.codexAppServer.defaultBaseURL,
      model: AIProviderPreset.codexDefaultModel,
      requiresAPIKey: false
    )

    XCTAssertEqual(config.capabilitySupport(for: .reasoningControl), .supported)
    XCTAssertEqual(config.capabilitySupport(for: .modelDiscovery), .supported)
  }

  func testCurrentProbeEvidenceOverridesUnknownAndExpiredEvidenceFailsClosed() {
    let configWithoutEvidence = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model",
      requiresAPIKey: false
    )
    let key = AIProviderCapabilityCacheKey(config: configWithoutEvidence)
    let now = Date(timeIntervalSince1970: 100)
    let currentEvidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .toolCalling,
      outcome: .supported,
      observedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    var configured = configWithoutEvidence
    configured.capabilityProbeEvidence = [.toolCalling: currentEvidence]

    XCTAssertEqual(configured.capabilitySupport(for: .toolCalling, at: now), .supported)
    XCTAssertEqual(
      configured.capabilityEvidenceState(for: .toolCalling, at: now),
      .probed
    )
    XCTAssertEqual(
      configured.protocolCapabilityDescriptor(for: .toolCalling, at: now).probeOutcome,
      .supported
    )

    let expiredEvidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .toolCalling,
      outcome: .supported,
      observedAt: now.addingTimeInterval(-120),
      expiresAt: now.addingTimeInterval(-60)
    )
    configured.capabilityProbeEvidence = [.toolCalling: expiredEvidence]
    XCTAssertEqual(configured.capabilitySupport(for: .toolCalling, at: now), .unknown)
    XCTAssertEqual(
      configured.capabilityEvidenceState(for: .toolCalling, at: now),
      .expired
    )
  }

  func testDeepSeekPresetDoesNotClaimToolCallingForUnknownModel() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: "third-party-model-name",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .toolCalling), .unknown)
  }

  func testCapabilityExtensionsDoNotChangeExistingConfigCodablePayload() throws {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let encoded = try encoder.encode(config)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    XCTAssertTrue(
      Set(["baseURL", "model", "preset", "requiresAPIKey"])
        .isSubset(of: Set(object.keys))
    )
    XCTAssertNil(object["capabilityDescriptors"])
    XCTAssertNil(object["capabilities"])
    XCTAssertEqual(try JSONDecoder().decode(AIProviderConfig.self, from: encoded), config)
  }
}
