import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorVersionHistoryActionsTests: MarkdownEditorAppKitInteractionTestCase {
  func testHistoryDrainsOnlyItsOwnMountedEditorBeforePresentation() {
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
    let draftID = UUID()
    let target = MarkdownEditorCommandTarget()
    target.coordinator = first
    target.documentID = draftID
    var presentedBody: String?
    let action = MarkdownEditorVersionHistoryCommandAction(
      draftID: draftID,
      prepare: { target.flushPendingWrites(for: draftID) },
      present: { presentedBody = first.text }
    )

    action.open()

    XCTAssertEqual(presentedBody, "first edited")
    XCTAssertEqual(second.text, "second")
    second.flushPendingBindingWrites()
  }

  func testStaleHistoryActionCannotOpenTheNextDraft() {
    let coordinator = makeCoordinator(source: "body", bodyMarkdown: "body", bodyUTF16Offset: 0)
    let textView = NSTextView()
    coordinator.textView = textView
    let target = MarkdownEditorCommandTarget()
    target.coordinator = coordinator
    let expectedDraftID = UUID()
    target.documentID = UUID()
    var presentationCount = 0
    let action = MarkdownEditorVersionHistoryCommandAction(
      draftID: expectedDraftID,
      prepare: { target.flushPendingWrites(for: expectedDraftID) },
      present: { presentationCount += 1 }
    )

    action.open()

    XCTAssertEqual(presentationCount, 0)
  }

  func testHistoryDoesNotInterruptMarkedInput() {
    let coordinator = makeCoordinator(source: "body", bodyMarkdown: "body", bodyUTF16Offset: 0)
    let textView = HistoryComposingTextView()
    coordinator.textView = textView
    let target = MarkdownEditorCommandTarget()
    target.coordinator = coordinator
    let draftID = UUID()
    target.documentID = draftID
    var presentationCount = 0
    let action = MarkdownEditorVersionHistoryCommandAction(
      draftID: draftID,
      prepare: { target.flushPendingWrites(for: draftID) },
      present: { presentationCount += 1 }
    )

    action.open()

    XCTAssertEqual(presentationCount, 0)
    XCTAssertEqual(coordinator.text, "body")
  }
}

@MainActor
private final class HistoryComposingTextView: NSTextView {
  override func hasMarkedText() -> Bool { true }
}
