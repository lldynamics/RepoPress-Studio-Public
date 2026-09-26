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

  /// TextKit 2 rendering attributes are paint-only, so fonts and paragraph
  /// metrics must live in the text storage to reach layout. Brings the
  /// storage's layout attributes inside `applicationRange` in line with the
  /// palette, writing only where they differ so an unchanged repaint does not
  /// invalidate layout. Ranges in `excludedRanges` (collapsed syntax markers)
  /// keep their own layout font.
  @discardableResult
  static func synchronizeLayoutAttributes(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    in textStorage: NSMutableAttributedString,
    within applicationRange: NSRange,
    excluding excludedRanges: [NSRange],
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    let clampedRange = NSIntersectionRange(
      applicationRange,
      NSRange(location: 0, length: textStorage.length)
    )
    guard clampedRange.length > 0 else { return 0 }
    var writeCount = 0
    let sortedExclusions = excludedRanges.sorted { $0.location < $1.location }

    func write(_ key: NSAttributedString.Key, _ value: NSObject, in range: NSRange) {
      for segment in subtracting(sortedExclusions, from: range) {
        textStorage.enumerateAttribute(key, in: segment) { current, runRange, _ in
          guard (current as? NSObject)?.isEqual(value) != true else { return }
          textStorage.addAttribute(key, value: value, range: runRange)
          writeCount += 1
        }
      }
    }

    for run in composedFontRuns(
      snapshot,
      within: clampedRange,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    ) {
      write(.font, run.font, in: run.range)
    }

    if let defaultParagraphStyle = defaultAttributes[.paragraphStyle] as? NSParagraphStyle {
      let source = textStorage.string as NSString
      var headingParagraphs: [(range: NSRange, style: NSParagraphStyle)] = []
      for run in snapshot.runs {
        guard let style = styleAttributes[run.style]?[.paragraphStyle] as? NSParagraphStyle,
          NSIntersectionRange(run.range, clampedRange).length > 0,
          NSMaxRange(run.range) <= source.length
        else { continue }
        headingParagraphs.append((source.paragraphRange(for: run.range), style))
      }
      // Other storage paragraph styles (e.g. inline attachment card height
      // reservations) are owned elsewhere; only undo metrics this palette
      // authored for a line that is no longer a heading.
      let paletteParagraphStyles = styleAttributes.values.compactMap {
        $0[.paragraphStyle] as? NSParagraphStyle
      }
      var cursor = clampedRange.location
      for paragraph in headingParagraphs.sorted(by: { $0.range.location < $1.range.location }) {
        let range = NSIntersectionRange(paragraph.range, clampedRange)
        guard range.length > 0, range.location >= cursor else { continue }
        writeCount += resetStalePaletteParagraphStyles(
          in: textStorage,
          within: NSRange(location: cursor, length: range.location - cursor),
          matching: paletteParagraphStyles,
          defaultStyle: defaultParagraphStyle)
        write(.paragraphStyle, paragraph.style, in: range)
        cursor = NSMaxRange(range)
      }
      writeCount += resetStalePaletteParagraphStyles(
        in: textStorage,
        within: NSRange(location: cursor, length: NSMaxRange(clampedRange) - cursor),
        matching: paletteParagraphStyles,
        defaultStyle: defaultParagraphStyle)
    }
    return writeCount
  }

  private static func resetStalePaletteParagraphStyles(
    in textStorage: NSMutableAttributedString,
    within range: NSRange,
    matching paletteStyles: [NSParagraphStyle],
    defaultStyle: NSParagraphStyle
  ) -> Int {
    var cursor = range.location
    var writeCount = 0
    // Keep AppKit objects on MainActor instead of capturing them in an
    // Objective-C enumeration block inside a local function.
    while cursor < NSMaxRange(range) {
      var effectiveRange = NSRange()
      let current = textStorage.attribute(
        .paragraphStyle, at: cursor, longestEffectiveRange: &effectiveRange, in: range)
      let runRange = NSIntersectionRange(
        effectiveRange, NSRange(location: cursor, length: NSMaxRange(range) - cursor))
      cursor = NSMaxRange(runRange)
      guard let current = current as? NSParagraphStyle,
        paletteStyles.contains(where: { $0.isEqual(current) })
      else { continue }
      textStorage.addAttribute(.paragraphStyle, value: defaultStyle, range: runRange)
      writeCount += 1
    }
    return writeCount
  }

  private static func subtracting(_ sortedExclusions: [NSRange], from range: NSRange) -> [NSRange] {
    var segments: [NSRange] = []
    var cursor = range.location
    for exclusion in sortedExclusions {
      guard NSMaxRange(exclusion) > cursor else { continue }
      guard exclusion.location < NSMaxRange(range) else { break }
      if exclusion.location > cursor {
        segments.append(NSRange(location: cursor, length: exclusion.location - cursor))
      }
      cursor = max(cursor, NSMaxRange(exclusion))
    }
    if cursor < NSMaxRange(range) {
      segments.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
    }
    return segments
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
