import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class EditorAIReviewPresentationTests: XCTestCase {
  func testGhostCommandPolicyRejectsMarkedTextAndNonCollapsedSelections() {
    let cursor = NSRange(location: 3, length: 0)
    XCTAssertFalse(
      MarkdownGhostTextCommandPolicy.shouldAccept(
        ghostText: "续写", selectedRange: cursor, bodyUTF16Offset: 0, hasMarkedText: true
      ))
    XCTAssertFalse(
      MarkdownGhostTextCommandPolicy.shouldAccept(
        ghostText: "续写", selectedRange: NSRange(location: 3, length: 1), bodyUTF16Offset: 0,
        hasMarkedText: false
      ))
    XCTAssertFalse(
      MarkdownGhostTextCommandPolicy.shouldDismiss(ghostText: "续写", hasMarkedText: true))
  }

  func testGhostCommandPolicyAcceptsOnlyCollapsedBodyCursor() {
    XCTAssertTrue(
      MarkdownGhostTextCommandPolicy.shouldAccept(
        ghostText: "续写", selectedRange: NSRange(location: 4, length: 0), bodyUTF16Offset: 4,
        hasMarkedText: false
      ))
    XCTAssertFalse(
      MarkdownGhostTextCommandPolicy.shouldAccept(
        ghostText: "续写", selectedRange: NSRange(location: 3, length: 0), bodyUTF16Offset: 4,
        hasMarkedText: false
      ))
  }

  @MainActor
  func testGhostOverlayDoesNotInterceptPointerEvents() {
    let overlay = MarkdownGhostTextOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 10)))
  }
}
