import Foundation
import XCTest

import PublishingAICore

final class AIProviderRequestPurposeTests: XCTestCase {
  func testRequestPurposesPreserveExplicitOrderAndRawValues() {
    let purposes: [AIProviderRequestPurpose] = [
      .interactiveChat,
      .utilityTask,
      .connectionTest,
      .capabilityProbe,
    ]

    XCTAssertEqual(
      purposes.map(\.rawValue),
      [
        "interactive_chat",
        "utility_task",
        "connection_test",
        "capability_probe",
      ]
    )
    XCTAssertEqual(purposes.count, 4)
  }

  func testRequestPurposesRoundTripThroughCanonicalJSON() throws {
    let purposes: [AIProviderRequestPurpose] = [
      .interactiveChat,
      .utilityTask,
      .connectionTest,
      .capabilityProbe,
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for purpose in purposes {
      let encoded = try encoder.encode(purpose)
      XCTAssertEqual(
        String(decoding: encoded, as: UTF8.self),
        "\"\(purpose.rawValue)\"",
        purpose.rawValue
      )
      XCTAssertEqual(
        try decoder.decode(AIProviderRequestPurpose.self, from: encoded),
        purpose
      )
    }
  }

  func testUnknownRequestPurposeRawValueFailsDecoding() {
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        AIProviderRequestPurpose.self,
        from: Data("\"future_request_purpose\"".utf8)
      )
    )
  }
}
