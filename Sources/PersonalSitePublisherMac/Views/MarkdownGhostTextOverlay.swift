import AppKit

final class MarkdownGhostTextOverlayView: NSView {
  weak var textView: NSTextView?
  var ghostText = "" {
    didSet {
      guard oldValue != ghostText else { return }
      isHidden = ghostText.isEmpty
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let textView,
          !ghostText.isEmpty,
          let font = textView.font else {
      return
    }

    let cursor = textView.selectedRange()
    guard cursor.length == 0,
          let insertionRect = insertionRect(in: textView, cursor: cursor.location) else {
      return
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.48),
      .paragraphStyle: paragraphStyle
    ]
    let origin = NSPoint(
      x: max(0, insertionRect.minX),
      y: max(0, insertionRect.minY)
    )
    let width = max(80, bounds.width - origin.x - 20)
    let drawRect = NSRect(
      x: origin.x,
      y: origin.y,
      width: width,
      height: max(font.boundingRectForFont.height * 4, bounds.height - origin.y)
    )
    (ghostText as NSString).draw(
      with: drawRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
    )
  }

  private func insertionRect(in textView: NSTextView, cursor: Int) -> NSRect? {
    let documentLength = (textView.string as NSString).length
    let clampedCursor = min(max(cursor, 0), documentLength)
    let screenRect = textView.firstRect(
      forCharacterRange: NSRange(location: clampedCursor, length: 0),
      actualRange: nil
    )
    if !screenRect.isEmpty {
      let windowRect = textView.window?.convertFromScreen(screenRect) ?? screenRect
      return convert(windowRect, from: nil)
    }

    guard let layoutManager = textView.layoutManager else {
      return nil
    }
    let glyphCount = layoutManager.numberOfGlyphs
    guard glyphCount > 0 else {
      return NSRect(
        x: textView.textContainerOrigin.x,
        y: textView.textContainerOrigin.y,
        width: 1,
        height: fontLineHeight(for: textView)
      )
    }
    let glyphIndex = min(clampedCursor, glyphCount - 1)
    let lineRect = layoutManager.lineFragmentRect(
      forGlyphAt: glyphIndex,
      effectiveRange: nil
    )
    let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
    return NSRect(
      x: textView.textContainerOrigin.x + glyphLocation.x,
      y: textView.textContainerOrigin.y + lineRect.minY,
      width: 1,
      height: lineRect.height
    )
  }

  private func fontLineHeight(for textView: NSTextView) -> CGFloat {
    textView.font?.boundingRectForFont.height ?? NSFont.systemFontSize
  }
}
