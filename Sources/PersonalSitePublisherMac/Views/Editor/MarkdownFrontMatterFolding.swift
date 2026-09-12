import AppKit

/// Folding only changes the visible document bounds. Markdown bytes, UTF-16
/// offsets and the text view's undo stack remain intact.
final class MarkdownFrontMatterClipView: NSClipView {
  var hiddenPrefixHeight: CGFloat = 0

  override var documentRect: NSRect {
    var rect = super.documentRect
    let prefix = min(max(0, hiddenPrefixHeight), rect.height)
    rect.origin.y += prefix
    rect.size.height -= prefix
    return rect
  }

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var bounds = super.constrainBoundsRect(proposedBounds)
    bounds.origin.y = max(bounds.origin.y, hiddenPrefixHeight)
    return bounds
  }
}

enum MarkdownFrontMatterFoldSelection {
  static func visibleRange(_ range: NSRange, bodyOffset: Int, documentLength: Int) -> NSRange {
    let lower = min(max(bodyOffset, 0), documentLength)
    guard range.location != NSNotFound else { return NSRange(location: lower, length: 0) }
    let start = min(max(range.location, lower), documentLength)
    let available = max(0, documentLength - min(range.location, documentLength))
    let end = min(documentLength, range.location + min(range.length, available))
    return NSRange(location: start, length: max(0, end - start))
  }
}

@MainActor
enum MarkdownFrontMatterFoldGeometry {
  static func bodyOrigin(at bodyOffset: Int, in textView: NSTextView) -> CGFloat? {
    guard let manager = textView.textLayoutManager,
      let range = MarkdownTextKit2RangeAdapter.textRange(
        for: NSRange(location: bodyOffset, length: 0), in: textView)
    else { return nil }
    manager.ensureLayout(for: range)
    var origin: CGFloat?
    manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
      // A caret has zero width, so NSRect.isEmpty rejects valid geometry.
      if rect.height > 0 {
        origin = rect.minY + textView.textContainerOrigin.y
      }
      return false
    }
    return origin
  }
}
