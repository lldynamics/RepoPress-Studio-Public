import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownFrontMatterFoldingTests: MarkdownEditorAppKitInteractionTestCase {
  func testStorageEditsInvalidateGeometryWithoutLayoutNotification() async throws {
    let view = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude))
    view.string = "TextKit storage edit"
    let manager = try XCTUnwrap(view.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    let observer = MarkdownEditorDocumentGeometry.Observer()
    var invalidations = 0
    observer.observe(manager) { invalidations += 1 }
    let storage = try XCTUnwrap(view.textStorage)
    storage.addAttribute(
      .foregroundColor, value: NSColor.red,
      range: NSRange(location: 0, length: storage.length))
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      if invalidations > 0 { break }
    }
    XCTAssertGreaterThan(invalidations, 0)
    observer.observe(nil) { XCTFail("Detached observer must not invalidate") }
    storage.addAttribute(
      .foregroundColor, value: NSColor.blue,
      range: NSRange(location: 0, length: storage.length))
    try await Task.sleep(for: .milliseconds(30))
  }

  func testLateTextLayoutGrowthAndShrinkUpdateTheScrollExtent() async throws {
    let scroll = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
    scroll.contentView = MarkdownFrontMatterClipView()
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = true
    let view = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude))
    view.textContainer?.widthTracksTextView = false
    view.textContainer?.heightTracksTextView = false
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.string = (1...8).map { "第 \($0) 段：语法渲染和字号变化以后，正文仍应完整显示并能立即上下滚动。" }
      .joined(separator: "\n\n")
    view.font = .systemFont(ofSize: 12)
    scroll.documentView = view
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.orderOut(nil) }
    let manager = try XCTUnwrap(view.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    scroll.layoutSubtreeIfNeeded()
    let source = view.string
    let selection = view.selectedRange()
    XCTAssertEqual(view.frame.height, scroll.contentView.bounds.height, accuracy: 1)

    // Syntax rendering can change storage attributes after the height was cached.
    // Do not manually invalidate the scroll view: it must follow TextKit's geometry.
    let storage = try XCTUnwrap(view.textStorage)
    storage.addAttribute(
      .font, value: NSFont.systemFont(ofSize: 32),
      range: NSRange(location: 0, length: storage.length))
    manager.ensureLayout(for: manager.documentRange)
    let expandedHeight = manager.usageBoundsForTextContainer.maxY + 32
    XCTAssertGreaterThan(expandedHeight, scroll.contentView.bounds.height * 2)
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      scroll.layoutSubtreeIfNeeded()
      if view.frame.height >= expandedHeight - 1 { break }
    }
    XCTAssertGreaterThanOrEqual(view.frame.height, expandedHeight - 1)
    XCTAssertFalse(try XCTUnwrap(scroll.verticalScroller).isHidden)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100)

    storage.addAttribute(
      .font, value: NSFont.systemFont(ofSize: 12),
      range: NSRange(location: 0, length: storage.length))
    manager.ensureLayout(for: manager.documentRange)
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      scroll.layoutSubtreeIfNeeded()
      if abs(view.frame.height - scroll.contentView.bounds.height) < 1 { break }
    }
    XCTAssertEqual(
      view.frame.height, scroll.contentView.bounds.height, accuracy: 1,
      "usage=\(manager.usageBoundsForTextContainer), "
        + "measured=\(String(describing: MarkdownEditorDocumentGeometry.height(in: view)))"
    )
    XCTAssertTrue(try XCTUnwrap(scroll.verticalScroller).isHidden)
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    XCTAssertEqual(view.string, source)
    XCTAssertEqual(view.selectedRange(), selection)
  }

  func testAppendingAndDeletingPlainTextUpdatesTheScrollExtentThroughStorageObserver() async throws
  {
    let scroll = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
    scroll.contentView = MarkdownFrontMatterClipView()
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = true
    let view = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude))
    view.textContainer?.widthTracksTextView = false
    view.textContainer?.heightTracksTextView = false
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.font = .systemFont(ofSize: 13)
    let original = (1...36).map { "原始正文第 \($0) 行，固定宽度下应保持可滚动。" }.joined(separator: "\n")
    let appended = (1...24).map { "追加正文第 \($0) 行，存储通知应更新文档高度。" }.joined(separator: "\n")
    view.string = original
    scroll.documentView = view
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.orderOut(nil) }

    let manager = try XCTUnwrap(view.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    scroll.layoutSubtreeIfNeeded()
    manager.ensureLayout(for: manager.documentRange)
    let originalHeight = view.frame.height
    XCTAssertGreaterThan(originalHeight, scroll.contentView.bounds.height)
    XCTAssertNotNil(scroll.cachedDocumentHeightForTesting)

    let storage = try XCTUnwrap(view.textStorage)
    let end = NSRange(location: storage.length, length: 0)
    storage.replaceCharacters(in: end, with: "\n" + appended)
    manager.ensureLayout(for: manager.documentRange)
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(10))
      manager.ensureLayout(for: manager.documentRange)
      scroll.layoutSubtreeIfNeeded()
      if view.frame.height > originalHeight + 100 { break }
    }
    scroll.layoutSubtreeIfNeeded()
    manager.ensureLayout(for: manager.documentRange)
    let appendedHeight = view.frame.height
    XCTAssertGreaterThan(appendedHeight, originalHeight + 100)
    XCTAssertEqual(view.string, original + "\n" + appended)

    let appendedSuffix = "\n" + appended
    let deleteRange = NSRange(
      location: (original as NSString).length,
      length: (appendedSuffix as NSString).length)
    storage.replaceCharacters(in: deleteRange, with: "")
    manager.ensureLayout(for: manager.documentRange)
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(10))
      manager.ensureLayout(for: manager.documentRange)
      scroll.layoutSubtreeIfNeeded()
      if abs(view.frame.height - originalHeight) < 1 { break }
    }
    scroll.layoutSubtreeIfNeeded()
    manager.ensureLayout(for: manager.documentRange)
    XCTAssertEqual(view.frame.height, originalHeight, accuracy: 1)
    XCTAssertEqual(view.string, original)
  }

  func testDeletedTailDoesNotRetainAnOversizedUsageBoundsEstimate() throws {
    for (suffix, spacing) in [("", CGFloat(0)), ("\n", 0), ("\n", 11)] {
      let manager = StaleUsageBoundsTextLayoutManager()
      let content = NSTextContentStorage()
      content.addTextLayoutManager(manager)
      let container = NSTextContainer(
        size: NSSize(width: 413, height: CGFloat.greatestFiniteMagnitude))
      manager.textContainer = container
      let view = NSTextView(
        frame: NSRect(x: 0, y: 0, width: 445, height: 2_000), textContainer: container)
      XCTAssertTrue(view.textLayoutManager === manager)
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      view.textContainerInset = NSSize(width: 16, height: 16)
      let paragraph = NSMutableParagraphStyle()
      paragraph.paragraphSpacing = spacing
      paragraph.paragraphSpacingBefore = spacing > 0 ? 7 : 0
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph,
      ]
      let original = (1...36).map { "原始正文第 \($0) 行。" }.joined(separator: "\n") + suffix
      let storage = try XCTUnwrap(content.textStorage)
      storage.setAttributedString(NSAttributedString(string: original, attributes: attributes))
      let originalContent = NSAttributedString(attributedString: storage)
      manager.ensureLayout(for: manager.documentRange)
      let baselineHeight = manager.usageBoundsForTextContainer.maxY + 32
      XCTAssertEqual(
        try XCTUnwrap(MarkdownEditorDocumentGeometry.height(in: view)), baselineHeight, accuracy: 1)

      let appended = "\n" + (1...24).map { "追加正文第 \($0) 行。" }.joined(separator: "\n")
      storage.append(NSAttributedString(string: appended, attributes: attributes))
      manager.ensureLayout(for: manager.documentRange)
      let expandedBounds = manager.usageBoundsForTextContainer
      XCTAssertGreaterThan(expandedBounds.maxY + 32, baselineHeight + 100)
      storage.replaceCharacters(
        in: NSRange(location: (original as NSString).length, length: (appended as NSString).length),
        with: "")
      manager.ensureLayout(for: manager.documentRange)
      XCTAssertTrue(storage.isEqual(to: originalContent))
      let deletedUsageHeight = manager.usageBoundsForTextContainer.maxY + 32
      var terminalGeometry = "unavailable"
      manager.enumerateTextLayoutFragments(
        from: manager.documentRange.endLocation, options: [.reverse]
      ) { fragment in
        terminalGeometry =
          "frame=\(fragment.layoutFragmentFrame), top=\(fragment.topMargin), bottom=\(fragment.bottomMargin)"
        return false
      }
      let deletedHeight = try XCTUnwrap(MarkdownEditorDocumentGeometry.height(in: view))
      XCTAssertLessThan(deletedHeight + 100, expandedBounds.maxY + 32)
      // Keep real storage/fragment layout, but simulate an older TextKit
      // usage estimate that still reports the removed paragraphs. Compare
      // the same post-edit layout before/after injection, independently of
      // any pre-edit empty-paragraph margin assumptions.
      manager.reportedUsageBounds = expandedBounds
      let frozenHeight = try XCTUnwrap(MarkdownEditorDocumentGeometry.height(in: view))
      print(
        "stale-usage regression: newline=\(!suffix.isEmpty), spacing=\(spacing), initial=\(baselineHeight), deleted=\(deletedHeight), usage=\(deletedUsageHeight), frozen=\(frozenHeight), \(terminalGeometry)"
      )
      XCTAssertEqual(
        frozenHeight, deletedHeight, accuracy: 1)
      XCTAssertEqual(view.string, original)
    }
  }

  func testInitialScrollExtentWaitsForViewportAndUpdatesWhenDocumentIsReplaced() throws {
    let longBody = (0..<240).map { "第 \($0) 段：正文首次打开即可滚动。" }.joined(separator: "\n\n")
    let scroll = MarkdownEditorScrollView(frame: .zero)
    scroll.contentView = MarkdownFrontMatterClipView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let view = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    view.string = longBody
    view.font = NSFont.systemFont(ofSize: 16)
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    scroll.documentView = view
    scroll.needsLayout = true
    scroll.layoutSubtreeIfNeeded()
    XCTAssertNil(
      scroll.cachedDocumentHeightForTesting, "A zero-sized viewport must not cache height.")

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.orderOut(nil) }
    for source in [longBody + "😀\n", "", "短文章😀", longBody] {
      view.string = source
      view.setSelectedRange(NSRange(location: 0, length: 0))
      scroll.invalidateDocumentHeight(immediately: true)
      scroll.layoutSubtreeIfNeeded()
      let viewportHeight = scroll.contentView.bounds.height
      XCTAssertGreaterThan(viewportHeight, 100)
      if source.hasPrefix(longBody) {
        XCTAssertGreaterThan(view.frame.height, viewportHeight * 2)
        var proposedBounds = scroll.contentView.bounds
        proposedBounds.origin.y = viewportHeight
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposedBounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100)
      } else {
        XCTAssertEqual(view.frame.height, viewportHeight, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        var proposedBounds = scroll.contentView.bounds
        proposedBounds.origin.y = viewportHeight
        let constrainedBounds = scroll.contentView.constrainBoundsRect(proposedBounds)
        XCTAssertEqual(constrainedBounds.minY, 0, accuracy: 1)
        scroll.contentView.scroll(to: constrainedBounds.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
      }
      XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
      XCTAssertEqual(view.string, source)
    }
  }

  func testTogglingArticleInformationPreservesAScrolledBodyAndSelection() throws {
    let prefix = "---\ntitle: 标题\ntags: [写作]\n---\n\n"
    let body = (1...100).map { "第 \($0) 段正文。" }.joined(separator: "\n\n")
    let source = prefix + body
    let scroll = MarkdownEditorScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    scroll.contentView = MarkdownFrontMatterClipView()
    let view = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    view.string = source
    scroll.documentView = view
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.orderOut(nil) }
    let bodyOffset = (prefix as NSString).length
    scroll.foldedFrontMatterBodyOffset = bodyOffset
    scroll.layoutSubtreeIfNeeded()

    let selection = (source as NSString).range(of: "第 30 段正文。")
    view.setSelectedRange(selection)
    let selectedLineY = try XCTUnwrap(
      MarkdownFrontMatterFoldGeometry.bodyOrigin(at: selection.location, in: view))
    scroll.invalidateDocumentHeight(immediately: true)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: selectedLineY - 80))
    scroll.reflectScrolledClipView(scroll.contentView)
    let originalOrigin = scroll.contentView.bounds.minY
    let clip = try XCTUnwrap(scroll.contentView as? MarkdownFrontMatterClipView)
    XCTAssertGreaterThan(originalOrigin, clip.hiddenPrefixHeight + 100)

    for offset in [0, bodyOffset, 0, bodyOffset] {
      // The SwiftUI gutter reduces only the folded editor's viewport height.
      scroll.setFrameSize(NSSize(width: 640, height: offset == 0 ? 480 : 464))
      scroll.foldedFrontMatterBodyOffset = offset
      scroll.layoutSubtreeIfNeeded()
      XCTAssertEqual(scroll.contentView.bounds.minY, originalOrigin, accuracy: 1)
      XCTAssertEqual(view.selectedRange(), selection)
      XCTAssertEqual(view.string, source)
    }
  }

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

  func testFoldClipKeepsHiddenPrefixWhenRestoredOriginBypassesConstraint() {
    let clip = MarkdownFrontMatterClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))

    clip.hiddenPrefixHeight = 204
    XCTAssertEqual(clip.bounds.origin.y, 204, "enabling the fold hides the prefix")

    // Session restore and typewriter scrolling set the origin directly.
    clip.scroll(to: .zero)
    XCTAssertEqual(clip.bounds.origin.y, 204)
    clip.setBoundsOrigin(NSPoint(x: 0, y: 12))
    XCTAssertEqual(clip.bounds.origin.y, 204)
    clip.scroll(to: NSPoint(x: 0, y: 320))
    XCTAssertEqual(clip.bounds.origin.y, 320, "scrolling within the body is unchanged")

    clip.hiddenPrefixHeight = 0
    clip.scroll(to: .zero)
    XCTAssertEqual(clip.bounds.origin.y, 0, "expanding metadata allows the top again")
  }

  func testFoldMeasurementWaitsForASizedViewport() {
    XCTAssertFalse(MarkdownEditorScrollView.canMeasureFrontMatterFold(viewportSize: .zero))
    XCTAssertFalse(
      MarkdownEditorScrollView.canMeasureFrontMatterFold(
        viewportSize: NSSize(width: 640, height: 0)))
    XCTAssertTrue(
      MarkdownEditorScrollView.canMeasureFrontMatterFold(
        viewportSize: NSSize(width: 640, height: 480)))
  }
}

private final class StaleUsageBoundsTextLayoutManager: NSTextLayoutManager {
  var reportedUsageBounds: CGRect?

  override var usageBoundsForTextContainer: CGRect {
    reportedUsageBounds ?? super.usageBoundsForTextContainer
  }
}
