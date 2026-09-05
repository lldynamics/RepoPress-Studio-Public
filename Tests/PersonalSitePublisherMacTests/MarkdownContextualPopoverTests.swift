import CoreGraphics
import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownContextualPopoverTests: XCTestCase {
  private let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)

  func testPreferredAbovePlacementTracksAMultilineSelectionAndCentersIt() throws {
    let anchor = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: 24, length: 36),
      rect: CGRect(x: 160, y: 150, width: 84, height: 44),
      viewport: viewport
    )

    let placement = try XCTUnwrap(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: anchor,
        contentSize: CGSize(width: 180, height: 40),
        preferredEdge: .above
      )
    )

    XCTAssertEqual(placement.edge, .above)
    XCTAssertEqual(placement.frame.maxY, anchor.rect.minY - 8, accuracy: 0.001)
    XCTAssertEqual(placement.frame.midX, anchor.rect.midX, accuracy: 0.001)
  }

  func testPlacementFlipsBelowWhenThereIsNoSpaceAbove() throws {
    let anchor = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: 2, length: 1),
      rect: CGRect(x: 120, y: 18, width: 12, height: 18),
      viewport: viewport
    )

    let placement = try XCTUnwrap(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: anchor,
        contentSize: CGSize(width: 220, height: 120),
        preferredEdge: .above
      )
    )

    XCTAssertEqual(placement.edge, .below)
    XCTAssertEqual(placement.frame.minY, anchor.rect.maxY + 8, accuracy: 0.001)
  }

  func testPlacementClampsBothHorizontalEdgesForNarrowViewport() throws {
    let leftAnchor = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: 0, length: 0),
      rect: CGRect(x: 1, y: 110, width: 2, height: 18),
      viewport: CGRect(x: 0, y: 0, width: 250, height: 260)
    )
    let rightAnchor = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: 200, length: 1),
      rect: CGRect(x: 246, y: 110, width: 2, height: 18),
      viewport: CGRect(x: 0, y: 0, width: 250, height: 260)
    )

    let left = try XCTUnwrap(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: leftAnchor,
        contentSize: CGSize(width: 220, height: 40),
        preferredEdge: .below
      )
    )
    let right = try XCTUnwrap(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: rightAnchor,
        contentSize: CGSize(width: 220, height: 40),
        preferredEdge: .below
      )
    )

    XCTAssertEqual(left.frame.minX, 12, accuracy: 0.001)
    XCTAssertEqual(right.frame.maxX, 238, accuracy: 0.001)
  }

  func testInvalidRangeOrEmptyViewportDoesNotProduceFixedFallbackPlacement() {
    let invalidRange = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: NSNotFound, length: 0),
      rect: CGRect(x: 20, y: 20, width: 4, height: 18),
      viewport: viewport
    )
    let emptyViewport = MarkdownContextualPopoverAnchor(
      selection: NSRange(location: 0, length: 0),
      rect: CGRect(x: 20, y: 20, width: 4, height: 18),
      viewport: .zero
    )

    XCTAssertNil(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: invalidRange,
        contentSize: CGSize(width: 180, height: 40),
        preferredEdge: .below
      )
    )
    XCTAssertNil(
      MarkdownContextualPopoverPlacement.resolve(
        anchor: emptyViewport,
        contentSize: CGSize(width: 180, height: 40),
        preferredEdge: .below
      )
    )
  }

  func testBodySelectionRemovesFrontMatterOffsetWithoutChangingTextGeometry() throws {
    let selection = try XCTUnwrap(
      MarkdownContextualPopoverAnchorResolver.selection(
        forDocumentRange: NSRange(location: 31, length: 4),
        documentUTF16Length: 44,
        bodyUTF16Offset: 24,
        bodyUTF16Length: 20
      )
    )

    XCTAssertEqual(selection, NSRange(location: 7, length: 4))
  }

  func testFrontMatterSourceSelectionUsesSourceModeRange() throws {
    let selection = try XCTUnwrap(
      MarkdownContextualPopoverAnchorResolver.selection(
        forDocumentRange: NSRange(location: 6, length: 3),
        documentUTF16Length: 44,
        bodyUTF16Offset: 24,
        bodyUTF16Length: 20
      )
    )

    XCTAssertEqual(selection, NSRange(location: 0, length: 0))
  }

  func testInvalidFrontMatterSourceModeUsesTheSameClampedBodySelectionAsEditorBridge() throws {
    let selection = try XCTUnwrap(
      MarkdownContextualPopoverAnchorResolver.selection(
        forDocumentRange: NSRange(location: 42, length: 5),
        documentUTF16Length: 47,
        bodyUTF16Offset: 24,
        bodyUTF16Length: 12
      )
    )

    XCTAssertEqual(selection, NSRange(location: 12, length: 0))
  }

  func testOffscreenAndOverflowingDocumentRangesDoNotCreateAnAnchor() {
    XCTAssertNil(
      MarkdownContextualPopoverAnchorResolver.anchor(
        selection: NSRange(location: 2, length: 1),
        textRect: CGRect(x: 20, y: 420, width: 10, height: 18),
        visibleTextRect: CGRect(x: 0, y: 0, width: 300, height: 200),
        viewport: CGRect(x: 0, y: 0, width: 300, height: 200)
      )
    )
    XCTAssertNil(
      MarkdownContextualPopoverAnchorResolver.selection(
        forDocumentRange: NSRange(location: Int.max - 1, length: 4),
        documentUTF16Length: 12,
        bodyUTF16Offset: 0,
        bodyUTF16Length: 12
      )
    )
  }

  func testEmptyCaretRectGetsANonZeroHitTargetBeforePlacement() {
    let rect = MarkdownContextualPopoverAnchorResolver.normalizedTextRect(
      CGRect(x: 20, y: 30, width: 0, height: 18),
      for: NSRange(location: 5, length: 0)
    )

    XCTAssertEqual(rect.width, 1)
    XCTAssertEqual(rect.height, 18)
  }
}
