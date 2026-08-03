import Foundation

public struct MarkdownLineLocation: Equatable, Sendable {
  public var lineNumber: Int
  public var fullRange: NSRange
  public var contentRange: NSRange

  public init(lineNumber: Int, fullRange: NSRange, contentRange: NSRange) {
    self.lineNumber = lineNumber
    self.fullRange = fullRange
    self.contentRange = contentRange
  }
}

public struct MarkdownCursorPosition: Equatable, Sendable {
  public var line: Int
  public var column: Int
  public var utf16Column: Int
  public var location: Int
  public var lineLocation: MarkdownLineLocation

  public init(
    line: Int,
    column: Int,
    utf16Column: Int,
    location: Int,
    lineLocation: MarkdownLineLocation
  ) {
    self.line = line
    self.column = column
    self.utf16Column = utf16Column
    self.location = location
    self.lineLocation = lineLocation
  }
}

public struct MarkdownFenceMatch: Equatable, Sendable {
  public var marker: String
  public var markerLength: Int
  public var languageHint: String?
  public var openingLine: Int
  public var closingLine: Int?
  public var openingMarkerRange: NSRange
  public var closingMarkerRange: NSRange?
  public var bodyRange: NSRange
  public var fullRange: NSRange

  public init(
    marker: String,
    markerLength: Int,
    languageHint: String?,
    openingLine: Int,
    closingLine: Int?,
    openingMarkerRange: NSRange,
    closingMarkerRange: NSRange?,
    bodyRange: NSRange,
    fullRange: NSRange
  ) {
    self.marker = marker
    self.markerLength = markerLength
    self.languageHint = languageHint
    self.openingLine = openingLine
    self.closingLine = closingLine
    self.openingMarkerRange = openingMarkerRange
    self.closingMarkerRange = closingMarkerRange
    self.bodyRange = bodyRange
    self.fullRange = fullRange
  }

  public var isClosed: Bool {
    closingMarkerRange != nil
  }
}

public struct MarkdownCursorContextService: Sendable {
  public init() {}

  public func lineLocations(in markdown: String) -> [MarkdownLineLocation] {
    let source = markdown as NSString
    guard source.length > 0 else {
      return [
        MarkdownLineLocation(
          lineNumber: 1,
          fullRange: NSRange(location: 0, length: 0),
          contentRange: NSRange(location: 0, length: 0)
        )
      ]
    }

    var result: [MarkdownLineLocation] = []
    var location = 0
    while location < source.length {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      result.append(
        MarkdownLineLocation(
          lineNumber: result.count + 1,
          fullRange: NSRange(location: lineStart, length: lineEnd - lineStart),
          contentRange: NSRange(location: lineStart, length: contentsEnd - lineStart)
        )
      )
      location = max(lineEnd, location + 1)
    }

    let finalCharacter = source.character(at: source.length - 1)
    if finalCharacter == 10 || finalCharacter == 13 {
      result.append(
        MarkdownLineLocation(
          lineNumber: result.count + 1,
          fullRange: NSRange(location: source.length, length: 0),
          contentRange: NSRange(location: source.length, length: 0)
        )
      )
    }
    return result
  }

  public func position(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownCursorPosition? {
    let source = markdown as NSString
    guard selectedRange.location != NSNotFound else { return nil }
    let cursor = min(max(0, selectedRange.location), source.length)
    let lines = lineLocations(in: markdown)
    let line =
      lines.first { line in
        if line.fullRange.length == 0 {
          return cursor == line.fullRange.location
        }
        return cursor >= line.fullRange.location && cursor < NSMaxRange(line.fullRange)
      } ?? lines.last
    guard let line else { return nil }

    let contentEnd = NSMaxRange(line.contentRange)
    let prefixEnd = min(max(cursor, line.contentRange.location), contentEnd)
    let prefixRange = NSRange(
      location: line.contentRange.location,
      length: prefixEnd - line.contentRange.location
    )
    let prefix = source.substring(with: prefixRange)
    return MarkdownCursorPosition(
      line: line.lineNumber,
      column: prefix.count + 1,
      utf16Column: prefixRange.length + 1,
      location: cursor,
      lineLocation: line
    )
  }

  public func jumpTarget(
    in markdown: String,
    line requestedLine: Int,
    column requestedColumn: Int = 1
  ) -> NSRange? {
    guard requestedLine > 0, requestedColumn > 0 else { return nil }
    let source = markdown as NSString
    let lines = lineLocations(in: markdown)
    guard requestedLine <= lines.count else { return nil }
    let line = lines[requestedLine - 1]
    let content = source.substring(with: line.contentRange)
    let characterOffset = min(requestedColumn - 1, content.count)
    let stringIndex = content.index(content.startIndex, offsetBy: characterOffset)
    let utf16Offset = content[..<stringIndex].utf16.count
    return NSRange(location: line.contentRange.location + utf16Offset, length: 0)
  }

  public func fenceMatches(in markdown: String) -> [MarkdownFenceMatch] {
    let source = markdown as NSString
    let lines = lineLocations(in: markdown)
    var matches: [MarkdownFenceMatch] = []
    var active: OpeningFence?

    for line in lines {
      if let opening = active {
        guard
          let closing = closingFence(
            in: source,
            line: line,
            marker: opening.marker,
            minimumLength: opening.length
          )
        else {
          continue
        }
        let bodyStart = NSMaxRange(opening.line.fullRange)
        matches.append(
          MarkdownFenceMatch(
            marker: opening.markerString,
            markerLength: opening.length,
            languageHint: opening.languageHint,
            openingLine: opening.line.lineNumber,
            closingLine: line.lineNumber,
            openingMarkerRange: opening.markerRange,
            closingMarkerRange: closing.markerRange,
            bodyRange: NSRange(
              location: bodyStart,
              length: max(0, line.fullRange.location - bodyStart)
            ),
            fullRange: NSRange(
              location: opening.line.fullRange.location,
              length: NSMaxRange(line.fullRange) - opening.line.fullRange.location
            )
          )
        )
        active = nil
      } else if let opening = openingFence(in: source, line: line) {
        active = opening
      }
    }

    if let opening = active {
      let bodyStart = NSMaxRange(opening.line.fullRange)
      matches.append(
        MarkdownFenceMatch(
          marker: opening.markerString,
          markerLength: opening.length,
          languageHint: opening.languageHint,
          openingLine: opening.line.lineNumber,
          closingLine: nil,
          openingMarkerRange: opening.markerRange,
          closingMarkerRange: nil,
          bodyRange: NSRange(
            location: bodyStart,
            length: max(0, source.length - bodyStart)
          ),
          fullRange: NSRange(
            location: opening.line.fullRange.location,
            length: source.length - opening.line.fullRange.location
          )
        )
      )
    }
    return matches
  }

  public func fenceMatch(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownFenceMatch? {
    let sourceLength = (markdown as NSString).length
    guard selectedRange.location != NSNotFound else { return nil }
    let selection = NSRange(
      location: min(max(0, selectedRange.location), sourceLength),
      length: min(
        max(0, selectedRange.length),
        max(0, sourceLength - min(max(0, selectedRange.location), sourceLength))
      )
    )
    return fenceMatches(in: markdown).first { match in
      if selection.length > 0 {
        return NSIntersectionRange(selection, match.fullRange).length > 0
      }
      let end = NSMaxRange(match.fullRange)
      return selection.location >= match.fullRange.location
        && (selection.location < end || selection.location == sourceLength && end == sourceLength)
    }
  }

  public func counterpartFenceMarkerRange(
    in markdown: String,
    cursorLocation: Int
  ) -> NSRange? {
    guard
      let match = fenceMatch(
        in: markdown,
        selectedRange: NSRange(location: cursorLocation, length: 0)
      ), let closingRange = match.closingMarkerRange
    else {
      return nil
    }
    if containsCaret(cursorLocation, in: match.openingMarkerRange) {
      return closingRange
    }
    if containsCaret(cursorLocation, in: closingRange) {
      return match.openingMarkerRange
    }
    return nil
  }

  private func openingFence(
    in source: NSString,
    line: MarkdownLineLocation
  ) -> OpeningFence? {
    let end = NSMaxRange(line.contentRange)
    var cursor = line.contentRange.location
    var spaces = 0
    while cursor < end, source.character(at: cursor) == 32, spaces < 4 {
      spaces += 1
      cursor += 1
    }
    guard spaces <= 3, cursor < end else { return nil }
    let marker = source.character(at: cursor)
    guard marker == 96 || marker == 126 else { return nil }
    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == marker {
      cursor += 1
    }
    let markerLength = cursor - markerStart
    guard markerLength >= 3 else { return nil }

    let info = source.substring(
      with: NSRange(location: cursor, length: end - cursor)
    )
    if marker == 96, info.contains("`") { return nil }
    let languageHint =
      info
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .first
      .map(String.init)
    return OpeningFence(
      marker: marker,
      length: markerLength,
      languageHint: languageHint,
      markerRange: NSRange(location: markerStart, length: markerLength),
      line: line
    )
  }

  private func closingFence(
    in source: NSString,
    line: MarkdownLineLocation,
    marker: unichar,
    minimumLength: Int
  ) -> ClosingFence? {
    let end = NSMaxRange(line.contentRange)
    var cursor = line.contentRange.location
    var spaces = 0
    while cursor < end, source.character(at: cursor) == 32, spaces < 4 {
      spaces += 1
      cursor += 1
    }
    guard spaces <= 3, cursor < end, source.character(at: cursor) == marker else {
      return nil
    }
    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == marker {
      cursor += 1
    }
    guard cursor - markerStart >= minimumLength else { return nil }
    let markerEnd = cursor
    while cursor < end {
      let character = source.character(at: cursor)
      guard character == 32 || character == 9 else { return nil }
      cursor += 1
    }
    return ClosingFence(
      markerRange: NSRange(location: markerStart, length: markerEnd - markerStart)
    )
  }

  private func containsCaret(_ location: Int, in range: NSRange) -> Bool {
    location >= range.location && location <= NSMaxRange(range)
  }

  private struct OpeningFence {
    var marker: unichar
    var length: Int
    var languageHint: String?
    var markerRange: NSRange
    var line: MarkdownLineLocation

    var markerString: String {
      marker == 96 ? "`" : "~"
    }
  }

  private struct ClosingFence {
    var markerRange: NSRange
  }
}
