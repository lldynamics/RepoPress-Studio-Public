import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownInlineFormulaLayoutTests: MarkdownEditorAppKitInteractionTestCase {
  func testNarrowViewportRendersCompleteFormulaCrossingItsBottomEdge() throws {
    let formula =
      "$$\n" + (0..<30).map { "a_\($0) + b_\($0) = c_\($0)" }.joined(separator: "\n")
      + "\n$$"
    let source = "Introduction\n\n" + formula + "\n\nEOF\n\n$$offscreen$$"
    let coordinator = makeCoordinator(source: source, bodyMarkdown: source, bodyUTF16Offset: 0)
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 240, height: 3_000),
      containerSize: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.string = source
    let fullRange = NSRange(location: 0, length: source.utf16.count)
    textView.textStorage?.setAttributes(
      coordinator.syntaxHighlightPalette.defaultAttributes, range: fullRange)
    let selection = NSRange(location: source.utf16.count, length: 0)
    textView.setSelectedRange(selection)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
    scrollView.documentView = textView
    let window = NSWindow(
      contentRect: scrollView.frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    window.contentView = scrollView
    window.orderFront(nil)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    defer {
      coordinator.clearInlineAttachmentDrawings(in: textView)
      window.orderOut(nil)
    }

    let viewport = try XCTUnwrap(MarkdownTextKit2RangeAdapter.visibleRange(in: textView))
    let formulaRange = (source as NSString).range(of: formula)
    XCTAssertGreaterThan(NSIntersectionRange(viewport, formulaRange).length, 0)
    XCTAssertLessThan(NSMaxRange(viewport), NSMaxRange(formulaRange))

    coordinator.applyInlineAttachmentDrawings(in: textView, applicationRange: viewport)

    let key = "attachment:\(formulaRange.location)"
    let drawing = try XCTUnwrap(coordinator.inlineAttachmentDrawingDescriptors[key])
    XCTAssertEqual(drawing.documentRange, formulaRange)
    XCTAssertGreaterThan(drawing.frame.height, scrollView.contentSize.height)
    XCTAssertTrue(scrollView.documentVisibleRect.intersects(drawing.frame))
    XCTAssertEqual(coordinator.inlineAttachmentDrawingDescriptors.count, 1)
    XCTAssertEqual(textView.string, source)
    XCTAssertEqual(textView.selectedRange(), selection)

    coordinator.applyInlineAttachmentDrawings(
      in: textView, applicationRange: viewport, preservingExisting: true)
    XCTAssertEqual(coordinator.inlineAttachmentDrawingDescriptors[key], drawing)
  }

  func testFormulaCrossingBothViewportEdgesRendersAndRemainsEditableWhenSelected() throws {
    let formula = "$$\na + b\nc + d\ne + f\n$$"
    let source = "before\n" + formula + "\n\nafter"
    let coordinator = makeCoordinator(source: source, bodyMarkdown: source, bodyUTF16Offset: 0)
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 240, height: 480),
      containerSize: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = source
    let fullRange = NSRange(location: 0, length: source.utf16.count)
    textView.textStorage?.setAttributes(
      coordinator.syntaxHighlightPalette.defaultAttributes, range: fullRange)
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    let middleRange = (source as NSString).range(of: "c + d")
    let formulaRange = (source as NSString).range(of: formula)
    let key = "attachment:\(formulaRange.location)"

    coordinator.applyInlineAttachmentDrawings(in: textView, applicationRange: middleRange)
    XCTAssertEqual(coordinator.inlineAttachmentDrawingDescriptors[key]?.documentRange, formulaRange)
    XCTAssertNotNil(coordinator.inlineAttachmentGeometryReservations[key])

    let selection = NSRange(location: middleRange.location + 1, length: 0)
    textView.setSelectedRange(selection)
    coordinator.applyInlineAttachmentDrawings(
      in: textView, applicationRange: middleRange, preservingExisting: true)
    XCTAssertTrue(coordinator.inlineAttachmentDrawingDescriptors.isEmpty)
    XCTAssertTrue(coordinator.inlineAttachmentGeometryReservations.isEmpty)
    XCTAssertEqual(textView.string, source)
    XCTAssertEqual(textView.selectedRange(), selection)
  }

  func testDisplayFormulaSharesHeightAcrossItsActualSourceParagraphs() {
    let inlineDelimiters = MarkdownInlineAttachmentDrawingLayout.formulaMinimumLineHeight(
      presentationHeight: 36,
      sourceText: "$$E = mc^2$$"
    )
    let separateDelimiters = MarkdownInlineAttachmentDrawingLayout.formulaMinimumLineHeight(
      presentationHeight: 36,
      sourceText: "$$\nE = mc^2\n$$"
    )

    XCTAssertEqual(inlineDelimiters, 44)
    XCTAssertEqual(separateDelimiters, 24)
    XCTAssertLessThan(separateDelimiters * 3, 100)
  }

  func testTrailingNewlineAndCRLFDoNotCreateExtraSourceParagraphs() {
    for source in ["$$\nx\n$$", "$$\nx\n$$\n", "$$\r\nx\r\n$$\r\n"] {
      XCTAssertEqual(
        MarkdownInlineAttachmentDrawingLayout.formulaMinimumLineHeight(
          presentationHeight: 100,
          sourceText: source
        ),
        36
      )
    }
  }

  func testWrappedSourceLinesShareTallFormulaReservationWithoutAHeightCap() {
    let height = MarkdownInlineAttachmentDrawingLayout.formulaMinimumLineHeight(
      presentationHeight: 300,
      sourceText: "$$long formula$$",
      laidOutSourceLineCount: 10
    )

    XCTAssertEqual(height, 31)
    XCTAssertGreaterThanOrEqual(height * 10, 300)
  }

  func testDisplayFormulaPreservesLineBreaksAndMeasuresEveryLine() {
    let source = "a + b\r\nc + d\ne + f\ng + h"
    let rendered = MarkdownInlineFormulaPresentation.attributedString(for: source, fontSize: 19)
    let size = MarkdownInlineFormulaPresentation.size(
      for: source, displayMode: .display, fontSize: 19, availableWidth: 320)
    let singleLine = MarkdownInlineFormulaPresentation.size(
      for: "a + b", displayMode: .display, fontSize: 19, availableWidth: 320)

    XCTAssertEqual(rendered.string, "a + b\nc + d\ne + f\ng + h")
    XCTAssertGreaterThan(size.height, singleLine.height * 2)
  }

  func testNarrowFormulaGrowsVerticallyInsteadOfTruncating() {
    let source = String(repeating: "x^2 + y_i + ", count: 30) + "z"
    let wide = MarkdownInlineFormulaPresentation.size(
      for: source, displayMode: .display, fontSize: 19, availableWidth: 640)
    let narrow = MarkdownInlineFormulaPresentation.size(
      for: source, displayMode: .display, fontSize: 19, availableWidth: 200)

    XCTAssertEqual(narrow.width, 200)
    XCTAssertGreaterThan(narrow.height, wide.height)
    XCTAssertGreaterThan(narrow.height, 100)
  }

  func testNativeFormulaViewHasNoBorderOrTwoLineLimit() throws {
    let view = MarkdownInlineAttachmentOverlayView(
      frame: NSRect(x: 0, y: 0, width: 200, height: 200)
    )
    view.configure(.formula(source: "a\nb\nc", displayMode: .display, fontSize: 19))
    view.layoutSubtreeIfNeeded()
    let label = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)

    XCTAssertEqual(view.layer?.borderWidth, 0)
    XCTAssertEqual(label.maximumNumberOfLines, 0)
    XCTAssertEqual(label.lineBreakMode, .byCharWrapping)
    XCTAssertEqual(label.attributedStringValue.string, "a\nb\nc")
  }
}
