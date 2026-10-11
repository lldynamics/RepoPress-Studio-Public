import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MacMarkdownComposerDuplicateTitleTests: MarkdownEditorAppKitInteractionTestCase {
  func testDuplicateTitleDeletionPreservesFrontMatterAndCanUndoAndRedo() throws {
    let prefix = "---\ntitle: 标题 😀\n---\n"
    let body = "\r\n# 标题 😀\r\n\r\n正文 👩🏽‍💻\r\n"
    let coordinator = makeCoordinator(
      source: prefix + body, bodyMarkdown: body, bodyUTF16Offset: (prefix as NSString).length)
    let textView = makeTextView()
    textView.string = prefix + body
    textView.allowsUndo = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = textView
    window.makeFirstResponder(textView)
    defer { window.orderOut(nil) }
    let edit = try XCTUnwrap(
      MarkdownDuplicateTitleService.removalEdit(
        in: body, title: "标题 😀",
        selectedRange: NSRange(location: (body as NSString).length, length: 0)))
    let request = MarkdownTextEditRequest(expectedText: body, edit: edit)
    XCTAssertEqual(coordinator.handle(request, in: textView)?.wasApplied, true)
    let expected = prefix + "\r\n\r\n正文 👩🏽‍💻\r\n"
    XCTAssertEqual(textView.string, expected)
    XCTAssertTrue(textView.undoManager?.canUndo == true)
    textView.undoManager?.undo()
    XCTAssertEqual(textView.string, prefix + body)
    textView.undoManager?.redo()
    XCTAssertEqual(textView.string, expected)
  }

  func testNativeEditRejectsUnpublishedTextAndIME() throws {
    let body = "# Title\nBody"
    let coordinator = makeCoordinator(source: body, bodyMarkdown: body, bodyUTF16Offset: 0)
    let edit = try XCTUnwrap(
      MarkdownDuplicateTitleService.removalEdit(
        in: body, title: "Title", selectedRange: .init(location: 0, length: 0)))
    let request = MarkdownTextEditRequest(expectedText: body, edit: edit)
    let textView = makeTextView()
    textView.string = body + " typed"
    XCTAssertEqual(coordinator.handle(request, in: textView)?.wasApplied, false)
    XCTAssertEqual(textView.string, body + " typed")
    let markedTextView = DuplicateTitleComposingTextView()
    markedTextView.string = body
    XCTAssertEqual(
      coordinator.handle(
        MarkdownTextEditRequest(expectedText: body, edit: edit), in: markedTextView)?.wasApplied,
      false)
    XCTAssertEqual(markedTextView.string, body)
  }

  func testFlushUsesLatestBodyBeforeComputingRemoval() throws {
    let body = "# Title\nBody"
    let coordinator = makeCoordinator(source: body, bodyMarkdown: body, bodyUTF16Offset: 0)
    let textView = makeTextView()
    coordinator.textView = textView
    textView.string = body + " typed"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    let target = MarkdownEditorCommandTarget()
    let draftID = UUID()
    target.documentID = draftID
    target.coordinator = coordinator
    XCTAssertEqual(coordinator.text, body)
    XCTAssertTrue(target.flushPendingWrites(for: draftID))
    let latest = coordinator.bodyMarkdown
    XCTAssertEqual(latest, body + " typed")
    let edit = try XCTUnwrap(
      MarkdownDuplicateTitleService.removalEdit(
        in: latest, title: "Title", selectedRange: .init(location: 0, length: 0)))
    XCTAssertEqual(
      coordinator.handle(MarkdownTextEditRequest(expectedText: latest, edit: edit), in: textView)?
        .wasApplied, true)
    XCTAssertEqual(textView.string, "Body typed")
    coordinator.flushPendingBindingWrites()
  }

}

@MainActor
private final class DuplicateTitleComposingTextView: NSTextView {
  override func hasMarkedText() -> Bool { true }
}
