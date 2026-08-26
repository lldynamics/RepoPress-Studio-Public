import Foundation
import XCTest

@testable import PublishingAICore

final class AIOutboundPayloadPreviewModelsTests: XCTestCase {
  func testPreviewRoundTripsThroughCodable() throws {
    let preview = AIOutboundPayloadPreview(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      destination: "https://example.com/v1/chat",
      model: "gpt-test",
      contextCounts: [
        AIOutboundPayloadContextCount(category: .currentArticle, count: 2),
        AIOutboundPayloadContextCount(category: .imageAttachment, count: 1),
      ],
      textCharacterCount: 128,
      imageCount: 1,
      imageByteCount: 2048,
      strippedFields: [.absoluteLocalPath, .shellCommand],
      sensitiveCategories: [.absoluteLocalPath, .credentialLikeSecret],
      nonce: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      fingerprint: "fingerprint",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      expiresAt: Date(timeIntervalSince1970: 1_700_000_300),
      isLoopback: false
    )

    let data = try JSONEncoder().encode(preview)
    let decoded = try JSONDecoder().decode(AIOutboundPayloadPreview.self, from: data)

    XCTAssertEqual(decoded, preview)
  }

  func testInitializersNormalizeNegativeCountsAndSupplyIdentityDefaults() {
    let contextCount = AIOutboundPayloadContextCount(
      category: .conversationHistory,
      count: -1
    )
    let preview = AIOutboundPayloadPreview(
      destination: "loopback://local",
      model: "local",
      contextCounts: [contextCount],
      textCharacterCount: -1,
      imageCount: -2,
      imageByteCount: -3,
      strippedFields: [],
      sensitiveCategories: [],
      fingerprint: "fingerprint",
      createdAt: .distantPast,
      expiresAt: .distantFuture,
      isLoopback: true
    )

    XCTAssertEqual(contextCount.count, 0)
    XCTAssertEqual(preview.textCharacterCount, 0)
    XCTAssertEqual(preview.imageCount, 0)
    XCTAssertEqual(preview.imageByteCount, 0)
    XCTAssertNotEqual(preview.id, UUID())
    XCTAssertNotEqual(preview.nonce, UUID())
  }
}
