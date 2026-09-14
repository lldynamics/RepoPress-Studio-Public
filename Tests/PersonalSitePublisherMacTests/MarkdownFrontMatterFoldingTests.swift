import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownFrontMatterFoldingTests: MarkdownEditorAppKitInteractionTestCase {
  func testFoldedTextKitLayoutStartsAtBodyIncludingEmptyBody() throws {
    for body in ["正文😀\n第二行", ""] {
      let prefix = "+++\ntitle = \"标题\"\ncustom = [1, 2]\n+++\n\n"
      let scroll = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
      scroll.contentView = MarkdownFrontMatterClipView()
      let view = DroppableMarkdownTextView.makeTextKit2(
        containerSize: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
      view.string = prefix + body
      scroll.documentView = view
      let window = NSWindow(
        contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = scroll
      defer { window.orderOut(nil) }
      scroll.foldedFrontMatterBodyOffset = (prefix as NSString).length
      scroll.layoutSubtreeIfNeeded()
      let clip = try XCTUnwrap(scroll.contentView as? MarkdownFrontMatterClipView)
      XCTAssertGreaterThan(clip.hiddenPrefixHeight, 20)
      XCTAssertGreaterThanOrEqual(clip.bounds.minY, clip.hiddenPrefixHeight)
      XCTAssertEqual(view.string, prefix + body)
      scroll.foldedFrontMatterBodyOffset = 0
      scroll.layoutSubtreeIfNeeded()
      XCTAssertEqual(clip.hiddenPrefixHeight, 0)
      XCTAssertEqual(clip.bounds.minY, 0)
    }
  }

  func testFoldedSelectionAndBackspaceCannotReachHiddenMetadata() {
    let prefix = "+++\ntitle = \"标题😀\"\nunknown = [1, 2]\n+++\n\n"
    let body = "正文😀"
    let offset = (prefix as NSString).length
    let source = prefix + body
    let coordinator = makeCoordinator(source: source, bodyMarkdown: body, bodyUTF16Offset: offset)
    coordinator.isFrontMatterFolded = true
    let view = makeTextView()
    view.string = source
    XCTAssertEqual(
      coordinator.textView(
        view,
        willChangeSelectionFromCharacterRange: NSRange(location: offset, length: 0),
        toCharacterRange: NSRange(location: 0, length: (source as NSString).length)),
      NSRange(location: offset, length: (body as NSString).length))
    XCTAssertFalse(
      coordinator.textView(
        view,
        shouldChangeTextIn: NSRange(location: offset - 1, length: 1), replacementString: ""))
    XCTAssertEqual(view.string, source)
    coordinator.isFrontMatterFolded = false
    XCTAssertTrue(
      coordinator.textView(
        view,
        shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "+"))
  }

  func testFoldingPreservesUnknownMetadataAndBodyUndo() {
    let prefix = "---\ntitle: 示例\ncustom: {nested: [one, two]}\n---\n\n"
    let body = "甲😀乙"
    let coordinator = makeCoordinator(
      source: prefix + body, bodyMarkdown: body,
      bodyUTF16Offset: (prefix as NSString).length)
    coordinator.isFrontMatterFolded = true
    let view = makeTextView()
    view.string = prefix + body
    view.allowsUndo = true
    view.delegate = coordinator
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.makeFirstResponder(view)
    defer { window.orderOut(nil) }
    let request = MarkdownTextEditRequest(
      expectedText: body,
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 1, length: 2), replacement: "新",
        selectedRange: NSRange(location: 2, length: 0)))
    XCTAssertEqual(coordinator.handle(request, in: view)?.wasApplied, true)
    XCTAssertEqual(view.string, prefix + "甲新乙")
    coordinator.isFrontMatterFolded = false
    coordinator.isFrontMatterFolded = true
    view.undoManager?.undo()
    XCTAssertEqual(view.string, prefix + body)
  }

  func testFoldClipKeepsHiddenPrefixOutsideViewportWithoutEditingDocument() {
    let clip = MarkdownFrontMatterClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let view = makeTextView()
    view.string = "metadata\nbody"
    view.setFrameSize(NSSize(width: 400, height: 700))
    clip.documentView = view
    clip.hiddenPrefixHeight = 100
    let constrained = clip.constrainBoundsRect(NSRect(x: 0, y: 0, width: 400, height: 200))
    XCTAssertGreaterThanOrEqual(constrained.minY, 100)
    XCTAssertEqual(view.string, "metadata\nbody")
    clip.hiddenPrefixHeight = 0
    XCTAssertEqual(clip.constrainBoundsRect(NSRect(x: 0, y: 0, width: 400, height: 200)).minY, 0)
  }
}
