import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderCapabilityProbeAdapterTests: XCTestCase {
  func testCapabilityCacheKeyAdapterUsesSanitizedConfigIdentityNormalizedModelAndSchema() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "HTTPS://User:secret@Example.COM:443/v1/?api_key=do-not-cache#fragment",
      model: " model ",
      requiresAPIKey: true
    )

    let defaultKey = AIProviderCapabilityCacheKey(config: config)
    XCTAssertEqual(defaultKey.preset, .custom)
    XCTAssertEqual(defaultKey.endpointIdentity, "https://example.com:443/v1")
    XCTAssertEqual(defaultKey.model, "model")
    XCTAssertEqual(
      defaultKey.probeSchemaVersion,
      AIProviderCapabilityCacheKey.currentProbeSchemaVersion
    )
    XCTAssertFalse(defaultKey.endpointIdentity.contains("secret"))
    XCTAssertFalse(defaultKey.endpointIdentity.contains("api_key"))
    XCTAssertFalse(defaultKey.endpointIdentity.contains("?"))
    XCTAssertFalse(defaultKey.endpointIdentity.contains("#"))

    let versionedKey = AIProviderCapabilityCacheKey(config: config, probeSchemaVersion: 2)
    XCTAssertEqual(versionedKey.preset, defaultKey.preset)
    XCTAssertEqual(versionedKey.endpointIdentity, defaultKey.endpointIdentity)
    XCTAssertEqual(versionedKey.model, defaultKey.model)
    XCTAssertEqual(versionedKey.probeSchemaVersion, 2)
    XCTAssertNotEqual(versionedKey, defaultKey)
  }

  func
    testProbeReportAdapterAppliesCurrentEvidenceOnlyForMatchingConfigAndPreservesExistingEvidence()
  {
    var config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model-a",
      requiresAPIKey: false
    )
    let key = AIProviderCapabilityCacheKey(config: config)
    let now = Date(timeIntervalSince1970: 100)
    let existingEvidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .structuredOutput,
      outcome: .unsupported,
      observedAt: Date(timeIntervalSince1970: 80),
      expiresAt: Date(timeIntervalSince1970: 160)
    )
    config.capabilityProbeEvidence = [.structuredOutput: existingEvidence]

    let currentEvidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .toolCalling,
      outcome: .supported,
      observedAt: Date(timeIntervalSince1970: 90),
      expiresAt: Date(timeIntervalSince1970: 160)
    )
    let expiredEvidence = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .visionInput,
      outcome: .unsupported,
      observedAt: Date(timeIntervalSince1970: 20),
      expiresAt: Date(timeIntervalSince1970: 90)
    )
    let report = AIProviderCapabilityProbeReport(
      key: key,
      results: [
        .toolCalling: AIProviderCapabilityProbeResult(
          capability: .toolCalling,
          outcome: .supported,
          evidence: currentEvidence
        ),
        .visionInput: AIProviderCapabilityProbeResult(
          capability: .visionInput,
          outcome: .unsupported,
          evidence: expiredEvidence
        ),
      ],
      cacheState: .miss,
      generatedAt: now
    )

    var mismatchedConfig = config
    mismatchedConfig.model = "model-b"
    XCTAssertEqual(report.applying(to: mismatchedConfig, at: now), mismatchedConfig)

    let updated = report.applying(to: config, at: now)
    XCTAssertEqual(updated.capabilityProbeEvidence?[.toolCalling], currentEvidence)
    XCTAssertNil(updated.capabilityProbeEvidence?[.visionInput])
    XCTAssertEqual(updated.capabilityProbeEvidence?[.structuredOutput], existingEvidence)
  }
}
