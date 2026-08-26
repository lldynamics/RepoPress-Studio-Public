import XCTest
import PublishingAICore

final class AIProviderPresetCapabilitySupportTests: XCTestCase {
  private static let businessSupportMatrix: [
    (preset: AIProviderPreset, capability: AIProviderCapability, support: AIProviderCapabilitySupport)
  ] = [
    (.codexAppServer, .chat, .supported),
    (.codexAppServer, .streamingResponse, .supported),
    (.codexAppServer, .visionInput, .unsupported),
    (.codexAppServer, .reasoningControl, .supported),
    (.codexAppServer, .localService, .unsupported),
    (.codexAppServer, .modelDiscovery, .supported),
    (.openAICompatible, .chat, .supported),
    (.openAICompatible, .streamingResponse, .supported),
    (.openAICompatible, .visionInput, .unknown),
    (.openAICompatible, .reasoningControl, .unsupported),
    (.openAICompatible, .localService, .unsupported),
    (.openAICompatible, .modelDiscovery, .supported),
    (.deepSeek, .chat, .supported),
    (.deepSeek, .streamingResponse, .supported),
    (.deepSeek, .visionInput, .unsupported),
    (.deepSeek, .reasoningControl, .supported),
    (.deepSeek, .localService, .unsupported),
    (.deepSeek, .modelDiscovery, .supported),
    (.anthropic, .chat, .supported),
    (.anthropic, .streamingResponse, .supported),
    (.anthropic, .visionInput, .unknown),
    (.anthropic, .reasoningControl, .unknown),
    (.anthropic, .localService, .unsupported),
    (.anthropic, .modelDiscovery, .supported),
    (.gemini, .chat, .supported),
    (.gemini, .streamingResponse, .supported),
    (.gemini, .visionInput, .unknown),
    (.gemini, .reasoningControl, .supported),
    (.gemini, .localService, .unsupported),
    (.gemini, .modelDiscovery, .supported),
    (.siliconFlow, .chat, .supported),
    (.siliconFlow, .streamingResponse, .supported),
    (.siliconFlow, .visionInput, .unknown),
    (.siliconFlow, .reasoningControl, .supported),
    (.siliconFlow, .localService, .unsupported),
    (.siliconFlow, .modelDiscovery, .supported),
    (.moonshot, .chat, .supported),
    (.moonshot, .streamingResponse, .supported),
    (.moonshot, .visionInput, .unknown),
    (.moonshot, .reasoningControl, .supported),
    (.moonshot, .localService, .unsupported),
    (.moonshot, .modelDiscovery, .supported),
    (.zhipu, .chat, .supported),
    (.zhipu, .streamingResponse, .supported),
    (.zhipu, .visionInput, .unknown),
    (.zhipu, .reasoningControl, .supported),
    (.zhipu, .localService, .unsupported),
    (.zhipu, .modelDiscovery, .supported),
    (.openRouter, .chat, .supported),
    (.openRouter, .streamingResponse, .supported),
    (.openRouter, .visionInput, .unknown),
    (.openRouter, .reasoningControl, .unknown),
    (.openRouter, .localService, .unsupported),
    (.openRouter, .modelDiscovery, .supported),
    (.local, .chat, .supported),
    (.local, .streamingResponse, .supported),
    (.local, .visionInput, .unknown),
    (.local, .reasoningControl, .unknown),
    (.local, .localService, .supported),
    (.local, .modelDiscovery, .supported),
    (.custom, .chat, .unknown),
    (.custom, .streamingResponse, .unknown),
    (.custom, .visionInput, .unknown),
    (.custom, .reasoningControl, .unknown),
    (.custom, .localService, .unknown),
    (.custom, .modelDiscovery, .unknown),
  ]

  private static let protocolSupportMatrix: [
    (
      preset: AIProviderPreset,
      capability: AIProviderProtocolCapability,
      support: AIProviderCapabilitySupport
    )
  ] = [
    (.codexAppServer, .toolCalling, .supported),
    (.codexAppServer, .structuredOutput, .unknown),
    (.openAICompatible, .toolCalling, .unknown),
    (.openAICompatible, .structuredOutput, .unknown),
    (.deepSeek, .toolCalling, .supported),
    (.deepSeek, .structuredOutput, .unknown),
    (.anthropic, .toolCalling, .supported),
    (.anthropic, .structuredOutput, .unknown),
    (.gemini, .toolCalling, .supported),
    (.gemini, .structuredOutput, .unknown),
    (.siliconFlow, .toolCalling, .supported),
    (.siliconFlow, .structuredOutput, .unknown),
    (.moonshot, .toolCalling, .supported),
    (.moonshot, .structuredOutput, .unknown),
    (.zhipu, .toolCalling, .supported),
    (.zhipu, .structuredOutput, .unknown),
    (.openRouter, .toolCalling, .unknown),
    (.openRouter, .structuredOutput, .unknown),
    (.local, .toolCalling, .unknown),
    (.local, .structuredOutput, .unknown),
    (.custom, .toolCalling, .unknown),
    (.custom, .structuredOutput, .unknown),
  ]

  func testEveryPresetBusinessCapabilitySupportMatrixIsExact() {
    XCTAssertEqual(Self.businessSupportMatrix.count, 11 * 6)
    XCTAssertEqual(AIProviderPreset.allCases.count, 11)
    XCTAssertEqual(AIProviderCapability.allCases.count, 6)

    for row in Self.businessSupportMatrix {
      XCTAssertEqual(row.preset.capabilitySupport(for: row.capability), row.support)
    }
  }

  func testEveryPresetProtocolCapabilitySupportMatrixIsExact() {
    XCTAssertEqual(Self.protocolSupportMatrix.count, 11 * 2)
    XCTAssertEqual(AIProviderPreset.allCases.count, 11)
    XCTAssertEqual(AIProviderProtocolCapability.allCases.count, 2)

    for row in Self.protocolSupportMatrix {
      XCTAssertEqual(row.preset.capabilitySupport(for: row.capability), row.support)
    }
  }

  func testPresetCapabilityDescriptorsHaveStableOrderIdentityKeysAndSupport() {
    for preset in AIProviderPreset.allCases {
      let expected = Self.businessSupportMatrix.filter { $0.preset == preset }
      let descriptors = preset.capabilityDescriptors

      XCTAssertEqual(descriptors.count, 6, preset.rawValue)
      XCTAssertEqual(
        descriptors.map(\.capability),
        expected.map(\.capability),
        preset.rawValue
      )
      XCTAssertEqual(descriptors.map(\.id), expected.map(\.capability), preset.rawValue)
      XCTAssertEqual(
        descriptors.map(\.key),
        expected.map(\.capability).map(\.rawValue),
        preset.rawValue
      )
      XCTAssertEqual(descriptors.map(\.support), expected.map(\.support), preset.rawValue)
      XCTAssertEqual(Set(descriptors.map(\.id)).count, 6, preset.rawValue)
      XCTAssertEqual(Set(descriptors.map(\.key)).count, 6, preset.rawValue)
    }
  }

  func testSingularBusinessDescriptorsMatchCollectionsAndEvidenceDefaults() throws {
    for row in Self.businessSupportMatrix {
      let singular = row.preset.capabilityDescriptor(for: row.capability)
      let collectionMatches = row.preset.capabilityDescriptors.filter {
        $0.capability == row.capability
      }

      XCTAssertEqual(collectionMatches.count, 1, "\(row.preset.rawValue):\(row.capability.rawValue)")
      let collectionDescriptor = try XCTUnwrap(collectionMatches.first)
      XCTAssertEqual(singular, collectionDescriptor)
      XCTAssertEqual(singular.support, row.support)
      XCTAssertEqual(
        singular.evidenceState,
        row.support == .unknown ? .unknown : .staticInference
      )
      XCTAssertNil(singular.probeOutcome)
    }
  }
}
