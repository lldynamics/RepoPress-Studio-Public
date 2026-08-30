import Foundation
import SwiftTreeSitter

extension MarkdownSyntaxHighlightParser {
  static func captureRuns(
    from highlights: [NamedRange],
    source: NSString,
    requestedRange: NSRange
  ) -> MarkdownSyntaxCaptureRuns {
    var result = MarkdownSyntaxCaptureRuns()
    var referenceCaptures: [NSRange] = []
    var uriCaptures: [NSRange] = []

    for highlight in highlights {
      guard
        let range = boundedCaptureRange(
          highlight.range,
          source: source,
          requestedRange: requestedRange
        )
      else {
        continue
      }

      switch highlight.name {
      case "text.title":
        guard let level = atxHeadingLevel(in: source, at: range.location),
          let lineRange = boundedLineRange(
            in: source,
            at: range.location,
            requestedRange: requestedRange
          )
        else {
          continue
        }
        result.headings.append(
          MarkdownSyntaxHighlightRun(
            style: headingStyle(for: level),
            range: lineRange
          )
        )
      case "text.emphasis":
        result.italic.append(range)
      case "text.strong":
        result.bold.append(range)
      case "text.reference":
        referenceCaptures.append(highlight.range)
      case "text.uri":
        uriCaptures.append(highlight.range)
      case "punctuation.special":
        guard
          let lineRange = boundedLineRange(
            in: source,
            at: range.location,
            requestedRange: requestedRange
          )
        else {
          continue
        }
        if isListLine(in: source, lineRange: lineRange) {
          result.lists.append(lineRange)
        } else if isQuoteLine(in: source, lineRange: lineRange) {
          result.quotes.append(lineRange)
        }
      default:
        continue
      }
    }

    result.links = captureLinkRanges(
      referenceCaptures: referenceCaptures,
      uriCaptures: uriCaptures,
      source: source,
      requestedRange: requestedRange
    )
    result.headings = normalizedRuns(result.headings)
    result.links = normalizedRanges(result.links)
    result.lists = normalizedRanges(result.lists)
    result.quotes = normalizedRanges(result.quotes)
    result.bold = normalizedRanges(result.bold)
    result.italic = normalizedRanges(result.italic)
    return result
  }

  static func lexicalFallbackStyles(
    mode: MarkdownSyntaxHighlightSnapshotMode,
    treeSitterHighlights: [NamedRange],
    captureRuns: MarkdownSyntaxCaptureRuns,
    source: NSString,
    requestedRange: NSRange,
    literalRanges: [NSRange]
  ) -> MarkdownSyntaxLexicalStyles {
    guard case .synchronized = mode, !treeSitterHighlights.isEmpty else {
      return .all
    }

    var styles: MarkdownSyntaxLexicalStyles = [.html, .strikethrough]
    if captureRuns.headings.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.headings.map(\.range),
        predicate: { atxHeadingLevel(in: $0, at: $1.location) != nil }
      )
    {
      styles.insert(.headings)
    }
    if captureRuns.links.isEmpty
      || hasUncapturedInlineLink(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.links,
        literalRanges: literalRanges
      )
    {
      styles.insert(.links)
    }
    if captureRuns.lists.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.lists,
        predicate: isListLine
      )
    {
      styles.insert(.lists)
    }
    if captureRuns.quotes.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.quotes,
        predicate: isQuoteLine
      )
    {
      styles.insert(.quotes)
    }
    if captureRuns.bold.isEmpty { styles.insert(.bold) }
    if captureRuns.italic.isEmpty { styles.insert(.italic) }
    if containsUnresolvedTripleAsterisk(
      in: source,
      requestedRange: requestedRange,
      literalRanges: literalRanges
    ) {
      styles.insert([.bold, .italic])
    }
    return styles
  }

  static func hasUncapturedLineStyle(
    in source: NSString,
    requestedRange: NSRange,
    capturedRanges: [NSRange],
    predicate: (NSString, NSRange) -> Bool
  ) -> Bool {
    var location = requestedRange.location
    let upperBound = NSMaxRange(requestedRange)
    while location < upperBound {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      let fullLine = NSRange(
        location: lineStart,
        length: max(0, contentsEnd - lineStart)
      )
      let candidate = NSIntersectionRange(fullLine, requestedRange)
      if candidate.length > 0,
        predicate(source, fullLine),
        !capturedRanges.contains(where: {
          NSIntersectionRange($0, candidate).length > 0
        })
      {
        return true
      }
      location = max(lineEnd, location + 1)
    }
    return false
  }

  static func hasUncapturedInlineLink(
    in source: NSString,
    requestedRange: NSRange,
    capturedRanges: [NSRange],
    literalRanges: [NSRange]
  ) -> Bool {
    let expandedRange = source.lineRange(for: requestedRange)
    var cursor = expandedRange.location
    let upperBound = min(NSMaxRange(expandedRange), source.length)
    while cursor < upperBound {
      guard source.character(at: cursor) == 91,
        !isEscaped(source, at: cursor),
        let closing = closingBracket(after: cursor + 1, source: source)
      else {
        cursor += 1
        continue
      }
      let destinationStart = closing + 1
      guard destinationStart < upperBound,
        source.character(at: destinationStart) == 40,
        let ending = closingParenthesis(after: destinationStart + 1, source: source)
      else {
        cursor = closing + 1
        continue
      }
      let candidate = NSRange(
        location: cursor,
        length: ending + 1 - cursor
      )
      let requestedCandidate = NSIntersectionRange(candidate, requestedRange)
      if requestedCandidate.length > 0,
        !literalRanges.contains(where: {
          NSIntersectionRange($0, requestedCandidate).length > 0
        }),
        !capturedRanges.contains(where: {
          NSIntersectionRange($0, requestedCandidate).length > 0
        })
      {
        return true
      }
      cursor = ending + 1
    }
    return false
  }

  static func containsUnresolvedTripleAsterisk(
    in source: NSString,
    requestedRange: NSRange,
    literalRanges: [NSRange]
  ) -> Bool {
    var searchStart = requestedRange.location
    let upperBound = NSMaxRange(requestedRange)
    while searchStart < upperBound {
      let remaining = NSRange(location: searchStart, length: upperBound - searchStart)
      let marker = source.range(of: "***", options: [], range: remaining)
      guard marker.location != NSNotFound else { return false }
      if !literalRanges.contains(where: { NSIntersectionRange($0, marker).length > 0 }) {
        return true
      }
      searchStart = NSMaxRange(marker)
    }
    return false
  }

  static func boundedCaptureRange(
    _ captureRange: NSRange,
    source: NSString,
    requestedRange: NSRange
  ) -> NSRange? {
    guard isValid(captureRange, length: source.length) else { return nil }
    let intersection = NSIntersectionRange(captureRange, requestedRange)
    return intersection.length > 0 ? intersection : nil
  }

  static func boundedLineRange(
    in source: NSString,
    at location: Int,
    requestedRange: NSRange
  ) -> NSRange? {
    guard location >= 0, location <= source.length else { return nil }
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    source.getLineStart(
      &lineStart,
      end: &lineEnd,
      contentsEnd: &contentsEnd,
      for: NSRange(location: min(location, source.length), length: 0)
    )
    let lineRange = NSRange(
      location: lineStart,
      length: max(0, contentsEnd - lineStart)
    )
    let intersection = NSIntersectionRange(lineRange, requestedRange)
    return intersection.length > 0 ? intersection : nil
  }

  static func atxHeadingLevel(in source: NSString, at location: Int) -> Int? {
    guard location >= 0, location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var count = 0
    while cursor < end, source.character(at: cursor) == 35, count < 6 {
      count += 1
      cursor += 1
    }
    guard (1...6).contains(count), cursor < end,
      source.character(at: cursor) == 32 || source.character(at: cursor) == 9
    else {
      return nil
    }
    return count
  }

  static func headingStyle(for level: Int) -> MarkdownSyntaxHighlightStyle {
    switch level {
    case 1: return .heading1
    case 2: return .heading2
    case 3: return .heading3
    case 4: return .heading4
    case 5: return .heading5
    case 6: return .heading6
    default: return .heading
    }
  }

  static func isListLine(in source: NSString, lineRange: NSRange) -> Bool {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    while cursor < end, source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
      cursor += 1
    }
    guard cursor < end else { return false }
    let marker = source.character(at: cursor)
    if marker == 45 || marker == 42 || marker == 43 {
      cursor += 1
    } else if marker >= 48, marker <= 57 {
      repeat {
        cursor += 1
      } while cursor < end
        && source.character(at: cursor) >= 48
        && source.character(at: cursor) <= 57
      guard cursor < end, source.character(at: cursor) == 46 else { return false }
      cursor += 1
    } else {
      return false
    }
    guard cursor < end else { return false }
    return source.character(at: cursor) == 32 || source.character(at: cursor) == 9
  }

  static func isQuoteLine(in source: NSString, lineRange: NSRange) -> Bool {
    lineRange.length > 2
      && source.character(at: lineRange.location) == 62
      && source.character(at: lineRange.location + 1) == 32
  }

  static func captureLinkRanges(
    referenceCaptures: [NSRange],
    uriCaptures: [NSRange],
    source: NSString,
    requestedRange: NSRange
  ) -> [NSRange] {
    var ranges: [NSRange] = []
    for reference in referenceCaptures {
      guard isValid(reference, length: source.length), reference.length > 0,
        let openingBracket = openingBracket(
          before: reference.location,
          source: source
        ),
        let closingBracket = closingBracket(
          after: NSMaxRange(reference),
          source: source
        )
      else {
        continue
      }
      var destinationStart = closingBracket + 1
      guard destinationStart < source.length,
        source.character(at: destinationStart) == 40
      else {
        continue
      }
      destinationStart += 1
      guard
        let uri = uriCaptures.first(where: { uriRange in
          isValid(uriRange, length: source.length)
            && uriRange.location >= destinationStart
            && uriRange.location < source.length
        }),
        let closingParenthesis = closingParenthesis(
          after: NSMaxRange(uri),
          source: source
        )
      else {
        continue
      }
      let linkRange = NSRange(
        location: openingBracket,
        length: closingParenthesis + 1 - openingBracket
      )
      if let bounded = boundedCaptureRange(
        linkRange,
        source: source,
        requestedRange: requestedRange
      ) {
        ranges.append(bounded)
      }
    }
    return ranges
  }

  static func openingBracket(before location: Int, source: NSString) -> Int? {
    guard location > 0 else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location - 1, length: 0))
    var cursor = location - 1
    while cursor >= lineRange.location {
      if source.character(at: cursor) == 91,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor -= 1
    }
    return nil
  }

  static func closingBracket(after location: Int, source: NSString) -> Int? {
    guard location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = location
    while cursor < NSMaxRange(lineRange) {
      if source.character(at: cursor) == 93,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  static func closingParenthesis(after location: Int, source: NSString) -> Int? {
    guard location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = location
    while cursor < NSMaxRange(lineRange) {
      if source.character(at: cursor) == 41,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  static func isEscaped(_ source: NSString, at location: Int) -> Bool {
    var cursor = location
    var slashCount = 0
    while cursor > 0, source.character(at: cursor - 1) == 92 {
      slashCount += 1
      cursor -= 1
    }
    return slashCount.isMultiple(of: 2) == false
  }

  static func normalizedRuns(
    _ runs: [MarkdownSyntaxHighlightRun]
  ) -> [MarkdownSyntaxHighlightRun] {
    runs.sorted {
      if $0.range.location == $1.range.location {
        return $0.range.length < $1.range.length
      }
      return $0.range.location < $1.range.location
    }.reduce(into: []) { result, run in
      if result.last != run { result.append(run) }
    }
  }

  static func normalizedRanges(_ ranges: [NSRange]) -> [NSRange] {
    ranges.sorted {
      if $0.location == $1.location { return $0.length < $1.length }
      return $0.location < $1.location
    }.reduce(into: []) { result, range in
      if result.last != range { result.append(range) }
    }
  }

  static func excludingOverlaps(
    from orderedRanges: [NSRange],
    excludedBy orderedExcludedRanges: [NSRange]
  ) -> [NSRange] {
    guard !orderedRanges.isEmpty, !orderedExcludedRanges.isEmpty else {
      return orderedRanges
    }

    var includedRanges: [NSRange] = []
    includedRanges.reserveCapacity(orderedRanges.count)
    var excludedIndex = 0
    for range in orderedRanges {
      guard range.length > 0 else {
        includedRanges.append(range)
        continue
      }

      while excludedIndex < orderedExcludedRanges.count {
        let excludedRange = orderedExcludedRanges[excludedIndex]
        if excludedRange.location == NSNotFound
          || excludedRange.length == 0
          || NSMaxRange(excludedRange) <= range.location
        {
          excludedIndex += 1
        } else {
          break
        }
      }

      guard excludedIndex < orderedExcludedRanges.count else {
        includedRanges.append(range)
        continue
      }
      if orderedExcludedRanges[excludedIndex].location >= NSMaxRange(range) {
        includedRanges.append(range)
      }
    }
    return includedRanges
  }

  func append(
    _ ranges: [NSRange],
    style: MarkdownSyntaxHighlightStyle,
    offset: Int,
    to runs: inout [MarkdownSyntaxHighlightRun]
  ) {
    runs.append(
      contentsOf: ranges.map { range in
        MarkdownSyntaxHighlightRun(
          style: style,
          range: NSRange(location: offset + range.location, length: range.length)
        )
      })
  }

  static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

/// Ranges that can be emitted directly from tree-sitter highlight captures.
///
/// The Markdown queries intentionally expose punctuation captures rather than
/// editor-level constructs for headings, lists, and block quotes. Those three
/// styles therefore use a tiny line-prefix interpretation below to expand the
/// capture to the same source range the editor has historically applied. HTML
/// and strikethrough are not covered by the vendored queries and remain
/// explicit lightweight-lexer fallbacks.
struct MarkdownSyntaxCaptureRuns {
  var headings: [MarkdownSyntaxHighlightRun] = []
  var links: [NSRange] = []
  var lists: [NSRange] = []
  var quotes: [NSRange] = []
  var bold: [NSRange] = []
  var italic: [NSRange] = []
}

struct MarkdownSyntaxLexicalStyles: OptionSet {
  let rawValue: UInt8

  static let headings = Self(rawValue: 1 << 0)
  static let links = Self(rawValue: 1 << 1)
  static let lists = Self(rawValue: 1 << 2)
  static let quotes = Self(rawValue: 1 << 3)
  static let bold = Self(rawValue: 1 << 4)
  static let italic = Self(rawValue: 1 << 5)
  static let strikethrough = Self(rawValue: 1 << 6)
  static let html = Self(rawValue: 1 << 7)
  static let all: Self = [
    .headings,
    .links,
    .lists,
    .quotes,
    .bold,
    .italic,
    .strikethrough,
    .html,
  ]
}
