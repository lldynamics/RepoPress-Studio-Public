import AppKit

/// Preserves the text at the top of the viewport when the editor reflows.
/// Reflow resolves the prefix through the visible text to keep coordinates
/// stable. Ordinary scrolling does not invoke this work.
@MainActor
struct MarkdownEditorViewportAnchor {
  let range: NSRange
  let visibleRange: NSRange
  let offset: CGFloat

  static func capture(in scrollView: NSScrollView) -> Self? {
    guard let textView = scrollView.documentView as? NSTextView,
      !textView.string.isEmpty
    else { return nil }
    let bounds = scrollView.contentView.bounds
    let x = textView.textContainerOrigin.x + 1
    let length = (textView.string as NSString).length
    let start = min(
      textView.characterIndexForInsertion(
        at: NSPoint(x: x, y: max(bounds.minY + 1, textView.textContainerOrigin.y + 1))), length - 1)
    let end = min(textView.characterIndexForInsertion(at: NSPoint(x: x, y: bounds.maxY)), length)
    let range = NSRange(location: start, length: 1)
    guard let rect = MarkdownTextKit2RangeAdapter.rect(for: range, in: textView) else { return nil }
    return Self(
      range: range,
      visibleRange: NSRange(location: start, length: max(end - start, 1)),
      offset: bounds.minY - rect.minY
    )
  }

  /// Live resize can outlast an edit. Never ask TextKit to resolve an anchor
  /// from a previous document length, because a stale UTF-16 range can point
  /// beyond the newly edited buffer.
  func isValid(in textView: NSTextView) -> Bool {
    let length = (textView.string as NSString).length
    return length > 0
      && range.location >= 0
      && NSMaxRange(range) <= length
      && visibleRange.location >= 0
      && NSMaxRange(visibleRange) <= length
  }

  func origin(afterReflowIn textView: NSTextView) -> CGFloat? {
    guard isValid(in: textView) else { return nil }
    if let range = MarkdownTextKit2RangeAdapter.textRange(
      for: NSRange(location: 0, length: NSMaxRange(visibleRange)), in: textView
    ) {
      textView.textLayoutManager?.ensureLayout(for: range)
    }
    // Keep the document extent available as well as the visible prefix. A
    // partially laid-out usage bound must not become a shorter scroll range.
    let lastCharacter = NSRange(location: (textView.string as NSString).length - 1, length: 1)
    _ = MarkdownTextKit2RangeAdapter.rect(for: lastCharacter, in: textView)
    return MarkdownTextKit2RangeAdapter.rect(for: range, in: textView).map { $0.minY + offset }
  }
}
