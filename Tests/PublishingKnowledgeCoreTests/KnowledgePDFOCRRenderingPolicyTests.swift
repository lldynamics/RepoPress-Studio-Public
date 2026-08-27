import CoreGraphics
import XCTest
@testable import PublishingKnowledgeCore

final class KnowledgePDFOCRRenderingPolicyTests: XCTestCase {
  func testTargetSizeCapsTheLongestEdgeAt1600Pixels() throws {
    let landscape = try XCTUnwrap(
      KnowledgePDFOCRRenderingPolicy.targetSize(
        for: CGRect(x: 0, y: 0, width: 4_000, height: 2_000)
      )
    )
    XCTAssertEqual(landscape.width, 1_600, accuracy: 0.001)
    XCTAssertEqual(landscape.height, 800, accuracy: 0.001)

    let portrait = try XCTUnwrap(
      KnowledgePDFOCRRenderingPolicy.targetSize(
        for: CGRect(x: 0, y: 0, width: 1_000, height: 5_000)
      )
    )
    XCTAssertEqual(portrait.width, 320, accuracy: 0.001)
    XCTAssertEqual(portrait.height, 1_600, accuracy: 0.001)
  }

  func testTargetSizeRejectsEmptyPageBounds() {
    XCTAssertNil(
      KnowledgePDFOCRRenderingPolicy.targetSize(
        for: CGRect(x: 0, y: 0, width: 0, height: 800)
      )
    )
  }
}
