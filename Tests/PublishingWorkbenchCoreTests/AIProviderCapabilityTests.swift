import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIProviderCapabilityTests: XCTestCase {
  func testCapabilityKeysAndOrderAreStable() {
    XCTAssertEqual(
      AIProviderCapability.allCases.map(\.rawValue),
      [
        "chat",
        "streaming_response",
        "vision_input",
        "reasoning_control",
        "local_service",
        "model_discovery",
      ]
    )
  }

  func testCapabilityAndSupportDisplayNamesAreLocalizationFriendly() {
    for capability in AIProviderCapability.allCases {
      XCTAssertFalse(capability.localizationKey.isEmpty)
      XCTAssertFalse(capability.displayName.isEmpty)
    }

    for support in AIProviderCapabilitySupport.allCases {
      XCTAssertFalse(support.localizationKey.isEmpty)
      XCTAssertFalse(support.displayName.isEmpty)
    }
  }

  func testEveryPresetDescribesEveryCapabilityExactlyOnce() {
    for preset in AIProviderPreset.allCases {
      let descriptors = preset.capabilityDescriptors

      XCTAssertEqual(descriptors.map(\.capability), AIProviderCapability.allCases)
      XCTAssertEqual(Set(descriptors.map(\.id)).count, AIProviderCapability.allCases.count)
      XCTAssertEqual(descriptors.map(\.key), AIProviderCapability.allCases.map(\.rawValue))
    }
  }

  func testCustomPresetDoesNotClaimVisionOrReasoningSupport() {
    XCTAssertEqual(
      AIProviderPreset.custom.capabilitySupport(for: .visionInput),
      .unknown
    )
    XCTAssertEqual(
      AIProviderPreset.custom.capabilitySupport(for: .reasoningControl),
      .unknown
    )
  }

  func testKnownPresetCapabilityBoundaries() {
    XCTAssertEqual(AIProviderPreset.deepSeek.capabilitySupport(for: .chat), .supported)
    XCTAssertEqual(
      AIProviderPreset.deepSeek.capabilitySupport(for: .streamingResponse),
      .supported
    )
    XCTAssertEqual(
      AIProviderPreset.deepSeek.capabilitySupport(for: .visionInput),
      .unsupported
    )
    XCTAssertEqual(
      AIProviderPreset.openAICompatible.capabilitySupport(for: .visionInput),
      .unknown
    )
    XCTAssertEqual(
      AIProviderPreset.deepSeek.capabilitySupport(for: .reasoningControl),
      .supported
    )
    XCTAssertEqual(
      AIProviderPreset.local.capabilitySupport(for: .localService),
      .supported
    )
    XCTAssertEqual(
      AIProviderPreset.local.capabilitySupport(for: .modelDiscovery),
      .supported
    )
  }

  func testCustomDeepSeekEndpointUsesKnownCapabilityBoundary() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-v4-flash",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.capabilitySupport(for: .visionInput), .unsupported)
    XCTAssertEqual(config.capabilitySupport(for: .reasoningControl), .supported)
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
