import XCTest

@testable import PublishingAICore

final class AIProviderCapabilityRejectionClassifierTests: XCTestCase {
  func testExplicitCapabilityMarkersAndRejectionsAreRecognized() {
    XCTAssertTrue(
      AIProviderCapabilityRejectionClassifier.explicitlyRejects(
        "STREAM_OPTIONS is NOT SUPPORTED",
        capability: .streamingResponse
      )
    )
    XCTAssertTrue(
      AIProviderCapabilityRejectionClassifier.explicitlyRejects(
        "Tool_Choice is unsupported",
        capability: .toolCalling
      )
    )
    XCTAssertTrue(
      AIProviderCapabilityRejectionClassifier.explicitlyRejects(
        "JSON_SCHEMA is NOT IMPLEMENTED",
        capability: .structuredOutput
      )
    )
    XCTAssertTrue(
      AIProviderCapabilityRejectionClassifier.explicitlyRejects(
        "IMAGE_URL is an UNKNOWN PARAMETER",
        capability: .visionInput
      )
    )
  }

  func testIncompleteOrUnrelatedErrorsAreNotClassifiedAsRejections() {
    let cases: [(String, AIProviderCapabilityProbeKind)] = [
      ("", .streamingResponse),
      ("stream_options", .streamingResponse),
      ("unsupported", .streamingResponse),
      ("authentication failed: invalid API key", .toolCalling),
      ("rate limit exceeded", .structuredOutput),
      ("internal server error", .visionInput),
    ]

    for (body, capability) in cases {
      XCTAssertFalse(
        AIProviderCapabilityRejectionClassifier.explicitlyRejects(
          body,
          capability: capability
        ),
        "Unexpected unsupported classification for: \(body)"
      )
    }
  }

  func testChatIsNeverClassifiedAsUnsupportedAndMatchingIsCaseInsensitive() {
    let bodies = [
      "STREAM_OPTIONS IS NOT SUPPORTED",
      "Tool_Choice Unsupported",
      "JSON_SCHEMA NOT IMPLEMENTED",
      "IMAGE_URL UNKNOWN PARAMETER",
      "CHAT IS NOT SUPPORTED",
    ]

    for body in bodies {
      XCTAssertFalse(
        AIProviderCapabilityRejectionClassifier.explicitlyRejects(
          body,
          capability: .chat
        ),
        "Chat must remain supported/unknown rather than unsupported: \(body)"
      )
    }
  }

  func testFixedDetailsAreStableAndNeverEchoProbeResponseBody() {
    let expectedDetails: [(AIProviderCapabilityProbeKind, String)] = [
      (.chat, "connection response did not prove chat capability"),
      (.streamingResponse, "stream capability was explicitly rejected"),
      (.toolCalling, "tool-calling capability was explicitly rejected"),
      (.structuredOutput, "structured-output capability was explicitly rejected"),
      (.visionInput, "vision capability was explicitly rejected"),
    ]
    let responseBody = "provider response: stream_options is not supported"

    for (capability, expectedDetail) in expectedDetails {
      let detail = AIProviderCapabilityRejectionClassifier.fixedDetail(
        for: capability
      )
      XCTAssertEqual(detail, expectedDetail)
      XCTAssertFalse(detail.contains(responseBody))
      XCTAssertEqual(
        detail,
        AIProviderCapabilityRejectionClassifier.fixedDetail(for: capability)
      )
      XCTAssertEqual(
        AIProviderCapabilityRejectionClassifier.inconclusiveDetail,
        "probe response was inconclusive"
      )
      XCTAssertFalse(
        AIProviderCapabilityRejectionClassifier.inconclusiveDetail.contains(responseBody)
      )
    }
  }
}
