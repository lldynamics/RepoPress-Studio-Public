import AppKit

enum MarkdownInlineAttachmentDrawingLayoutMode {
  case block
  case inline
}

enum MarkdownInlineAttachmentDrawingLayout {
  static func formulaMinimumLineHeight(
    presentationHeight: CGFloat,
    sourceText: String,
    laidOutSourceLineCount: Int = 0
  ) -> CGFloat {
    let source = sourceText as NSString
    var paragraphCount = 0
    var location = 0
    while location < source.length {
      paragraphCount += 1
      location = NSMaxRange(source.paragraphRange(for: NSRange(location: location, length: 0)))
    }
    // A display formula can span separate delimiter paragraphs and wrapped
    // source lines. Reserve its total presentation height across those lines,
    // rather than applying a complete card height to every source paragraph.
    let lineCount = max(1, max(paragraphCount, laidOutSourceLineCount))
    return max(24, ceil((presentationHeight + WorkbenchSpacing.control) / CGFloat(lineCount)))
  }

  static func frame(
    sourceRect: NSRect,
    textViewBounds: NSRect,
    horizontalInset: CGFloat,
    mode: MarkdownInlineAttachmentDrawingLayoutMode,
    preferredWidth: CGFloat?,
    preferredHeight: CGFloat
  ) -> NSRect? {
    let bounds = textViewBounds.standardized
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    // A narrow editor window must never produce a frame wider than the text
    // container. Keep at least one point for the content area while clamping
    // the inset itself when the window is narrower than the normal gutter.
    let safeInset = min(
      max(0, horizontalInset),
      max(0, (bounds.width - 1) / 2)
    )
    let contentMinX = bounds.minX + safeInset
    let contentMaxX = bounds.maxX - safeInset
    let availableWidth = max(1, contentMaxX - contentMinX)

    switch mode {
    case .block:
      let height = max(preferredHeight, sourceRect.height - 12)
      return NSRect(
        x: contentMinX,
        y: sourceRect.midY - (height / 2),
        width: availableWidth,
        height: height
      )
    case .inline:
      let sourceWidth = sourceRect.width
      guard sourceWidth > 0 else { return nil }

      // Inline drawings are painted above the Markdown source. If their
      // presentation needs more width than the source span reserved by
      // TextKit, extending the frame would cover the next glyph. Returning
      // nil makes the caller restore the source instead of obscuring text.
      let requestedWidth = max(1, preferredWidth ?? sourceWidth)
      let tolerance: CGFloat = 0.5
      guard requestedWidth <= sourceWidth + tolerance else { return nil }

      let x = min(max(contentMinX, sourceRect.minX), contentMaxX)
      let availableInlineWidth = max(0, contentMaxX - x)
      let visibleSourceWidth = max(0, sourceRect.maxX - x)
      guard requestedWidth <= availableInlineWidth + tolerance,
        requestedWidth <= visibleSourceWidth + tolerance
      else {
        // A partially visible or narrow source span cannot safely host the
        // complete formula presentation. Keep the Markdown source visible.
        return nil
      }

      let width = min(requestedWidth, min(availableInlineWidth, visibleSourceWidth))
      guard width > 0 else { return nil }
      let height = max(preferredHeight, sourceRect.height + 4)
      return NSRect(
        x: x,
        y: sourceRect.midY - (height / 2),
        width: width,
        height: height
      )
    }
  }
}
