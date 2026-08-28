import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeImageOCRServiceTests: XCTestCase {
  func testVisualAnchorCodableClampsNormalizedBounds() throws {
    let anchor = KnowledgeVisualAnchor(
      frameIndex: -4,
      x: -0.2,
      y: 0.8,
      width: 2,
      height: 0.6,
      confidence: 1.4
    )
    let decoded = try JSONDecoder().decode(
      KnowledgeVisualAnchor.self,
      from: JSONEncoder().encode(anchor)
    )

    XCTAssertEqual(decoded.frameIndex, 0)
    XCTAssertEqual(decoded.x, 0)
    XCTAssertEqual(decoded.y, 0.8)
    XCTAssertEqual(decoded.width, 1)
    XCTAssertEqual(decoded.height, 0.2, accuracy: 0.000_001)
    XCTAssertEqual(decoded.confidence, 1)
  }

  func testChunkingPreservesVisualAnchorFromOCRSection() throws {
    let anchor = KnowledgeVisualAnchor(
      frameIndex: 0,
      x: 0.1,
      y: 0.2,
      width: 0.3,
      height: 0.1,
      confidence: 0.91
    )
    let chunks = KnowledgeChunkingService(maximumChunkCharacters: 320).chunks(
      documentID: UUID(),
      revisionID: UUID(),
      sections: [KnowledgeExtractedSection(text: "图中文字", visualAnchor: anchor)]
    )

    XCTAssertEqual(try XCTUnwrap(chunks.first).visualAnchor, anchor)
  }
}
