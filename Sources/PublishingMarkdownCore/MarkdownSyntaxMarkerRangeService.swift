import Foundation

public struct MarkdownSyntaxMarker: Hashable, Sendable {
  public enum Presentation: Hashable, Sendable {
    case hidden
    case unorderedList
    case orderedList(String)
    case taskList(isChecked: Bool)
    case quote
  }

  public var range: NSRange
  public var presentation: Presentation

  public init(range: NSRange, presentation: Presentation) {
    self.range = range
    self.presentation = presentation
  }
}

public enum MarkdownSyntaxMarkerRangeService {
  public static func markers(
    in markdown: String,
    snapshot: MarkdownSyntaxHighlightSnapshot,
    activeSelection: NSRange? = nil
  ) -> [MarkdownSyntaxMarker] {
    let source = markdown as NSString
    guard snapshot.range.location != NSNotFound,
      snapshot.range.location >= 0,
      snapshot.range.length >= 0,
      NSMaxRange(snapshot.range) <= source.length
    else { return [] }

    var result: [MarkdownSyntaxMarker] = []
    for run in snapshot.runs {
      guard NSMaxRange(run.range) <= source.length,
        !selection(activeSelection, touches: run.range)
      else { continue }
      result.append(contentsOf: markers(in: source, for: run))
    }
    return normalized(result)
  }

  public static func markerRanges(
    in markdown: String,
    snapshot: MarkdownSyntaxHighlightSnapshot,
    activeSelection: NSRange? = nil
  ) -> [NSRange] {
    markers(
      in: markdown,
      snapshot: snapshot,
      activeSelection: activeSelection
    ).map(\.range)
  }

  private static func markers(
    in source: NSString,
    for run: MarkdownSyntaxHighlightRun
  ) -> [MarkdownSyntaxMarker] {
    let ranges: [NSRange]
    switch run.style {
    case .heading, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
      ranges = headingMarkers(in: source, range: run.range)
    case .bold, .italic:
      ranges = pairedRepeatedMarkers(in: source, range: run.range, marker: 42)
    case .strikethrough:
      ranges = pairedRepeatedMarkers(in: source, range: run.range, marker: 126)
    case .inlineCode:
      ranges = pairedRepeatedMarkers(in: source, range: run.range, marker: 96)
    case .link:
      ranges = linkMarkers(in: source, range: run.range)
    case .codeBlock:
      ranges = codeFenceMarkers(in: source, range: run.range)
    case .list:
      return listMarkers(in: source, range: run.range)
    case .quote:
      return quoteMarkers(in: source, range: run.range)
    case .html:
      return []
    }
    return ranges.map { MarkdownSyntaxMarker(range: $0, presentation: .hidden) }
  }

  private static func listMarkers(
    in source: NSString,
    range: NSRange
  ) -> [MarkdownSyntaxMarker] {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
    guard cursor < end else { return [] }

    let markerStart = cursor
    let marker = source.character(at: cursor)
    var presentation: MarkdownSyntaxMarker.Presentation
    var supportsTaskMarker = false
    if marker == 45 || marker == 42 || marker == 43 {
      cursor += 1
      presentation = .unorderedList
      supportsTaskMarker = true
    } else if isDigit(marker) {
      repeat { cursor += 1 } while cursor < end && isDigit(source.character(at: cursor))
      guard cursor < end, source.character(at: cursor) == 46 else { return [] }
      let ordinal = source.substring(
        with: NSRange(location: markerStart, length: cursor - markerStart)
      )
      cursor += 1
      presentation = .orderedList(ordinal + ".")
    } else {
      return []
    }
    guard cursor < end, isHorizontalWhitespace(source.character(at: cursor)) else { return [] }
    repeat { cursor += 1 } while cursor < end && isHorizontalWhitespace(source.character(at: cursor))
    if supportsTaskMarker,
      cursor + 3 < end,
      source.character(at: cursor) == 91,
      source.character(at: cursor + 2) == 93,
      isHorizontalWhitespace(source.character(at: cursor + 3))
    {
      let state = source.character(at: cursor + 1)
      if state == 32 || state == 120 || state == 88 {
        cursor += 3
        repeat { cursor += 1 } while cursor < end && isHorizontalWhitespace(source.character(at: cursor))
        presentation = .taskList(isChecked: state == 120 || state == 88)
      }
    }
    return [
      MarkdownSyntaxMarker(
        range: NSRange(location: markerStart, length: cursor - markerStart),
        presentation: presentation
      )
    ]
  }

  private static func quoteMarkers(
    in source: NSString,
    range: NSRange
  ) -> [MarkdownSyntaxMarker] {
    guard range.length >= 2,
      source.character(at: range.location) == 62,
      isHorizontalWhitespace(source.character(at: range.location + 1))
    else { return [] }
    var end = range.location + 2
    while end < NSMaxRange(range), isHorizontalWhitespace(source.character(at: end)) { end += 1 }
    return [
      MarkdownSyntaxMarker(
        range: NSRange(location: range.location, length: end - range.location),
        presentation: .quote
      )
    ]
  }

  private static func headingMarkers(in source: NSString, range: NSRange) -> [NSRange] {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, source.character(at: cursor) == 35 { cursor += 1 }
    guard cursor > range.location else { return [] }
    if cursor < end, isHorizontalWhitespace(source.character(at: cursor)) {
      cursor += 1
    }
    return [NSRange(location: range.location, length: cursor - range.location)]
  }

  private static func pairedRepeatedMarkers(
    in source: NSString,
    range: NSRange,
    marker: unichar
  ) -> [NSRange] {
    let end = NSMaxRange(range)
    var openingEnd = range.location
    while openingEnd < end, source.character(at: openingEnd) == marker {
      openingEnd += 1
    }
    let openingLength = openingEnd - range.location
    guard openingLength > 0, openingLength * 2 <= range.length else { return [] }

    var closingStart = end
    while closingStart > openingEnd, source.character(at: closingStart - 1) == marker {
      closingStart -= 1
    }
    let closingLength = end - closingStart
    guard closingLength == openingLength else { return [] }
    return [
      NSRange(location: range.location, length: openingLength),
      NSRange(location: closingStart, length: closingLength),
    ]
  }

  private static func linkMarkers(in source: NSString, range: NSRange) -> [NSRange] {
    guard range.length >= 4,
      source.character(at: range.location) == 91,
      source.character(at: NSMaxRange(range) - 1) == 41
    else { return [] }
    let separator = source.range(
      of: "](",
      range: NSRange(location: range.location + 1, length: range.length - 2)
    )
    guard separator.location != NSNotFound else { return [] }
    return [
      NSRange(location: range.location, length: 1),
      NSRange(location: separator.location, length: NSMaxRange(range) - separator.location),
    ]
  }

  private static func codeFenceMarkers(in source: NSString, range: NSRange) -> [NSRange] {
    let end = NSMaxRange(range)
    guard range.length >= 3, end <= source.length else { return [] }

    var openingLineStart = 0
    var openingLineEnd = 0
    var openingContentsEnd = 0
    source.getLineStart(
      &openingLineStart,
      end: &openingLineEnd,
      contentsEnd: &openingContentsEnd,
      for: NSRange(location: range.location, length: 0)
    )
    let openingMarkerStart = markerStart(
      in: source,
      lineStart: max(openingLineStart, range.location),
      contentsEnd: min(openingContentsEnd, end)
    )
    guard let openingMarkerStart else { return [] }
    let marker = source.character(at: openingMarkerStart)
    guard repeatedMarkerLength(
      in: source,
      from: openingMarkerStart,
      limit: min(openingContentsEnd, end),
      marker: marker
    ) >= 3 else { return [] }

    var ranges = [
      NSRange(
        location: openingMarkerStart,
        length: min(openingContentsEnd, end) - openingMarkerStart
      )
    ]
    var lastContentLocation = end - 1
    while lastContentLocation > openingMarkerStart,
      isLineBreak(source.character(at: lastContentLocation))
    {
      lastContentLocation -= 1
    }
    var closingLineStart = 0
    var closingLineEnd = 0
    var closingContentsEnd = 0
    source.getLineStart(
      &closingLineStart,
      end: &closingLineEnd,
      contentsEnd: &closingContentsEnd,
      for: NSRange(location: lastContentLocation, length: 0)
    )
    guard closingLineStart > openingLineStart,
      let closingMarkerStart = markerStart(
        in: source,
        lineStart: max(closingLineStart, range.location),
        contentsEnd: min(closingContentsEnd, end)
      ),
      source.character(at: closingMarkerStart) == marker,
      repeatedMarkerLength(
        in: source,
        from: closingMarkerStart,
        limit: min(closingContentsEnd, end),
        marker: marker
      ) >= 3
    else { return ranges }
    ranges.append(
      NSRange(
        location: closingMarkerStart,
        length: min(closingContentsEnd, end) - closingMarkerStart
      )
    )
    return ranges
  }

  private static func markerStart(
    in source: NSString,
    lineStart: Int,
    contentsEnd: Int
  ) -> Int? {
    var cursor = lineStart
    var indentation = 0
    while cursor < contentsEnd,
      indentation < 3,
      isHorizontalWhitespace(source.character(at: cursor))
    {
      cursor += 1
      indentation += 1
    }
    guard cursor < contentsEnd else { return nil }
    let marker = source.character(at: cursor)
    return marker == 96 || marker == 126 ? cursor : nil
  }

  private static func repeatedMarkerLength(
    in source: NSString,
    from start: Int,
    limit: Int,
    marker: unichar
  ) -> Int {
    var cursor = start
    while cursor < limit, source.character(at: cursor) == marker { cursor += 1 }
    return cursor - start
  }

  private static func selection(_ selection: NSRange?, touches range: NSRange) -> Bool {
    guard let selection, selection.location != NSNotFound else { return false }
    if selection.length == 0 {
      return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(selection, range).length > 0
  }

  private static func normalized(_ markers: [MarkdownSyntaxMarker]) -> [MarkdownSyntaxMarker] {
    markers
      .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
      .sorted {
        $0.range.location == $1.range.location
          ? $0.range.length < $1.range.length
          : $0.range.location < $1.range.location
      }
      .reduce(into: []) { result, marker in
        guard result.last != marker else { return }
        result.append(marker)
      }
  }

  private static func isDigit(_ value: unichar) -> Bool {
    value >= 48 && value <= 57
  }

  private static func isHorizontalWhitespace(_ value: unichar) -> Bool {
    value == 32 || value == 9
  }

  private static func isLineBreak(_ value: unichar) -> Bool {
    value == 10 || value == 13
  }

}
