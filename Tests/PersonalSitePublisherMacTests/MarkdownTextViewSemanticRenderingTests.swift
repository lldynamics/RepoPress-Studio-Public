import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownTextViewSemanticRenderingTests: XCTestCase {
  func testInactiveInlineMarkersAreVisuallyHidden() throws {
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration()
    )

    XCTAssertEqual(
      try XCTUnwrap(palette.inactiveMarkerAttributes[.foregroundColor] as? NSColor),
      .clear
    )
    XCTAssertEqual(
      try XCTUnwrap(palette.inactiveMarkerAttributes[.underlineColor] as? NSColor),
      .clear
    )
    let markerFont = palette.inactiveMarkerLayoutFont
    let normalWidth = NSAttributedString(
      string: "**",
      attributes: [.font: palette.baseFont]
    ).size().width
    let concealedWidth = NSAttributedString(
      string: "**",
      attributes: [.font: palette.inactiveMarkerLayoutFont]
    ).size().width

    XCTAssertLessThan(markerFont.pointSize, 0.1)
    XCTAssertLessThan(concealedWidth, normalWidth * 0.01)
    XCTAssertGreaterThan(palette.inactiveTaskMarkerLayoutFont.pointSize, markerFont.pointSize)
    XCTAssertLessThan(palette.inactiveTaskMarkerLayoutFont.pointSize, palette.baseFont.pointSize)
  }

  func testPaintedTaskCheckboxReportsToggledStateWithoutChildView() throws {
    var toggledState: Bool?
    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    let markerRange = NSRange(location: 0, length: 6)
    let frame = NSRect(x: 8, y: 8, width: 18, height: 18)
    textView.markdownBlockMarkerTaskToggleHandler = { _, checked in
      toggledState = checked
    }
    textView.markdownBlockMarkerDrawings = [
      MarkdownBlockMarkerDrawing(
        marker: MarkdownSyntaxMarker(
          range: markerRange,
          presentation: .taskList(isChecked: false)
        ),
        frame: frame,
        taskHitFrame: frame
      )
    ]
    let checkbox = try XCTUnwrap(
      textView.markdownTaskCheckboxAccessibilityElements.first
    )

    XCTAssertTrue(textView.subviews.isEmpty)
    XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
    XCTAssertEqual(checkbox.accessibilityValue() as? NSNumber, NSNumber(value: false))
    XCTAssertTrue(checkbox.performAccessibilityPress())
    XCTAssertEqual(toggledState, true)
  }

  func testHeadingPaletteUsesDescendingNativeFontSizes() throws {
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration(fontSize: 16)
    )
    let styles: [MarkdownSyntaxHighlightStyle] = [
      .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
    ]
    let pointSizes = try styles.map { style in
      try XCTUnwrap(palette.styleAttributes[style]?[.font] as? NSFont).pointSize
    }

    XCTAssertEqual(pointSizes, pointSizes.sorted(by: >))
    XCTAssertGreaterThan(pointSizes[0], palette.baseFont.pointSize)
    XCTAssertEqual(pointSizes[5], palette.baseFont.pointSize, accuracy: 0.01)
  }

  func testLayoutAttributeSynchronizationWritesHeadingMetricsToStorageOnlyWhereNeeded() throws {
    let source = "## Title\nBody\nCard"
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration(fontSize: 16)
    )
    let defaultParagraphStyle = try XCTUnwrap(
      palette.defaultAttributes[.paragraphStyle] as? NSParagraphStyle
    )
    let storage = NSMutableAttributedString(string: source, attributes: palette.defaultAttributes)
    let cardRange = (source as NSString).range(of: "Card")
    let cardParagraphStyle = NSMutableParagraphStyle()
    cardParagraphStyle.minimumLineHeight = 120
    storage.addAttribute(.paragraphStyle, value: cardParagraphStyle, range: cardRange)
    let fullRange = NSRange(location: 0, length: storage.length)
    let headingRange = (source as NSString).range(of: "## Title")
    let markerRange = NSRange(location: 0, length: 3)
    storage.addAttribute(.font, value: palette.inactiveMarkerLayoutFont, range: markerRange)
    let headingSnapshot = MarkdownSyntaxHighlightSnapshot(
      range: fullRange,
      runs: [MarkdownSyntaxHighlightRun(style: .heading2, range: headingRange)]
    )

    func synchronize(_ snapshot: MarkdownSyntaxHighlightSnapshot) -> Int {
      MarkdownTextViewSemanticAttributeApplier.synchronizeLayoutAttributes(
        snapshot,
        in: storage,
        within: fullRange,
        excluding: [markerRange],
        defaultAttributes: palette.defaultAttributes,
        styleAttributes: palette.styleAttributes
      )
    }

    XCTAssertGreaterThan(synchronize(headingSnapshot), 0)
    let headingFont = try XCTUnwrap(palette.styleAttributes[.heading2]?[.font] as? NSFont)
    let titleLocation = (source as NSString).range(of: "Title").location
    XCTAssertEqual(
      storage.attribute(.font, at: titleLocation, effectiveRange: nil) as? NSFont,
      headingFont
    )
    XCTAssertEqual(
      storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
      palette.inactiveMarkerLayoutFont,
      "Collapsed markers keep their compact layout font."
    )
    XCTAssertEqual(
      storage.attribute(.paragraphStyle, at: titleLocation, effectiveRange: nil)
        as? NSParagraphStyle,
      palette.styleAttributes[.heading2]?[.paragraphStyle] as? NSParagraphStyle
    )
    XCTAssertEqual(synchronize(headingSnapshot), 0, "An unchanged repaint must not touch storage.")

    XCTAssertGreaterThan(
      synchronize(MarkdownSyntaxHighlightSnapshot(range: fullRange, runs: [])),
      0
    )
    XCTAssertEqual(
      storage.attribute(.font, at: titleLocation, effectiveRange: nil) as? NSFont,
      palette.baseFont
    )
    XCTAssertEqual(
      storage.attribute(.paragraphStyle, at: titleLocation, effectiveRange: nil)
        as? NSParagraphStyle,
      defaultParagraphStyle
    )
    XCTAssertEqual(
      storage.attribute(.paragraphStyle, at: cardRange.location, effectiveRange: nil)
        as? NSParagraphStyle,
      cardParagraphStyle,
      "Paragraph styles owned by other features are preserved."
    )
  }

  func testStaleParagraphCleanupStaysWithinPartialRangeAndPreservesOtherStyles() throws {
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration(fontSize: 16)
    )
    let headingStyle = try XCTUnwrap(
      palette.styleAttributes[.heading1]?[.paragraphStyle] as? NSParagraphStyle)
    let secondHeadingStyle = try XCTUnwrap(
      palette.styleAttributes[.heading2]?[.paragraphStyle] as? NSParagraphStyle)
    let defaultStyle = try XCTUnwrap(
      palette.defaultAttributes[.paragraphStyle] as? NSParagraphStyle)
    let storage = NSMutableAttributedString(
      string: "abcdefghij", attributes: palette.defaultAttributes)
    storage.addAttribute(
      .paragraphStyle, value: headingStyle, range: NSRange(location: 0, length: 10))
    let cardStyle = NSMutableParagraphStyle()
    cardStyle.minimumLineHeight = 120
    storage.addAttribute(
      .paragraphStyle, value: cardStyle, range: NSRange(location: 4, length: 1))
    storage.addAttribute(
      .paragraphStyle, value: secondHeadingStyle, range: NSRange(location: 5, length: 2))
    storage.removeAttribute(.paragraphStyle, range: NSRange(location: 7, length: 1))
    let range = NSRange(location: 2, length: 6)
    let snapshot = MarkdownSyntaxHighlightSnapshot(range: range, runs: [])

    for expectedWrites in [2, 0] {
      XCTAssertEqual(
        MarkdownTextViewSemanticAttributeApplier.synchronizeLayoutAttributes(
          snapshot,
          in: storage,
          within: range,
          excluding: [],
          defaultAttributes: palette.defaultAttributes,
          styleAttributes: palette.styleAttributes
        ), expectedWrites)
    }
    for location in [0, 1, 8, 9] {
      XCTAssertEqual(
        storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
        headingStyle)
    }
    for location in [2, 3, 5, 6] {
      XCTAssertEqual(
        storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
        defaultStyle)
    }
    XCTAssertEqual(
      storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle,
      cardStyle)
    XCTAssertNil(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil))
  }

  func testNestedEmphasisPreservesHeadingSizeAndCombinesFontTraits() throws {
    let source = "# ***Title***"
    let storage = NSMutableAttributedString(string: source)
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration(fontSize: 16)
    )
    let emphasizedRange = (source as NSString).range(of: "***Title***")
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: storage.length),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading1,
          range: NSRange(location: 0, length: storage.length)
        ),
        MarkdownSyntaxHighlightRun(style: .bold, range: emphasizedRange),
        MarkdownSyntaxHighlightRun(style: .italic, range: emphasizedRange),
      ]
    )

    MarkdownTextViewSemanticAttributeApplier.apply(
      snapshot,
      to: storage,
      defaultAttributes: palette.defaultAttributes,
      styleAttributes: palette.styleAttributes
    )

    let titleLocation = (source as NSString).range(of: "Title").location
    let titleFont = try XCTUnwrap(
      storage.attribute(.font, at: titleLocation, effectiveRange: nil) as? NSFont
    )
    let headingFont = try XCTUnwrap(
      palette.styleAttributes[.heading1]?[.font] as? NSFont
    )
    XCTAssertEqual(titleFont.pointSize, headingFont.pointSize, accuracy: 0.01)
    XCTAssertTrue(titleFont.fontDescriptor.symbolicTraits.contains(.bold))
    XCTAssertTrue(titleFont.fontDescriptor.symbolicTraits.contains(.italic))
  }

  func testStrikethroughAndInlineCodeUseNativeAttributedStringStyles() {
    let source = "~~gone~~ `code`"
    let storage = NSMutableAttributedString(string: source)
    let palette = MarkdownTextViewSyntaxPalette(
      configuration: MarkdownEditorComfortConfiguration()
    )
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: storage.length),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .strikethrough,
          range: (source as NSString).range(of: "~~gone~~")
        ),
        MarkdownSyntaxHighlightRun(
          style: .inlineCode,
          range: (source as NSString).range(of: "`code`")
        ),
      ]
    )

    MarkdownTextViewSemanticAttributeApplier.apply(
      snapshot,
      to: storage,
      defaultAttributes: palette.defaultAttributes,
      styleAttributes: palette.styleAttributes
    )

    XCTAssertEqual(
      storage.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue
    )
    XCTAssertNotNil(storage.attribute(.foregroundColor, at: 11, effectiveRange: nil))
  }

  func testNativeFormulaPresentationTypesetsScriptsFractionsRootsAndSymbols() throws {
    let rendered = MarkdownInlineFormulaPresentation.attributedString(
      for: #"E = mc^2 + x_{i} + \frac{a}{b} + \sqrt{y} + \alpha"#
    )

    XCTAssertEqual(rendered.string, "E = mc2 + xi + a⁄b + √y + α")
    let source = rendered.string as NSString
    let superscriptLocation = source.range(of: "2").location
    let subscriptLocation = source.range(of: "i").location
    let numeratorLocation = source.range(of: "a⁄b").location
    let denominatorLocation = numeratorLocation + 2

    XCTAssertGreaterThan(
      try XCTUnwrap(
        rendered.attribute(
          .baselineOffset, at: superscriptLocation, effectiveRange: nil) as? CGFloat),
      0
    )
    XCTAssertLessThan(
      try XCTUnwrap(
        rendered.attribute(
          .baselineOffset, at: subscriptLocation, effectiveRange: nil) as? CGFloat),
      0
    )
    XCTAssertGreaterThan(
      try XCTUnwrap(
        rendered.attribute(
          .baselineOffset, at: numeratorLocation, effectiveRange: nil) as? CGFloat),
      0
    )
    XCTAssertLessThan(
      try XCTUnwrap(
        rendered.attribute(
          .baselineOffset, at: denominatorLocation, effectiveRange: nil) as? CGFloat),
      0
    )
  }

  func testNativeFormulaPresentationPreservesUnknownCommands() {
    let rendered = MarkdownInlineFormulaPresentation.attributedString(
      for: #"\operatorname{RepoPress}(x)"#
    )

    XCTAssertTrue(rendered.string.contains(#"\operatorname"#))
    XCTAssertTrue(rendered.string.contains("RepoPress"))
  }

  func testInlineFormulaUsesConfiguredFontSizeAndCompactSourceAnchoredFrame() throws {
    let rendered = MarkdownInlineFormulaPresentation.attributedString(
      for: "E = mc^2",
      fontSize: 16
    )
    let font = try XCTUnwrap(
      rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    )
    XCTAssertEqual(font.pointSize, 16, accuracy: 0.01)

    let frame = try XCTUnwrap(
      MarkdownInlineAttachmentDrawingLayout.frame(
        sourceRect: NSRect(x: 140, y: 80, width: 124, height: 22),
        textViewBounds: NSRect(x: 0, y: 0, width: 800, height: 600),
        horizontalInset: 26,
        mode: .inline,
        preferredWidth: 96,
        preferredHeight: 30
      ))
    XCTAssertEqual(frame.origin.x, 140, accuracy: 0.01)
    XCTAssertEqual(frame.width, 96, accuracy: 0.01)
    XCTAssertEqual(frame.height, 30, accuracy: 0.01)
    XCTAssertEqual(frame.midY, 91, accuracy: 0.01)
  }

  func testInlineFormulaFallsBackBeforeCoveringFollowingGlyphs() {
    let frame = MarkdownInlineAttachmentDrawingLayout.frame(
      sourceRect: NSRect(x: 140, y: 80, width: 72, height: 22),
      textViewBounds: NSRect(x: 0, y: 0, width: 800, height: 600),
      horizontalInset: 26,
      mode: .inline,
      preferredWidth: 96,
      preferredHeight: 30
    )

    XCTAssertNil(frame)
  }

  func testBlockOverlayWidthIsClampedToNarrowTextContainer() throws {
    let bounds = NSRect(x: 0, y: 0, width: 80, height: 600)
    let frame = try XCTUnwrap(
      MarkdownInlineAttachmentDrawingLayout.frame(
        sourceRect: NSRect(x: 24, y: 80, width: 180, height: 22),
        textViewBounds: bounds,
        horizontalInset: 26,
        mode: .block,
        preferredWidth: nil,
        preferredHeight: 164
      ))

    XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
    XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
    XCTAssertLessThanOrEqual(frame.width, bounds.width)
    XCTAssertEqual(frame.width, 28, accuracy: 0.01)
  }

  func testNativeAttachmentBridgeRequiresAppKitAttachmentCharacter() {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = "![cover](cover.png)"
    let sourceRange = NSRange(location: 0, length: 1)
    let attachment = MarkdownNativeTextAttachment(
      content: .formula(
        source: "E = mc^2",
        displayMode: .inline,
        fontSize: 16
      ),
      bounds: NSRect(x: 0, y: -24, width: 96, height: 30)
    )

    XCTAssertFalse(
      MarkdownNativeTextAttachmentSupport.canInstall(
        in: textView,
        sourceRange: sourceRange
      )
    )
    XCTAssertFalse(
      MarkdownNativeTextAttachmentSupport.install(
        attachment,
        in: textView,
        sourceRange: sourceRange
      )
    )
    XCTAssertNil(
      textView.textStorage?.attribute(
        .attachment,
        at: sourceRange.location,
        effectiveRange: nil
      ))
    XCTAssertEqual(textView.string, "![cover](cover.png)")
  }

  func testNativeAttachmentProviderKeepsReplacementCharacterAndOwnsViewCreation() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    let source = "A\u{FFFC}B"
    textView.string = source
    let sourceRange = NSRange(location: 1, length: 1)
    let attachment = MarkdownNativeTextAttachment(
      content: .formula(
        source: "E = mc^2",
        displayMode: .inline,
        fontSize: 16
      ),
      bounds: NSRect(x: 0, y: -24, width: 96, height: 30)
    )
    XCTAssertTrue(
      MarkdownNativeTextAttachmentSupport.install(
        attachment,
        in: textView,
        sourceRange: sourceRange
      )
    )
    XCTAssertEqual(textView.string, source)
    XCTAssertTrue(textView.textLayoutManager != nil)
    XCTAssertTrue(attachment.usesTextAttachmentView)
    let installedAttachment: NSTextAttachment? =
      textView.textStorage?.attribute(
        .attachment,
        at: sourceRange.location,
        effectiveRange: nil
      ) as? NSTextAttachment
    XCTAssertTrue(installedAttachment === attachment)

    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    let contentManager = try XCTUnwrap(layoutManager.textContentManager)
    let location = try XCTUnwrap(
      contentManager.location(contentManager.documentRange.location, offsetBy: 1)
    )
    let provider = MarkdownNativeTextAttachmentViewProvider(
      textAttachment: attachment,
      parentView: textView,
      textLayoutManager: layoutManager,
      location: location
    )
    let appKitProvider = try XCTUnwrap(
      attachment.viewProvider(
        for: textView,
        location: location,
        textContainer: textView.textContainer
      )
    )
    XCTAssertTrue(appKitProvider.textLayoutManager === layoutManager)
    let subviewCountBefore = textView.subviews.count
    let attachmentView = try XCTUnwrap(provider.view)

    XCTAssertTrue(attachmentView is MarkdownInlineAttachmentOverlayView)
    XCTAssertEqual(textView.subviews.count, subviewCountBefore)
    XCTAssertTrue(provider.tracksTextAttachmentViewBounds)
    XCTAssertEqual(
      provider.attachmentBounds(
        for: [:],
        location: location,
        textContainer: textView.textContainer,
        proposedLineFragment: .zero,
        position: .zero
      ),
      attachment.bounds
    )

    MarkdownNativeTextAttachmentSupport.remove(
      from: textView,
      sourceRange: sourceRange
    )
    XCTAssertNil(
      textView.textStorage?.attribute(
        .attachment,
        at: sourceRange.location,
        effectiveRange: nil
      ))
    XCTAssertEqual(textView.string, source)
  }
}
