import AppKit
import Foundation

extension MacMarkdownTextView {
  func clamped(_ range: NSRange, length: Int) -> NSRange {
    Self.clamped(range, length: length)
  }

  func documentRange(
    forBodyRange range: NSRange,
    bodyUTF16Offset: Int,
    documentLength: Int
  ) -> NSRange {
    let bodyLength = max(0, documentLength - bodyUTF16Offset)
    let clampedBodyRange = Self.clamped(range, length: bodyLength)
    return NSRange(
      location: bodyUTF16Offset + clampedBodyRange.location,
      length: clampedBodyRange.length
    )
  }

  static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  static func configureAccessibility(for textView: NSTextView) {
    textView.setAccessibilityLabel(String(localized: "Markdown 文档编辑器"))
    textView.setAccessibilityHelp(
      String(localized: "编辑当前文章的 Front Matter 与 Markdown 正文；Control-Tab 移到下一个控件")
    )
    textView.setAccessibilityIdentifier("markdown-document-editor")
  }
}
