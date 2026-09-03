import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownContextualPopoverTests: XCTestCase {
  func testSlashMenuUsesLeadingEdgeBelowCaretWhenSpaceAllows() {
    let placement = MarkdownContextualPopoverPlacement.resolve(
      anchor: CGRect(x: 120, y: 80, width: 2, height: 20),
      contentSize: CGSize(width: 250, height: 180),
      containerSize: CGSize(width: 700, height: 500),
      preferredEdge: .below,
      horizontalAlignment: .leading
    )

    XCTAssertEqual(placement.edge, .below)
    XCTAssertEqual(placement.origin, CGPoint(x: 120, y: 108))
  }

  func testSlashMenuFlipsAboveCaretNearBottomEdge() {
    let placement = MarkdownContextualPopoverPlacement.resolve(
      anchor: CGRect(x: 120, y: 450, width: 2, height: 20),
      contentSize: CGSize(width: 250, height: 180),
      containerSize: CGSize(width: 700, height: 500),
      preferredEdge: .below,
      horizontalAlignment: .leading
    )

    XCTAssertEqual(placement.edge, .above)
    XCTAssertEqual(placement.origin.y, 262)
  }

  func testSelectionBubbleFlipsBelowSelectionNearTopEdge() {
    let placement = MarkdownContextualPopoverPlacement.resolve(
      anchor: CGRect(x: 300, y: 10, width: 80, height: 22),
      contentSize: CGSize(width: 360, height: 40),
      containerSize: CGSize(width: 700, height: 500),
      preferredEdge: .above,
      horizontalAlignment: .center
    )

    XCTAssertEqual(placement.edge, .below)
    XCTAssertEqual(placement.origin, CGPoint(x: 160, y: 40))
  }

  func testPopoverClampsToHorizontalViewportMargins() {
    let placement = MarkdownContextualPopoverPlacement.resolve(
      anchor: CGRect(x: 680, y: 100, width: 2, height: 20),
      contentSize: CGSize(width: 250, height: 180),
      containerSize: CGSize(width: 700, height: 500),
      preferredEdge: .below,
      horizontalAlignment: .leading
    )

    XCTAssertEqual(placement.origin.x, 438)
  }

  @MainActor
  func testAppKitRectConvertsToTopLeadingEditorCoordinates() {
    let converted = MarkdownEditorContextualAnchorResolver.topLeadingRect(
      from: CGRect(x: 40, y: 320, width: 80, height: 24),
      in: CGRect(x: 0, y: 0, width: 700, height: 500),
      isFlipped: false
    )

    XCTAssertEqual(converted, CGRect(x: 40, y: 156, width: 80, height: 24))
  }

  @MainActor
  func testTextKitCaretResolvesInsideVisibleEditorViewport() throws {
    let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 420, height: 260))
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: CGRect(x: 0, y: 0, width: 420, height: 600),
      containerSize: CGSize(width: 388, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = "第一行\n第二行光标"
    textView.font = NSFont.systemFont(ofSize: 16)
    textView.textContainerInset = CGSize(width: 16, height: 16)
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    scrollView.documentView = textView
    scrollView.layoutSubtreeIfNeeded()

    let anchor = MarkdownEditorContextualAnchorResolver.viewportRect(
      for: textView.selectedRange(),
      in: textView
    )

    let resolvedAnchor = try XCTUnwrap(anchor)
    XCTAssertGreaterThanOrEqual(resolvedAnchor.minX, 0)
    XCTAssertGreaterThanOrEqual(resolvedAnchor.minY, 0)
    XCTAssertLessThanOrEqual(resolvedAnchor.maxX, scrollView.bounds.width)
    XCTAssertLessThanOrEqual(resolvedAnchor.maxY, scrollView.bounds.height)
  }

  @MainActor
  func testTextKitAnchorMovesWithTheEditorViewport() throws {
    let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 420, height: 180))
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: CGRect(x: 0, y: 0, width: 420, height: 1_200),
      containerSize: CGSize(width: 388, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = Array(repeating: "可滚动的编辑器行", count: 120).joined(separator: "\n")
    textView.font = NSFont.systemFont(ofSize: 16)
    textView.textContainerInset = CGSize(width: 16, height: 16)
    textView.setSelectedRange(NSRange(location: 0, length: 1))
    scrollView.documentView = textView
    scrollView.layoutSubtreeIfNeeded()

    let visibleBeforeScroll = try XCTUnwrap(
      MarkdownEditorContextualAnchorResolver.viewportRect(
        for: textView.selectedRange(),
        in: textView
      )
    )
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 80))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    scrollView.layoutSubtreeIfNeeded()

    XCTAssertNil(
      MarkdownEditorContextualAnchorResolver.viewportRect(
        for: textView.selectedRange(),
        in: textView
      )
    )
    XCTAssertGreaterThanOrEqual(visibleBeforeScroll.minY, 0)
  }
}
