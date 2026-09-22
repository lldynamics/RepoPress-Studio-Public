import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class UIOptimizationEditorViewportTests: XCTestCase {
  func testNarrowingEditorKeepsVisibleParagraph() throws {
    try verifyResize(from: 1000, to: 580)
  }

  func testInspectorWidthChangeKeepsViewportWhenBodyWidthIsUnchanged() throws {
    try verifyResize(from: 1320, to: 1000)
  }

  func testWideningEditorKeepsVisibleParagraph() throws {
    try verifyResize(from: 580, to: 1000)
  }

  func testReflowAtTopKeepsTheDocumentScrollable() throws {
    try verifyResize(from: 1000, to: 580, paragraph: 0)
  }

  func testLiveResizeDefersContainerReflowUntilTheFinalWidthAndRestoresAnchor() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let initialContainerWidth = try XCTUnwrap(fixture.textView.textContainer?.containerSize.width)
    let initialSelection = fixture.textView.selectedRange()
    let initialText = fixture.textView.string

    fixture.scrollView.viewWillStartLiveResize()
    for width in [940, 820, 700, 580, 700, 580] {
      fixture.scrollView.setFrameSize(NSSize(width: width, height: 400))
      fixture.scrollView.layout()
      XCTAssertEqual(
        try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
        initialContainerWidth,
        accuracy: 0.5
      )
    }

    fixture.scrollView.viewDidEndLiveResize()
    fixture.scrollView.layout()

    let finalWidth = try XCTUnwrap(fixture.textView.textContainer?.containerSize.width)
    let relocatedRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: fixture.anchor, in: fixture.textView))
    XCTAssertEqual(finalWidth, 548, accuracy: 0.5)
    XCTAssertEqual(
      relocatedRect.minY,
      fixture.scrollView.contentView.bounds.minY,
      accuracy: 40
    )
    XCTAssertEqual(fixture.textView.selectedRange(), initialSelection)
    XCTAssertEqual(fixture.textView.string, initialText)
  }

  func testLiveResizeDropsOutOfRangeAnchorAfterTextMutation() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    fixture.scrollView.viewWillStartLiveResize()
    fixture.scrollView.setFrameSize(NSSize(width: 580, height: 400))
    fixture.scrollView.layout()
    fixture.textView.string = "短文本"
    fixture.textView.setSelectedRange(NSRange(location: 2, length: 0))

    fixture.scrollView.viewDidEndLiveResize()
    fixture.scrollView.layout()

    XCTAssertEqual(fixture.textView.string, "短文本")
    XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertEqual(
      try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
      548,
      accuracy: 0.5
    )
    XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 1)
  }

  func testLiveResizeKeepsTheViewportMovedByTheUserBeforeItEnds() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    fixture.scrollView.viewWillStartLiveResize()
    fixture.scrollView.setFrameSize(NSSize(width: 580, height: 400))
    fixture.scrollView.layout()

    let currentRange = (fixture.textView.string as NSString).range(of: "Paragraph 20:")
    let currentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView)
    )
    fixture.textView.setSelectedRange(currentRange)
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: currentRect.minY))
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)

    fixture.scrollView.viewDidEndLiveResize()
    fixture.scrollView.layout()

    let relocatedRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView)
    )
    XCTAssertEqual(relocatedRect.minY, fixture.scrollView.contentView.bounds.minY, accuracy: 40)
    XCTAssertEqual(fixture.textView.selectedRange(), currentRange)
  }

  func testSameLengthReplacementUsesTheCurrentViewportInsteadOfTheOldAnchor() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let originalLength = fixture.textView.string.utf16.count
    fixture.scrollView.viewWillStartLiveResize()
    fixture.scrollView.setFrameSize(NSSize(width: 580, height: 400))
    fixture.scrollView.layout()
    fixture.textView.string = fixture.textView.string.replacingOccurrences(
      of: "Paragraph", with: "Rewritten"
    )
    XCTAssertEqual(fixture.textView.string.utf16.count, originalLength)
    let manager = try XCTUnwrap(fixture.textView.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    fixture.scrollView.invalidateDocumentHeight(immediately: true)
    fixture.scrollView.layout()
    let currentRange = (fixture.textView.string as NSString).range(of: "Rewritten 20:")
    let rect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView)
    )
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: rect.minY))
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
    let selection = fixture.textView.selectedRange()
    fixture.scrollView.viewDidEndLiveResize()
    fixture.scrollView.layout()
    let after = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView)
    )
    XCTAssertEqual(after.minY, fixture.scrollView.contentView.bounds.minY, accuracy: 40)
    XCTAssertEqual(fixture.textView.selectedRange(), selection)
  }

  func testLiveResizeRoundTripLeavesTheOriginalContainerAndSelectionIntact() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let initialContainerWidth = try XCTUnwrap(fixture.textView.textContainer?.containerSize.width)
    let initialSelection = fixture.textView.selectedRange()

    fixture.scrollView.viewWillStartLiveResize()
    for width in [940, 820, 700, 580, 700, 820, 940, 1000] {
      fixture.scrollView.setFrameSize(NSSize(width: width, height: 400))
      fixture.scrollView.layout()
      XCTAssertEqual(
        try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
        initialContainerWidth,
        accuracy: 0.5
      )
    }
    fixture.scrollView.viewDidEndLiveResize()
    fixture.scrollView.layout()

    XCTAssertEqual(
      try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
      initialContainerWidth,
      accuracy: 0.5
    )
    XCTAssertEqual(fixture.textView.selectedRange(), initialSelection)
  }

  func testOrdinaryWidthBurstDefersIntermediateContainerReflows() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let initialContainerWidth = try XCTUnwrap(fixture.textView.textContainer?.containerSize.width)
    let initialSelection = fixture.textView.selectedRange()
    let initialText = fixture.textView.string

    for width in [940, 820, 700, 580, 700, 580] {
      fixture.scrollView.setFrameSize(NSSize(width: width, height: 400))
      fixture.scrollView.layout()
      XCTAssertEqual(
        try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
        initialContainerWidth,
        accuracy: 0.5
      )
    }

    fixture.scrollView.completeDeferredFrameReflow()

    let relocatedRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: fixture.anchor, in: fixture.textView)
    )
    XCTAssertEqual(
      try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
      548,
      accuracy: 0.5
    )
    XCTAssertEqual(relocatedRect.minY, fixture.scrollView.contentView.bounds.minY, accuracy: 40)
    XCTAssertGreaterThan(fixture.textView.frame.height, fixture.scrollView.contentSize.height)
    XCTAssertEqual(fixture.textView.selectedRange(), initialSelection)
    XCTAssertEqual(fixture.textView.string, initialText)
  }

  func testDeferredFrameReflowKeepsScrollInputDuringTheQuietPeriod() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    fixture.scrollView.setFrameSize(NSSize(width: 580, height: 400))
    fixture.scrollView.layout()
    let currentRange = (fixture.textView.string as NSString).range(of: "Paragraph 20:")
    let currentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView))
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: currentRect.minY))
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
    // A later width update must preserve the fact that the user moved the viewport.
    fixture.scrollView.setFrameSize(NSSize(width: 620, height: 400))
    fixture.scrollView.layout()
    fixture.scrollView.completeDeferredFrameReflow()
    let after = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: currentRange, in: fixture.textView))
    XCTAssertEqual(after.minY, fixture.scrollView.contentView.bounds.minY, accuracy: 40)
  }

  func testOrdinaryWidthBurstCommitsImmediatelyAfterSameLengthTextMutation() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let originalLength = fixture.textView.string.utf16.count
    fixture.scrollView.setFrameSize(NSSize(width: 580, height: 400))
    fixture.scrollView.layout()
    fixture.textView.string = fixture.textView.string.replacingOccurrences(
      of: "Paragraph", with: "Rewritten"
    )
    fixture.scrollView.contentView.scroll(to: .zero)
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
    fixture.scrollView.invalidateDocumentHeight(immediately: true)
    fixture.scrollView.layout()

    XCTAssertEqual(
      try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
      548,
      accuracy: 0.5
    )
    XCTAssertEqual(fixture.textView.string.utf16.count, originalLength)
    XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 1)
  }

  func testPreferredBodyWidthChangeKeepsVisibleParagraph() throws {
    let fixture = try makeFixture(width: 1000, paragraph: 70)
    let initialSelection = fixture.textView.selectedRange()
    let initialContainerWidth = try XCTUnwrap(fixture.textView.textContainer?.containerSize.width)
    let updatedPreferredWidth = max(400, initialContainerWidth - 120)

    fixture.scrollView.preferredBodyWidth = updatedPreferredWidth
    fixture.scrollView.layout()

    let relocatedRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: fixture.anchor, in: fixture.textView))
    XCTAssertEqual(
      try XCTUnwrap(fixture.textView.textContainer?.containerSize.width),
      updatedPreferredWidth,
      accuracy: 0.5
    )
    XCTAssertEqual(
      relocatedRect.minY,
      fixture.scrollView.contentView.bounds.minY,
      accuracy: 40
    )
    XCTAssertEqual(fixture.textView.selectedRange(), initialSelection)
  }

  func testSelectionRevealSurvivesNativeScrollAndLaterParagraphReflow() throws {
    let fixture = try makeFixture(width: 800, paragraph: 159)
    let window = makeFocusedWindow(for: fixture.scrollView, textView: fixture.textView)
    defer { window.orderOut(nil) }
    fixture.scrollView.invalidateDocumentHeight(immediately: true, revealingSelection: true)
    // Native caret scrolling can change the clip origin before our next layout.
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    fixture.scrollView.layout()
    try assertSelectionVisible(in: fixture.textView, scrollView: fixture.scrollView)

    // A later attachment paragraph-height update does not carry a new input
    // event. The existing selection must still be revealed after frame growth.
    let firstParagraph = (fixture.textView.string as NSString).paragraphRange(
      for: NSRange(location: 0, length: 1))
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = 500
    fixture.textView.textStorage?.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
    let manager = try XCTUnwrap(fixture.textView.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    let previousHeight = fixture.textView.frame.height
    fixture.scrollView.invalidateDocumentHeight(immediately: true)
    fixture.scrollView.layout()
    XCTAssertGreaterThan(fixture.textView.frame.height, previousHeight)
    try assertSelectionVisible(in: fixture.textView, scrollView: fixture.scrollView)
  }

  func testViewportHeightShrinkKeepsActiveSelectionVisible() throws {
    let fixture = try makeFixture(width: 800, paragraph: 159)
    let window = makeFocusedWindow(for: fixture.scrollView, textView: fixture.textView)
    defer { window.orderOut(nil) }
    fixture.scrollView.invalidateDocumentHeight(immediately: true, revealingSelection: true)
    fixture.scrollView.layout()
    let rect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: fixture.textView.selectedRange(), in: fixture.textView)
    )
    fixture.scrollView.contentView.scroll(
      to: NSPoint(x: 0, y: max(0, rect.maxY - fixture.scrollView.contentSize.height)))
    try assertSelectionVisible(in: fixture.textView, scrollView: fixture.scrollView)

    // A save-error banner consumes editor height without changing the text or
    // container width, so the cached document height remains valid.
    let documentHeight = fixture.textView.frame.height
    window.setContentSize(NSSize(width: 800, height: 240))
    window.layoutIfNeeded()
    fixture.scrollView.layout()
    XCTAssertEqual(fixture.textView.frame.height, documentHeight, accuracy: 1)
    try assertSelectionVisible(in: fixture.textView, scrollView: fixture.scrollView)
  }

  func testLiveScrollAndFocusLossSupersedeSelectionReveal() throws {
    let fixture = try makeFixture(width: 800, paragraph: 159)
    let window = makeFocusedWindow(for: fixture.scrollView, textView: fixture.textView)
    defer { window.orderOut(nil) }
    fixture.scrollView.invalidateDocumentHeight(immediately: true, revealingSelection: true)
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.scrollView)
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    fixture.scrollView.layout()
    XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 100, accuracy: 1)

    fixture.scrollView.invalidateDocumentHeight(immediately: true, revealingSelection: true)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
    fixture.scrollView.layout()
    XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 200, accuracy: 1)
  }

  private func makeFocusedWindow(for scrollView: MarkdownEditorScrollView, textView: NSTextView)
    -> NSWindow
  {
    // The command-line test host cannot reliably activate a key window. This
    // fixture controls only that focus input; production focus is checked in
    // the packaged app, while all text layout and scrolling here remain AppKit.
    let window = SelectionRevealTestWindow(
      contentRect: scrollView.frame, styleMask: .titled, backing: .buffered, defer: false)
    window.contentView = scrollView
    window.layoutIfNeeded()
    scrollView.layout()
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layout()
    XCTAssertTrue(window.makeFirstResponder(textView))
    return window
  }

  private func assertSelectionVisible(
    in textView: NSTextView, scrollView: NSScrollView, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let rect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: textView.selectedRange(), in: textView), file: file,
      line: line)
    XCTAssertTrue(scrollView.documentVisibleRect.intersects(rect), file: file, line: line)
  }

  private func verifyResize(
    from initialWidth: CGFloat, to finalWidth: CGFloat, paragraph: Int = 70
  ) throws {
    _ = NSApplication.shared
    let scrollView = MarkdownEditorScrollView(
      frame: NSRect(x: 0, y: 0, width: initialWidth, height: 400)
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 820, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.font = .systemFont(ofSize: 14)
    textView.string = (0..<160).map { index in
      "Paragraph \(index): "
        + String(repeating: "A long paragraph keeps the same reading anchor. ", count: 5)
    }.joined(separator: "\n\n")
    textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: 400)
    scrollView.documentView = textView
    let manager = try XCTUnwrap(textView.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    scrollView.layout()
    manager.ensureLayout(for: manager.documentRange)
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layout()
    let source = textView.string as NSString
    let anchor = source.range(of: "Paragraph \(paragraph):")
    let rect = try XCTUnwrap(MarkdownTextKit2RangeAdapter.rect(for: anchor, in: textView))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: paragraph == 0 ? 0 : rect.minY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    if paragraph > 0 { XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 400) }
    let initialSelection = textView.selectedRange()
    let initialText = textView.string
    for width in [finalWidth, initialWidth, finalWidth] {
      scrollView.setFrameSize(NSSize(width: width, height: 400))
      scrollView.layout()
      scrollView.layout()
      let relocatedRect = try XCTUnwrap(
        MarkdownTextKit2RangeAdapter.rect(for: anchor, in: textView))
      XCTAssertGreaterThan(textView.frame.height, 400)
      if paragraph > 0 {
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 400)
        XCTAssertEqual(relocatedRect.minY, scrollView.contentView.bounds.minY, accuracy: 40)
      } else {
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1)
      }
      XCTAssertEqual(textView.selectedRange(), initialSelection)
      XCTAssertEqual(textView.string, initialText)
    }
  }

  private func makeFixture(
    width: CGFloat,
    paragraph: Int
  ) throws -> (
    scrollView: MarkdownEditorScrollView, textView: DroppableMarkdownTextView, anchor: NSRange
  ) {
    _ = NSApplication.shared
    let scrollView = MarkdownEditorScrollView(
      frame: NSRect(x: 0, y: 0, width: width, height: 400)
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 820, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.font = .systemFont(ofSize: 14)
    textView.string = (0..<160).map { index in
      "Paragraph \(index): "
        + String(repeating: "A long paragraph keeps the same reading anchor. ", count: 5)
    }.joined(separator: "\n\n")
    textView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    scrollView.documentView = textView
    let manager = try XCTUnwrap(textView.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    scrollView.layout()
    manager.ensureLayout(for: manager.documentRange)
    scrollView.invalidateDocumentHeight(immediately: true)
    scrollView.layout()
    let anchor = (textView.string as NSString).range(of: "Paragraph \(paragraph):")
    let rect = try XCTUnwrap(MarkdownTextKit2RangeAdapter.rect(for: anchor, in: textView))
    textView.setSelectedRange(anchor)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: rect.minY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    return (scrollView, textView, anchor)
  }
}

@MainActor
private final class SelectionRevealTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
