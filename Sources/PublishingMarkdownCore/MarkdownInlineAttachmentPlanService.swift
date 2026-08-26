import Foundation

public struct MarkdownInlineAttachmentPlan: Hashable, Sendable {
  public var items: [MarkdownInlineAttachmentItem]

  public init(items: [MarkdownInlineAttachmentItem]) {
    self.items = items
  }
}

public struct MarkdownInlineAttachmentItem: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case image(reference: String, altText: String)
    case formula(source: String, displayMode: MarkdownFormulaDisplayMode)
  }

  public var range: NSRange
  public var kind: Kind

  public init(range: NSRange, kind: Kind) {
    self.range = range
    self.kind = kind
  }
}

public enum MarkdownFormulaDisplayMode: String, Hashable, Sendable {
  case inline
  case display
}

public enum MarkdownInlineAttachmentPlanService {
  private static let incrementalMaximumEditLength = 4_096
  private static let attachmentSyntaxCharacters = CharacterSet(
    charactersIn: "\r\n$\\`~![]()<>"
  )
  private static let imageExpression = try? NSRegularExpression(
    pattern:
      #"^[ \t]*!\[((?:\\.|[^\]])*)\]\((?:<([^>]+)>|(.+?))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\)[ \t]*$"#,
    options: [.anchorsMatchLines]
  )
  private static let formulaExpressions: [NSRegularExpression] = [
    try? NSRegularExpression(pattern: #"(?s)(?<!\\)\$\$(.+?)(?<!\\)\$\$"#),
    try? NSRegularExpression(pattern: #"(?s)(?<!\\)\\\[(.+?)(?<!\\)\\\]"#),
  ].compactMap { $0 }
  private static let inlineFormulaExpression = try? NSRegularExpression(
    pattern: #"(?<!\\)(?<!\$)\$(?![\s$])((?:\\.|[^$\r\n])+?)(?<![\s\\])\$(?!\$)"#
  )

  public static func plan(in markdown: String) -> MarkdownInlineAttachmentPlan {
    let source = markdown as NSString
    guard source.length > 0 else { return MarkdownInlineAttachmentPlan(items: []) }
    let fullRange = NSRange(location: 0, length: source.length)
    let protectedRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    var items: [MarkdownInlineAttachmentItem] = []

    if let imageExpression {
      for match in imageExpression.matches(in: markdown, range: fullRange) {
        guard match.numberOfRanges >= 4,
          !intersects(match.range, protectedRanges),
          let referenceRange = [match.range(at: 2), match.range(at: 3)]
            .first(where: { $0.location != NSNotFound })
        else { continue }
        let altText =
          match.range(at: 1).location == NSNotFound
          ? ""
          : source.substring(with: match.range(at: 1))
        items.append(
          MarkdownInlineAttachmentItem(
            range: match.range,
            kind: .image(
              reference: source.substring(with: referenceRange),
              altText: altText
            )
          )
        )
      }
    }

    for expression in formulaExpressions {
      for match in expression.matches(in: markdown, range: fullRange) {
        guard match.numberOfRanges > 1,
          !intersects(match.range, protectedRanges),
          occupiesWholeLines(match.range, in: source)
        else { continue }
        let formula = source.substring(with: match.range(at: 1))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formula.isEmpty else { continue }
        items.append(
          MarkdownInlineAttachmentItem(
            range: match.range,
            kind: .formula(source: formula, displayMode: .display)
          )
        )
      }
    }

    if let inlineFormulaExpression {
      for match in inlineFormulaExpression.matches(in: markdown, range: fullRange) {
        guard match.numberOfRanges > 1,
          !intersects(match.range, protectedRanges)
        else { continue }
        let formula = source.substring(with: match.range(at: 1))
        guard !formula.isEmpty else { continue }
        items.append(
          MarkdownInlineAttachmentItem(
            range: match.range,
            kind: .formula(source: formula, displayMode: .inline)
          )
        )
      }
    }

    let orderedItems = items.sorted { lhs, rhs in
      lhs.range.location == rhs.range.location
        ? lhs.range.length > rhs.range.length
        : lhs.range.location < rhs.range.location
    }
    var selected: [MarkdownInlineAttachmentItem] = []
    selected.reserveCapacity(orderedItems.count)
    for item in orderedItems {
      if let last = selected.last,
        NSIntersectionRange(last.range, item.range).length > 0
      {
        continue
      }
      selected.append(item)
    }
    return MarkdownInlineAttachmentPlan(items: selected)
  }

  /// Reuses an existing attachment plan for an ordinary text edit that cannot
  /// create, remove, or change Markdown attachment syntax. Structural edits
  /// return `nil` so the caller can conservatively rebuild the complete plan.
  public static func incrementallyUpdatedPlan(
    _ previousPlan: MarkdownInlineAttachmentPlan,
    previousMarkdown: String,
    currentMarkdown: String,
    replacedRange: NSRange
  ) -> MarkdownInlineAttachmentPlan? {
    let previousSource = previousMarkdown as NSString
    let currentSource = currentMarkdown as NSString
    guard replacedRange.location != NSNotFound,
      replacedRange.location >= 0,
      replacedRange.length >= 0,
      replacedRange.location <= previousSource.length,
      replacedRange.length <= previousSource.length - replacedRange.location
    else { return nil }

    let insertedLength = currentSource.length - previousSource.length + replacedRange.length
    guard insertedLength >= 0,
      insertedLength <= incrementalMaximumEditLength,
      replacedRange.length <= incrementalMaximumEditLength
    else { return nil }

    let insertedRange = NSRange(location: replacedRange.location, length: insertedLength)
    let removedText = previousSource.substring(with: replacedRange)
    let insertedText = currentSource.substring(with: insertedRange)
    guard !containsAttachmentSyntax(removedText),
      !containsAttachmentSyntax(insertedText),
      !editTouchesAttachmentLine(
        replacedRange,
        items: previousPlan.items,
        source: previousSource
      )
    else { return nil }

    let delta = insertedLength - replacedRange.length
    let replacedEnd = NSMaxRange(replacedRange)
    let updatedItems = previousPlan.items.map { item -> MarkdownInlineAttachmentItem in
      guard item.range.location >= replacedEnd else { return item }
      return MarkdownInlineAttachmentItem(
        range: NSRange(location: item.range.location + delta, length: item.range.length),
        kind: item.kind
      )
    }
    return MarkdownInlineAttachmentPlan(items: updatedItems)
  }

  private static func occupiesWholeLines(_ range: NSRange, in source: NSString) -> Bool {
    let lineRange = source.lineRange(for: range)
    let prefixRange = NSRange(
      location: lineRange.location,
      length: max(0, range.location - lineRange.location)
    )
    let suffixStart = NSMaxRange(range)
    let suffixRange = NSRange(
      location: suffixStart,
      length: max(0, NSMaxRange(lineRange) - suffixStart)
    )
    let whitespace = CharacterSet.whitespacesAndNewlines
    return source.substring(with: prefixRange).trimmingCharacters(in: whitespace).isEmpty
      && source.substring(with: suffixRange).trimmingCharacters(in: whitespace).isEmpty
  }

  private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
    ranges.contains { NSIntersectionRange(range, $0).length > 0 }
  }

  private static func containsAttachmentSyntax(_ text: String) -> Bool {
    text.rangeOfCharacter(from: attachmentSyntaxCharacters) != nil
  }

  private static func editTouchesAttachmentLine(
    _ editRange: NSRange,
    items: [MarkdownInlineAttachmentItem],
    source: NSString
  ) -> Bool {
    items.contains { item in
      let lineRange = source.lineRange(for: item.range)
      if editRange.length == 0 {
        return editRange.location >= lineRange.location
          && editRange.location <= NSMaxRange(lineRange)
      }
      return NSIntersectionRange(editRange, lineRange).length > 0
    }
  }
}
