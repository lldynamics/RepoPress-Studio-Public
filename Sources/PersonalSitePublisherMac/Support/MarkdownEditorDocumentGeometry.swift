import AppKit

@MainActor
enum MarkdownEditorDocumentGeometry {
  static func height(in textView: NSTextView) -> CGFloat? {
    guard let layoutManager = textView.textLayoutManager else { return nil }
    let length = (textView.string as NSString).length
    if length > 0 {
      // A cold viewport can expose only its laid-out prefix as the usage
      // bound. Resolve the final fragment before caching the scroll extent,
      // without requesting full-document line layout or moving the caret.
      _ = MarkdownTextKit2RangeAdapter.rect(
        for: NSRange(location: length - 1, length: 1), in: textView
      )
    }
    return layoutManager.usageBoundsForTextContainer.height + textView.textContainerInset.height * 2
  }
}
