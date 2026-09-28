import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorCommandTargetTests: MarkdownEditorAppKitInteractionTestCase {
  func testExplicitSaveDrainsOnlyItsMountedEditor() {
    let first = makeCoordinator(source: "first", bodyMarkdown: "first", bodyUTF16Offset: 0)
    let second = makeCoordinator(source: "second", bodyMarkdown: "second", bodyUTF16Offset: 0)
    let firstView = NSTextView()
    let secondView = NSTextView()
    first.textView = firstView
    second.textView = secondView
    firstView.string = "first edited"
    secondView.string = "second edited"
    first.textDidChange(Notification(name: NSText.didChangeNotification, object: firstView))
    second.textDidChange(Notification(name: NSText.didChangeNotification, object: secondView))
    let target = MarkdownEditorCommandTarget()
    target.coordinator = first

    XCTAssertEqual(first.text, "first")
    XCTAssertTrue(target.flushPendingWrites())
    XCTAssertEqual(first.text, "first edited")
    XCTAssertEqual(second.text, "second")
    second.flushPendingBindingWrites()
  }

  func testExplicitSaveDoesNotCommitMarkedInput() {
    let coordinator = makeCoordinator(source: "body", bodyMarkdown: "body", bodyUTF16Offset: 0)
    let textView = ComposingTextView()
    coordinator.textView = textView
    let target = MarkdownEditorCommandTarget()
    target.coordinator = coordinator

    XCTAssertFalse(target.flushPendingWrites())
    XCTAssertEqual(coordinator.text, "body")
  }

  func testUnmountedEditorCannotClaimInputWasFlushed() {
    XCTAssertFalse(MarkdownEditorCommandTarget().flushPendingWrites())
  }

  func testStaleCommandCannotFlushAnotherDraftAfterSelectionChanges() {
    let coordinator = makeCoordinator(source: "body", bodyMarkdown: "body", bodyUTF16Offset: 0)
    let textView = NSTextView()
    coordinator.textView = textView
    let target = MarkdownEditorCommandTarget()
    target.coordinator = coordinator
    target.documentID = UUID()
    XCTAssertFalse(target.flushPendingWrites(for: UUID()))
    XCTAssertTrue(target.flushPendingWrites(for: target.documentID))
  }
}

@MainActor
private final class ComposingTextView: NSTextView {
  override func hasMarkedText() -> Bool { true }
}
