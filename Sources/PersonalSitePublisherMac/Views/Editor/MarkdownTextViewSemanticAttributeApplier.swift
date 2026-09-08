import AppKit
import PublishingMarkdownCore

@MainActor
enum MarkdownTextViewSemanticAttributeApplier {
  struct FontRun {
    let range: NSRange
    let font: NSFont
  }

  @discardableResult
  static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    apply(
      snapshot,
      to: textStorage,
      within: snapshot.range,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    )
  }

  @discardableResult
  static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    within applicationRange: NSRange,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: textStorage,
      within: applicationRange,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    )

    for run in composedFontRuns(
      snapshot,
      within: applicationRange,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    ) where NSMaxRange(run.range) <= textStorage.length {
      textStorage.addAttribute(.font, value: run.font, range: run.range)
    }
    return appliedRunCount
  }

  static func composedFontRuns(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    within applicationRange: NSRange,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> [FontRun] {
    guard applicationRange.length > 0,
      let defaultFont = defaultAttributes[.font] as? NSFont
    else { return [] }

    var boundaries: Set<Int> = [applicationRange.location, NSMaxRange(applicationRange)]
    let relevantRuns = snapshot.runs.compactMap { run -> MarkdownSyntaxHighlightRun? in
      let affectsFont =
        styleAttributes[run.style]?[.font] is NSFont
        || run.style == .bold
        || run.style == .italic
      guard affectsFont else { return nil }
      let intersection = NSIntersectionRange(run.range, applicationRange)
      guard intersection.length > 0 else { return nil }
      boundaries.insert(intersection.location)
      boundaries.insert(NSMaxRange(intersection))
      return MarkdownSyntaxHighlightRun(style: run.style, range: intersection)
    }
    let orderedBoundaries = boundaries.sorted()
    guard orderedBoundaries.count > 1 else { return [] }

    var fontRuns: [FontRun] = []
    for index in 0..<(orderedBoundaries.count - 1) {
      let segment = NSRange(
        location: orderedBoundaries[index],
        length: orderedBoundaries[index + 1] - orderedBoundaries[index]
      )
      guard segment.length > 0 else { continue }
      var font = defaultFont
      var hasBold = false
      var hasItalic = false
      for run in relevantRuns where NSIntersectionRange(run.range, segment).length > 0 {
        if let styledFont = styleAttributes[run.style]?[.font] as? NSFont {
          font = styledFont
        }
        hasBold = hasBold || run.style == .bold
        hasItalic = hasItalic || run.style == .italic
      }
      if hasBold {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if hasItalic {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      if let last = fontRuns.last,
        NSMaxRange(last.range) == segment.location,
        last.font == font
      {
        fontRuns[fontRuns.count - 1] = FontRun(
          range: NSUnionRange(last.range, segment),
          font: font
        )
      } else {
        fontRuns.append(FontRun(range: segment, font: font))
      }
    }
    return fontRuns
  }
}
