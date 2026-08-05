import Foundation
import OSLog

public enum MarkdownSyntaxHighlightStyle: String, Hashable, Sendable {
  case heading
  case codeBlock
  case link
  case list
  case quote
  case bold
  case italic
  case inlineCode
  case html
}

public struct MarkdownSyntaxHighlightRun: Hashable, Sendable {
  public var style: MarkdownSyntaxHighlightStyle
  public var range: NSRange

  public init(style: MarkdownSyntaxHighlightStyle, range: NSRange) {
    self.style = style
    self.range = range
  }
}

public struct MarkdownSyntaxHighlightSnapshot: Hashable, Sendable {
  public var range: NSRange
  public var runs: [MarkdownSyntaxHighlightRun]

  public init(range: NSRange, runs: [MarkdownSyntaxHighlightRun]) {
    self.range = range
    self.runs = runs
  }
}

public actor MarkdownSyntaxHighlightParser {
  private let signposter = OSSignposter(
    subsystem: "com.jinfang.PersonalSitePublisherMac",
    category: "MarkdownSyntax"
  )
  public init() {}

  public func snapshot(
    in markdown: String,
    range requestedRange: NSRange? = nil
  ) -> MarkdownSyntaxHighlightSnapshot? {
    guard !Task.isCancelled else { return nil }
    let source = markdown as NSString
    let range = requestedRange ?? NSRange(location: 0, length: source.length)
    guard Self.isValid(range, length: source.length) else { return nil }

    let signpostID = signposter.makeSignpostID()
    let intervalState = signposter.beginInterval(
      "SyntaxParse",
      id: signpostID,
      "documentLength: \(source.length, privacy: .public), rangeLength: \(range.length, privacy: .public)"
    )
    var completionState = 0
    var emittedRunCount = 0
    defer {
      signposter.endInterval(
        "SyntaxParse",
        intervalState,
        "completed: \(completionState, privacy: .public), runCount: \(emittedRunCount, privacy: .public)"
      )
    }

    let codeRanges = MarkdownCodeRangeScanner.scan(source, in: range)
    let codeBlockRanges = codeRanges.blockRanges
    let inlineCodeRanges = codeRanges.inlineRanges
    guard !Task.isCancelled else { return nil }

    let literalRanges = MarkdownCodeRangeScanResult(
      blockRanges: codeBlockRanges,
      inlineRanges: inlineCodeRanges
    ).allRanges
    guard let lexicalRuns = MarkdownSyntaxLightweightLexer.scan(
      source,
      in: range,
      blockRanges: codeBlockRanges,
      literalRanges: literalRanges
    ) else {
      return nil
    }

    var runs: [MarkdownSyntaxHighlightRun] = []
    append(lexicalRuns.headings, style: .heading, offset: 0, to: &runs)
    append(codeBlockRanges, style: .codeBlock, offset: 0, to: &runs)
    append(lexicalRuns.html, style: .html, offset: 0, to: &runs)
    append(lexicalRuns.links, style: .link, offset: 0, to: &runs)
    append(lexicalRuns.lists, style: .list, offset: 0, to: &runs)
    append(lexicalRuns.quotes, style: .quote, offset: 0, to: &runs)
    append(lexicalRuns.bold, style: .bold, offset: 0, to: &runs)
    append(lexicalRuns.italic, style: .italic, offset: 0, to: &runs)
    append(inlineCodeRanges, style: .inlineCode, offset: 0, to: &runs)
    guard !Task.isCancelled else { return nil }
    completionState = 1
    emittedRunCount = runs.count
    return MarkdownSyntaxHighlightSnapshot(range: range, runs: runs)
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
          || NSMaxRange(excludedRange) <= range.location {
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

  private func append(
    _ ranges: [NSRange],
    style: MarkdownSyntaxHighlightStyle,
    offset: Int,
    to runs: inout [MarkdownSyntaxHighlightRun]
  ) {
    runs.append(contentsOf: ranges.map { range in
      MarkdownSyntaxHighlightRun(
        style: style,
        range: NSRange(location: offset + range.location, length: range.length)
      )
    })
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

private struct MarkdownSyntaxLexicalRuns {
  var headings: [NSRange] = []
  var html: [NSRange] = []
  var links: [NSRange] = []
  var lists: [NSRange] = []
  var quotes: [NSRange] = []
  var bold: [NSRange] = []
  var italic: [NSRange] = []
}

/// A small UTF-16 lexer for the source-editor highlighting subset.
///
/// Code ranges are resolved first because fenced code carries state across
/// lines. The remaining constructs are found in three linear passes: block
/// prefixes, inline delimiters/links, and HTML. This keeps AppKit-compatible
/// coordinates without allocating one `String` per match or running seven
/// independent regular-expression engines.
private enum MarkdownSyntaxLightweightLexer {
  private static let backslash: unichar = 92
  private static let carriageReturn: unichar = 13
  private static let lineFeed: unichar = 10
  private static let space: unichar = 32
  private static let tab: unichar = 9
  private static let asterisk: unichar = 42

  static func scan(
    _ source: NSString,
    in scanRange: NSRange,
    blockRanges: [NSRange],
    literalRanges: [NSRange]
  ) -> MarkdownSyntaxLexicalRuns? {
    var result = MarkdownSyntaxLexicalRuns()
    guard scanLinePrefixes(
      source,
      in: scanRange,
      excluding: blockRanges,
      into: &result
    ),
    scanInline(
      source,
      in: scanRange,
      excluding: literalRanges,
      into: &result
    ),
    scanHTML(
      source,
      in: scanRange,
      excluding: literalRanges,
      into: &result
    ) else {
      return nil
    }
    return result
  }

  private static func scanLinePrefixes(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let upperBound = NSMaxRange(scanRange)
    var location = scanRange.location
    var excludedIndex = 0
    var nextCancellationCheck = 0
    while location < upperBound {
      if location >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = location + 4_096
      }
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      let boundedLineStart = max(lineStart, scanRange.location)
      let boundedContentsEnd = min(contentsEnd, upperBound)
      let lineRange = NSRange(
        location: boundedLineStart,
        length: max(0, boundedContentsEnd - boundedLineStart)
      )
      if containingRange(
        at: boundedLineStart,
        in: excludedRanges,
        index: &excludedIndex
      ) == nil {
        if isHeading(source, range: lineRange) { result.headings.append(lineRange) }
        if isList(source, range: lineRange) { result.lists.append(lineRange) }
        if isQuote(source, range: lineRange) { result.quotes.append(lineRange) }
      }
      location = max(lineEnd, location + 1)
    }
    return true
  }

  private static func scanInline(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let lowerBound = scanRange.location
    let upperBound = NSMaxRange(scanRange)
    var cursor = lowerBound
    var excludedIndex = 0
    var labelStart: Int?
    var linkStart: Int?
    var destinationStart: Int?
    var boldStart: Int?
    var italicStart: Int?
    var nextCancellationCheck = 0

    while cursor < upperBound {
      if cursor >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = cursor + 4_096
      }
      if let excluded = containingRange(
        at: cursor,
        in: excludedRanges,
        index: &excludedIndex
      ) {
        cursor = NSMaxRange(excluded)
        labelStart = nil
        linkStart = nil
        destinationStart = nil
        boldStart = nil
        italicStart = nil
        continue
      }

      let character = source.character(at: cursor)
      if character == lineFeed || character == carriageReturn {
        boldStart = nil
        italicStart = nil
      }

      if linkStart != nil {
        if character == 41, !isEscaped(source, at: cursor),
           let start = linkStart,
           let destination = destinationStart,
           cursor > destination {
          result.links.append(NSRange(location: start, length: cursor + 1 - start))
          linkStart = nil
          destinationStart = nil
        }
      } else if character == 91, !isEscaped(source, at: cursor) {
        if labelStart == nil { labelStart = cursor }
      } else if character == 93, !isEscaped(source, at: cursor) {
        if let start = labelStart,
           cursor > start + 1,
           cursor + 1 < upperBound,
           source.character(at: cursor + 1) == 40 {
          linkStart = start
          destinationStart = cursor + 2
          labelStart = nil
        } else {
          labelStart = nil
        }
      }

      if character == asterisk, !isEscaped(source, at: cursor) {
        var runEnd = cursor + 1
        while runEnd < upperBound, source.character(at: runEnd) == asterisk {
          runEnd += 1
        }
        let runLength = runEnd - cursor
        if runLength == 1 {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &italicStart,
            ranges: &result.italic
          )
        } else if runLength == 2 {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &boldStart,
            ranges: &result.bold
          )
        } else if runLength == 3 {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &boldStart,
            ranges: &result.bold
          )
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &italicStart,
            ranges: &result.italic
          )
        }
        cursor = runEnd
        continue
      }
      cursor += 1
    }
    return true
  }

  private static func scanHTML(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let upperBound = NSMaxRange(scanRange)
    var cursor = scanRange.location
    var excludedIndex = 0
    var commentStart: Int?
    var nextCancellationCheck = 0
    while cursor < upperBound {
      if cursor >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = cursor + 4_096
      }
      if let excluded = containingRange(
        at: cursor,
        in: excludedRanges,
        index: &excludedIndex
      ) {
        cursor = NSMaxRange(excluded)
        commentStart = nil
        continue
      }

      if let start = commentStart {
        if hasCharacters([45, 45, 62], in: source, at: cursor) {
          result.html.append(NSRange(location: start, length: cursor + 3 - start))
          commentStart = nil
          cursor += 3
        } else {
          cursor += 1
        }
        continue
      }

      guard source.character(at: cursor) == 60 else {
        cursor += 1
        continue
      }
      if hasCharacters([60, 33, 45, 45], in: source, at: cursor) {
        commentStart = cursor
        cursor += 4
        continue
      }
      if let end = htmlTagEnd(in: source, startingAt: cursor, upperBound: upperBound) {
        let overlapsLiteral = excludedIndex < excludedRanges.count
          && excludedRanges[excludedIndex].location < end
        if !overlapsLiteral {
          result.html.append(NSRange(location: cursor, length: end - cursor))
        }
        cursor = end
      } else {
        cursor += 1
      }
    }
    return true
  }

  private static func isHeading(_ source: NSString, range: NSRange) -> Bool {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, source.character(at: cursor) == 35, cursor - range.location < 7 {
      cursor += 1
    }
    let count = cursor - range.location
    return (1...6).contains(count)
      && cursor < end
      && isWhitespace(source.character(at: cursor))
  }

  private static func isList(_ source: NSString, range: NSRange) -> Bool {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, isWhitespace(source.character(at: cursor)) { cursor += 1 }
    guard cursor < end else { return false }

    let marker = source.character(at: cursor)
    if marker == 45 || marker == asterisk || marker == 43 {
      cursor += 1
    } else if isDigit(marker) {
      repeat { cursor += 1 } while cursor < end && isDigit(source.character(at: cursor))
      guard cursor < end, source.character(at: cursor) == 46 else { return false }
      cursor += 1
    } else {
      return false
    }
    return cursor < end && isWhitespace(source.character(at: cursor))
  }

  private static func isQuote(_ source: NSString, range: NSRange) -> Bool {
    range.length > 2
      && source.character(at: range.location) == 62
      && source.character(at: range.location + 1) == space
  }

  private static func pairDelimiter(
    _ source: NSString,
    start: Int,
    end: Int,
    upperBound: Int,
    opening: inout Int?,
    ranges: inout [NSRange]
  ) {
    let canClose = start > 0 && !isWhitespace(source.character(at: start - 1))
    let canOpen = end < upperBound && !isWhitespace(source.character(at: end))
    if let openingLocation = opening,
       canClose,
       start > openingLocation + (end - start) {
      ranges.append(NSRange(location: openingLocation, length: end - openingLocation))
      opening = nil
    } else if canOpen {
      opening = start
    }
  }

  private static func htmlTagEnd(
    in source: NSString,
    startingAt start: Int,
    upperBound: Int
  ) -> Int? {
    var cursor = start + 1
    guard cursor < upperBound else { return nil }
    if source.character(at: cursor) == 47 { cursor += 1 }
    guard cursor < upperBound, isASCIILetter(source.character(at: cursor)) else {
      return nil
    }
    cursor += 1
    while cursor < upperBound {
      let character = source.character(at: cursor)
      if character == 62 { return cursor + 1 }
      if character == 60 || character == lineFeed { return nil }
      cursor += 1
    }
    return nil
  }

  private static func containingRange(
    at location: Int,
    in ranges: [NSRange],
    index: inout Int
  ) -> NSRange? {
    while index < ranges.count, NSMaxRange(ranges[index]) <= location { index += 1 }
    guard index < ranges.count,
          ranges[index].location <= location,
          location < NSMaxRange(ranges[index]) else {
      return nil
    }
    return ranges[index]
  }

  private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
    var cursor = location
    var count = 0
    while cursor > 0, source.character(at: cursor - 1) == backslash {
      count += 1
      cursor -= 1
    }
    return count.isMultiple(of: 2) == false
  }

  private static func hasCharacters(
    _ characters: [unichar],
    in source: NSString,
    at location: Int
  ) -> Bool {
    guard location <= source.length - characters.count else { return false }
    for (offset, character) in characters.enumerated()
    where source.character(at: location + offset) != character {
      return false
    }
    return true
  }

  private static func isWhitespace(_ character: unichar) -> Bool {
    character == space || character == tab
  }

  private static func isDigit(_ character: unichar) -> Bool {
    character >= 48 && character <= 57
  }

  private static func isASCIILetter(_ character: unichar) -> Bool {
    (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
  }

}
