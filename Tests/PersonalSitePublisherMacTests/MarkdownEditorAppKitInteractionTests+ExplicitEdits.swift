import AppKit
import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionExplicitEditTests: MarkdownEditorAppKitInteractionTestCase {
  func testOldEditRequestCannotOverwriteLiveTextAheadOfBindingPublication() {
    let coordinator = makeCoordinator(source: "甲乙", bodyMarkdown: "甲乙", bodyUTF16Offset: 0)
    let view = makeTextView()
    view.string = "甲丙"
    let request = MarkdownTextEditRequest(
      expectedText: "甲乙",
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 0, length: 2), replacement: "一二",
        selectedRange: NSRange(location: 0, length: 0)
      )
    )
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, false)
    XCTAssertEqual(view.string, "甲丙")
  }

  func testExplicitEditMatchesActualBodyAfterFrontMatterAndRemainsUndoable() {
    let prefix = "---\ntitle: 示例\n---\n"
    let body = "甲😀乙"
    let coordinator = makeCoordinator(
      source: prefix + body, bodyMarkdown: body, bodyUTF16Offset: (prefix as NSString).length
    )
    let view = makeTextView()
    view.string = prefix + body
    view.allowsUndo = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    defer { window.orderOut(nil) }
    let request = MarkdownTextEditRequest(
      expectedText: body,
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 1, length: 2), replacement: "新",
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, true)
    XCTAssertEqual(view.string, prefix + "甲新乙")
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(view.string, prefix + body)
  }
}
