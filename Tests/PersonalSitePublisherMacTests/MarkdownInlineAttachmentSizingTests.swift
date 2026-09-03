import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownInlineAttachmentSizingTests: XCTestCase {
  func testImageCardHeightFollowsAspectRatioWithinBounds() {
    XCTAssertEqual(
      MarkdownInlineAttachmentImageLayout.cardHeight(
        imageSize: NSSize(width: 1_600, height: 900),
        availableWidth: 616
      ),
      354,
      accuracy: 0.01
    )
    XCTAssertEqual(
      MarkdownInlineAttachmentImageLayout.cardHeight(
        imageSize: NSSize(width: 4_000, height: 400),
        availableWidth: 616
      ),
      MarkdownInlineAttachmentImageLayout.minimumCardHeight,
      accuracy: 0.01
    )
    XCTAssertEqual(
      MarkdownInlineAttachmentImageLayout.cardHeight(
        imageSize: NSSize(width: 400, height: 2_000),
        availableWidth: 616
      ),
      MarkdownInlineAttachmentImageLayout.maximumCardHeight,
      accuracy: 0.01
    )
  }

  func testImageCardHeightFallsBackWhenMetadataIsUnavailable() {
    XCTAssertEqual(
      MarkdownInlineAttachmentImageLayout.cardHeight(
        imageSize: nil,
        availableWidth: 600
      ),
      MarkdownInlineAttachmentImageLayout.fallbackCardHeight,
      accuracy: 0.01
    )
    XCTAssertEqual(
      MarkdownInlineAttachmentImageLayout.minimumLineHeight(forCardHeight: 120),
      136,
      accuracy: 0.01
    )
  }

  func testOpenOriginalControlUsesAContainedTopRightHitTarget() throws {
    let card = NSRect(x: 12, y: 20, width: 400, height: 220)
    let frame = try XCTUnwrap(MarkdownInlineAttachmentOpenOriginalControl.frame(in: card))

    XCTAssertEqual(frame.maxX, card.maxX - MarkdownInlineAttachmentOpenOriginalControl.inset)
    XCTAssertEqual(frame.maxY, card.maxY - MarkdownInlineAttachmentOpenOriginalControl.inset)
    XCTAssertTrue(
      MarkdownInlineAttachmentOpenOriginalControl.contains(
        NSPoint(x: frame.midX, y: frame.midY),
        in: card
      )
    )
    XCTAssertFalse(
      MarkdownInlineAttachmentOpenOriginalControl.contains(
        NSPoint(x: card.minX + 4, y: card.minY + 4),
        in: card
      )
    )
  }

  func testOpenOriginalControlDeclinesCardsTooSmallForARealHitTarget() {
    XCTAssertNil(
      MarkdownInlineAttachmentOpenOriginalControl.frame(
        in: NSRect(x: 0, y: 0, width: 40, height: 30)
      )
    )
  }
}
