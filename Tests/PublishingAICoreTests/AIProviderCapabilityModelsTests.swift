import Foundation
import XCTest

@testable import PublishingAICore

final class AIProviderCapabilityModelsTests: XCTestCase {
  func testCapabilityRawValuesAndCaseOrderAreStable() {
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
    XCTAssertEqual(
      AIProviderCapabilitySupport.allCases.map(\.rawValue),
      ["supported", "unsupported", "unknown"]
    )
    XCTAssertEqual(
      AIProviderProtocolCapability.allCases.map(\.rawValue),
      ["tool_calling", "structured_output"]
    )
    XCTAssertEqual(
      AIProviderCapabilityProbeKind.allCases.map(\.rawValue),
      ["chat", "streamingResponse", "toolCalling", "structuredOutput", "visionInput"]
    )
    XCTAssertEqual(
      AIProviderCapabilityProbeOutcome.allCases.map(\.rawValue),
      ["supported", "unsupported", "inconclusive"]
    )
    XCTAssertEqual(
      AIProviderCapabilityEvidenceState.allCases.map(\.rawValue),
      ["static_inference", "probed", "unknown", "expired"]
    )
  }

  func testCapabilityModelDisplayNamesAndLocalizationKeysAreNonempty() {
    for capability in AIProviderCapability.allCases {
      XCTAssertFalse(capability.localizationKey.isEmpty)
      XCTAssertFalse(capability.displayName.isEmpty)
    }

    for support in AIProviderCapabilitySupport.allCases {
      XCTAssertFalse(support.localizationKey.isEmpty)
      XCTAssertFalse(support.displayName.isEmpty)
    }

    for capability in AIProviderProtocolCapability.allCases {
      XCTAssertFalse(capability.displayName.isEmpty)
    }
    for kind in AIProviderCapabilityProbeKind.allCases {
      XCTAssertFalse(kind.displayName.isEmpty)
    }
    for outcome in AIProviderCapabilityProbeOutcome.allCases {
      XCTAssertFalse(outcome.displayName.isEmpty)
    }
    for evidenceState in AIProviderCapabilityEvidenceState.allCases {
      XCTAssertFalse(evidenceState.displayName.isEmpty)
    }
  }

  func testProbeKindsMapCapabilitiesBothWaysAndOutcomesFailClosed() {
    let capabilityMappings: [(AIProviderCapabilityProbeKind, AIProviderCapability)] = [
      (.chat, .chat),
      (.streamingResponse, .streamingResponse),
      (.visionInput, .visionInput),
    ]
    for (kind, capability) in capabilityMappings {
      XCTAssertEqual(kind.capability, capability)
      XCTAssertEqual(AIProviderCapabilityProbeKind(capability: capability), kind)
      XCTAssertNil(kind.protocolCapability)
    }

    let protocolMappings: [
      (AIProviderCapabilityProbeKind, AIProviderProtocolCapability)
    ] = [
      (.toolCalling, .toolCalling),
      (.structuredOutput, .structuredOutput),
    ]
    for (kind, capability) in protocolMappings {
      XCTAssertNil(kind.capability)
      XCTAssertEqual(kind.protocolCapability, capability)
      XCTAssertEqual(
        AIProviderCapabilityProbeKind.allCases.first {
          $0.protocolCapability == capability
        },
        kind
      )
    }

    for capability in [
      AIProviderCapability.reasoningControl,
      .localService,
      .modelDiscovery,
    ] {
      XCTAssertNil(AIProviderCapabilityProbeKind(capability: capability))
    }
    XCTAssertEqual(AIProviderCapabilityProbeOutcome.supported.support, .supported)
    XCTAssertEqual(AIProviderCapabilityProbeOutcome.unsupported.support, .unsupported)
    XCTAssertEqual(AIProviderCapabilityProbeOutcome.inconclusive.support, .unknown)
  }

  func testCapabilityDescriptorsExposeStableIdentityAndRoundTripDefaults() throws {
    let capabilityDescriptor = AIProviderCapabilityDescriptor(
      capability: .visionInput,
      support: .unknown
    )
    let protocolDescriptor = AIProviderProtocolCapabilityDescriptor(
      capability: .toolCalling,
      support: .supported
    )

    XCTAssertEqual(capabilityDescriptor.id, .visionInput)
    XCTAssertEqual(capabilityDescriptor.key, "vision_input")
    XCTAssertEqual(capabilityDescriptor.displayName, capabilityDescriptor.localizedTitle)
    XCTAssertFalse(capabilityDescriptor.localizedTitle.isEmpty)
    XCTAssertFalse(capabilityDescriptor.localizedSupportTitle.isEmpty)
    XCTAssertFalse(capabilityDescriptor.localizedEvidenceTitle.isEmpty)
    XCTAssertEqual(capabilityDescriptor.evidenceState, .unknown)
    XCTAssertNil(capabilityDescriptor.probeOutcome)

    XCTAssertEqual(protocolDescriptor.id, .toolCalling)
    XCTAssertEqual(protocolDescriptor.key, "tool_calling")
    XCTAssertEqual(protocolDescriptor.displayName, protocolDescriptor.localizedTitle)
    XCTAssertFalse(protocolDescriptor.localizedTitle.isEmpty)
    XCTAssertFalse(protocolDescriptor.localizedSupportTitle.isEmpty)
    XCTAssertFalse(protocolDescriptor.localizedEvidenceTitle.isEmpty)
    XCTAssertEqual(protocolDescriptor.evidenceState, .unknown)
    XCTAssertNil(protocolDescriptor.probeOutcome)

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    XCTAssertEqual(
      try decoder.decode(
        AIProviderCapabilityDescriptor.self,
        from: encoder.encode(capabilityDescriptor)
      ),
      capabilityDescriptor
    )
    XCTAssertEqual(
      try decoder.decode(
        AIProviderProtocolCapabilityDescriptor.self,
        from: encoder.encode(protocolDescriptor)
      ),
      protocolDescriptor
    )
  }
}
