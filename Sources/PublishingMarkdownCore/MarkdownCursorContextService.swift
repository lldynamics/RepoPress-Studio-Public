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

/// A revision-bound snapshot of the cursor context used by the Markdown
/// composer.  Position and fence lookups share the line/fence scan that built
/// this value, so a view render can read both without rescanning the document.
public struct MarkdownCursorContextSnapshot: Equatable, Sendable {
  public let revision: UInt64
  public let selectedRange: NSRange
  public let position: MarkdownCursorPosition?
  public let fenceMatch: MarkdownFenceMatch?

  public init(
    revision: UInt64,
    selectedRange: NSRange,
    position: MarkdownCursorPosition?,
    fenceMatch: MarkdownFenceMatch?
  ) {
    self.revision = revision
    self.selectedRange = selectedRange
    self.position = position
    self.fenceMatch = fenceMatch
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
  private let indexCache: MarkdownCursorDocumentIndexCache

  public init() {
    indexCache = MarkdownCursorDocumentIndexCache()
  }

  /// Marks the current revision stale while retaining the previous source and
  /// index as the base for a single ordinary editor mutation.
  public func prepareForBodyChange() {
    indexCache.prepareForBodyChange()
  }

  /// Drops every cached source/index value. Use this for draft switches,
  /// conflict recovery, and other externally supplied body replacements.
  public func invalidateCache() {
    indexCache.invalidate()
  }

  /// Test-only visibility for proving that selection changes reuse the
  /// revision-bound index without putting cache details in the public API.
  var debugIndexBuildCount: Int {
    indexCache.currentBuildCount
  }

  /// Test-only visibility for proving that ordinary edits use the cached
  /// line/fence index instead of rebuilding it.
  var debugIncrementalUpdateCount: Int {
    indexCache.currentIncrementalUpdateCount
  }

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
    return position(in: source, cursor: cursor, lines: lines)
  }

  /// Builds one reusable snapshot for a body revision and selection.  The
  /// line locations are shared by the position and fence scans.
  public func snapshot(
    in markdown: String,
    selectedRange: NSRange,
    revision: UInt64
  ) -> MarkdownCursorContextSnapshot {
    let source = markdown as NSString
    guard selectedRange.location != NSNotFound else {
      return MarkdownCursorContextSnapshot(
        revision: revision,
        selectedRange: selectedRange,
        position: nil,
        fenceMatch: nil
      )
    }
    let cursor = min(max(0, selectedRange.location), source.length)
    let normalizedSelection = NSRange(
      location: cursor,
      length: min(
        max(0, selectedRange.length),
        max(0, source.length - cursor)
      )
    )
    let index = indexCache.index(
      for: revision,
      markdown: markdown,
      selectedRange: normalizedSelection,
      build: {
        makeDocumentIndex(in: markdown)
      },
      incremental: { previousSource, previousIndex, previousRevision, previousSelection in
        if let previousRevision, revision != previousRevision &+ 1 {
          return nil
        }
        return incrementallyUpdatingIndex(
          from: previousSource,
          previousIndex: previousIndex,
          previousSelection: previousSelection,
          to: markdown,
          selectedRange: normalizedSelection
        )
      }
    )
    let position =
      selectedRange.location == NSNotFound
      ? nil
      : self.position(in: source, cursor: cursor, lines: index.lines)
    let fenceMatch = fenceMatch(
      in: index.fences,
      selectedRange: normalizedSelection,
      sourceLength: source.length
    )
    return MarkdownCursorContextSnapshot(
      revision: revision,
      selectedRange: normalizedSelection,
      position: position,
      fenceMatch: fenceMatch
    )
  }

  private func position(
    in source: NSString,
    cursor: Int,
    lines: [MarkdownLineLocation]
  ) -> MarkdownCursorPosition? {
    guard !lines.isEmpty else { return nil }
    var lowerBound = 0
    var upperBound = lines.count
    while lowerBound < upperBound {
      let middle = (lowerBound + upperBound) / 2
      if lines[middle].fullRange.location <= cursor {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    let line = lines[max(0, lowerBound - 1)]

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
    return fenceMatches(in: source, lines: lines)
  }

  private func fenceMatches(
    in source: NSString,
    lines: [MarkdownLineLocation]
  ) -> [MarkdownFenceMatch] {
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
    let index = makeDocumentIndex(in: markdown)
    return fenceMatch(
      in: index.fences,
      selectedRange: selection,
      sourceLength: sourceLength
    )
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

  private func makeDocumentIndex(in markdown: String) -> MarkdownCursorDocumentIndex {
    let source = markdown as NSString
    let lines = lineLocations(in: markdown)
    return MarkdownCursorDocumentIndex(
      lines: lines,
      fences: fenceMatches(in: source, lines: lines)
    )
  }

  /// Applies a single editor edit to the cached line/fence index without
  /// rescanning the document. The editor supplies the previous and current
  /// selection through successive snapshots, which lets us identify ordinary
  /// insertions/deletions in O(1) UTF-16 metadata rather than diffing the whole
  /// body. Any edit that can change line structure or fence syntax returns nil
  /// and lets the caller perform the conservative full scan.
  private func incrementallyUpdatingIndex(
    from previousMarkdown: String,
    previousIndex: MarkdownCursorDocumentIndex,
    previousSelection: NSRange?,
    to markdown: String,
    selectedRange: NSRange
  ) -> MarkdownCursorDocumentIndex? {
    let previousSource = previousMarkdown as NSString
    let source = markdown as NSString
    guard
      let previousSelection,
      let edit = MarkdownCursorEdit(
        previousSource: previousSource,
        previousSelection: previousSelection,
        source: source,
        selectedRange: selectedRange
      )
    else {
      return nil
    }

    guard
      !containsLineBreak(in: previousSource, range: edit.previousRange),
      !containsLineBreak(in: source, range: edit.currentRange),
      !containsFenceMarker(in: previousSource, range: edit.previousRange),
      !containsFenceMarker(in: source, range: edit.currentRange),
      !editTouchesFenceMarkerLine(
        edit.previousRange,
        lines: previousIndex.lines,
        fences: previousIndex.fences
      )
    else {
      return nil
    }

    let delta = edit.currentRange.length - edit.previousRange.length
    let updatedLines = updatingLines(
      previousIndex.lines,
      edit: edit,
      delta: delta
    )
    let updatedFences = updatingFences(
      previousIndex.fences,
      edit: edit,
      previousSourceLength: previousSource.length,
      delta: delta
    )
    return MarkdownCursorDocumentIndex(
      lines: updatedLines,
      fences: updatedFences
    )
  }

  private func updatingLines(
    _ lines: [MarkdownLineLocation],
    edit: MarkdownCursorEdit,
    delta: Int
  ) -> [MarkdownLineLocation] {
    guard !lines.isEmpty else { return lines }
    let lineIndex = lineIndex(
      containing: edit.previousRange.location,
      in: lines
    )
    return lines.enumerated().map { index, line in
      if index < lineIndex {
        return line
      }
      if index == lineIndex {
        return MarkdownLineLocation(
          lineNumber: line.lineNumber,
          fullRange: NSRange(
            location: line.fullRange.location,
            length: max(0, line.fullRange.length + delta)
          ),
          contentRange: NSRange(
            location: line.contentRange.location,
            length: max(0, line.contentRange.length + delta)
          )
        )
      }
      return MarkdownLineLocation(
        lineNumber: line.lineNumber,
        fullRange: NSRange(
          location: line.fullRange.location + delta,
          length: line.fullRange.length
        ),
        contentRange: NSRange(
          location: line.contentRange.location + delta,
          length: line.contentRange.length
        )
      )
    }
  }

  private func updatingFences(
    _ fences: [MarkdownFenceMatch],
    edit: MarkdownCursorEdit,
    previousSourceLength: Int,
    delta: Int
  ) -> [MarkdownFenceMatch] {
    fences.map { fence in
      let fenceStart = fence.fullRange.location
      let fenceEnd = NSMaxRange(fence.fullRange)
      let editStart = edit.previousRange.location
      let editEnd = NSMaxRange(edit.previousRange)
      let isAtEndOfUnclosedFence =
        !fence.isClosed && editStart == previousSourceLength
        && editStart == fenceEnd
      let isInsideFence =
        editStart >= fenceStart
        && (editStart < fenceEnd || isAtEndOfUnclosedFence)

      guard isInsideFence else {
        guard editStart < fenceStart else { return fence }
        return shifting(fence, by: delta)
      }

      var updated = fence
      updated.bodyRange = adjustingRange(
        fence.bodyRange,
        edit: edit,
        delta: delta,
        extendsAtEnd: !fence.isClosed && editStart == fenceEnd
      )
      updated.fullRange = adjustingRange(
        fence.fullRange,
        edit: edit,
        delta: delta,
        extendsAtEnd: !fence.isClosed && editStart == fenceEnd
      )
      if let closingMarkerRange = fence.closingMarkerRange,
        closingMarkerRange.location >= editEnd
      {
        updated.closingMarkerRange = shiftingRange(closingMarkerRange, by: delta)
      }
      return updated
    }
  }

  private func adjustingRange(
    _ range: NSRange,
    edit: MarkdownCursorEdit,
    delta: Int,
    extendsAtEnd: Bool = false
  ) -> NSRange {
    let editStart = edit.previousRange.location
    let rangeEnd = NSMaxRange(range)
    if editStart >= rangeEnd && !extendsAtEnd {
      return range
    }
    if editStart < range.location {
      return shiftingRange(range, by: delta)
    }
    return NSRange(
      location: range.location,
      length: max(0, range.length + delta)
    )
  }

  private func shifting(_ fence: MarkdownFenceMatch, by delta: Int) -> MarkdownFenceMatch {
    var shifted = fence
    shifted.openingMarkerRange = shiftingRange(fence.openingMarkerRange, by: delta)
    shifted.closingMarkerRange = fence.closingMarkerRange.map {
      shiftingRange($0, by: delta)
    }
    shifted.bodyRange = shiftingRange(fence.bodyRange, by: delta)
    shifted.fullRange = shiftingRange(fence.fullRange, by: delta)
    return shifted
  }

  private func shiftingRange(_ range: NSRange, by delta: Int) -> NSRange {
    NSRange(location: range.location + delta, length: range.length)
  }

  private func lineIndex(
    containing location: Int,
    in lines: [MarkdownLineLocation]
  ) -> Int {
    var lowerBound = 0
    var upperBound = lines.count
    while lowerBound < upperBound {
      let middle = (lowerBound + upperBound) / 2
      if lines[middle].fullRange.location <= location {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return max(0, lowerBound - 1)
  }

  private func editTouchesFenceMarkerLine(
    _ editRange: NSRange,
    lines: [MarkdownLineLocation],
    fences: [MarkdownFenceMatch]
  ) -> Bool {
    let markerLocations = fences.flatMap { fence in
      var locations = [fence.openingMarkerRange.location]
      if let closingMarkerRange = fence.closingMarkerRange {
        locations.append(closingMarkerRange.location)
      }
      return locations
    }
    return markerLocations.contains { location in
      let markerLineIndex = lineIndex(containing: location, in: lines)
      let markerLine = lines[markerLineIndex]
      if editRange.length == 0 {
        return editRange.location >= markerLine.contentRange.location
          && editRange.location <= NSMaxRange(markerLine.contentRange)
      }
      return NSIntersectionRange(editRange, markerLine.contentRange).length > 0
    }
  }

  private func containsLineBreak(in source: NSString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    for location in range.location..<NSMaxRange(range) {
      let character = source.character(at: location)
      if character == 10 || character == 13 { return true }
    }
    return false
  }

  private func containsFenceMarker(in source: NSString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    for location in range.location..<NSMaxRange(range) {
      let character = source.character(at: location)
      if character == 96 || character == 126 { return true }
    }
    return false
  }

  private func fenceMatch(
    in fences: [MarkdownFenceMatch],
    selectedRange: NSRange,
    sourceLength: Int
  ) -> MarkdownFenceMatch? {
    guard !fences.isEmpty else { return nil }

    if selectedRange.length > 0 {
      // Find the first fence whose end is after the selection start. Fences
      // are emitted in source order and never overlap, so only this candidate
      // can intersect the selected range.
      var lowerBound = 0
      var upperBound = fences.count
      while lowerBound < upperBound {
        let middle = (lowerBound + upperBound) / 2
        if NSMaxRange(fences[middle].fullRange) <= selectedRange.location {
          lowerBound = middle + 1
        } else {
          upperBound = middle
        }
      }
      guard lowerBound < fences.count else { return nil }
      let candidate = fences[lowerBound]
      return NSIntersectionRange(selectedRange, candidate.fullRange).length > 0
        ? candidate
        : nil
    }

    // Find the last fence that starts at or before the caret. This keeps the
    // boundary behavior of the previous linear search, including a caret at
    // the end of an unclosed fence.
    var lowerBound = 0
    var upperBound = fences.count
    while lowerBound < upperBound {
      let middle = (lowerBound + upperBound) / 2
      if fences[middle].fullRange.location <= selectedRange.location {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound > 0 else {
      // A caret at the opening marker is covered by the first fence. The
      // lower-bound result is zero when the first range starts at zero, so
      // handle that boundary explicitly.
      let first = fences[0]
      let end = NSMaxRange(first.fullRange)
      return selectedRange.location >= first.fullRange.location
        && (selectedRange.location < end
          || selectedRange.location == sourceLength && end == sourceLength)
        ? first
        : nil
    }
    let candidate = fences[lowerBound - 1]
    let end = NSMaxRange(candidate.fullRange)
    return selectedRange.location >= candidate.fullRange.location
      && (selectedRange.location < end
        || selectedRange.location == sourceLength && end == sourceLength)
      ? candidate
      : nil
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

private struct MarkdownCursorEdit {
  let previousRange: NSRange
  let currentRange: NSRange

  init?(
    previousSource: NSString,
    previousSelection: NSRange,
    source: NSString,
    selectedRange: NSRange
  ) {
    guard
      previousSelection.location != NSNotFound,
      selectedRange.location != NSNotFound,
      previousSelection.length >= 0,
      selectedRange.length >= 0
    else {
      return nil
    }

    let previousLocation = min(
      max(0, previousSelection.location),
      previousSource.length
    )
    let currentLocation = min(
      max(0, selectedRange.location),
      source.length
    )
    let delta = source.length - previousSource.length

    if previousSelection.length > 0 {
      guard
        previousSelection.location <= previousSource.length,
        NSMaxRange(previousSelection) <= previousSource.length,
        selectedRange.length == 0
      else {
        return nil
      }
      let replacementLength = previousSelection.length + delta
      guard
        replacementLength >= 0,
        currentLocation == previousLocation + replacementLength
      else {
        return nil
      }
      previousRange = NSRange(
        location: previousLocation,
        length: previousSelection.length
      )
      currentRange = NSRange(
        location: previousLocation,
        length: replacementLength
      )
      return
    }

    guard selectedRange.length == 0 else { return nil }
    if delta > 0 {
      guard currentLocation == previousLocation + delta else { return nil }
      previousRange = NSRange(location: previousLocation, length: 0)
      currentRange = NSRange(location: previousLocation, length: delta)
    } else if delta < 0 {
      let deletionLength = -delta
      let deletionStart: Int
      if currentLocation == previousLocation {
        // Delete-forward keeps the caret in place.
        deletionStart = previousLocation
      } else {
        // Backspace moves the caret to the beginning of the removed range.
        guard previousLocation == currentLocation + deletionLength else {
          return nil
        }
        deletionStart = currentLocation
      }
      guard deletionStart + deletionLength <= previousSource.length else {
        return nil
      }
      previousRange = NSRange(location: deletionStart, length: deletionLength)
      currentRange = NSRange(location: deletionStart, length: 0)
    } else {
      // A same-length replacement at a zero-length selection carries no
      // reliable edit location. Let the conservative full scanner handle it.
      return nil
    }
  }
}

private struct MarkdownCursorDocumentIndex: Sendable {
  let lines: [MarkdownLineLocation]
  let fences: [MarkdownFenceMatch]
}

private final class MarkdownCursorDocumentIndexCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cachedRevision: UInt64?
  private var cachedBaseRevision: UInt64?
  private var cachedSource: String?
  private var cachedSelection: NSRange?
  private var cachedIndex: MarkdownCursorDocumentIndex?
  private var buildCount = 0
  private var incrementalUpdateCount = 0

  var currentBuildCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return buildCount
  }

  var currentIncrementalUpdateCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return incrementalUpdateCount
  }

  func index(
    for revision: UInt64,
    markdown: String,
    selectedRange: NSRange,
    build: () -> MarkdownCursorDocumentIndex,
    incremental: (
      _ previousSource: String,
      _ previousIndex: MarkdownCursorDocumentIndex,
      _ previousRevision: UInt64?,
      _ previousSelection: NSRange?
    ) -> MarkdownCursorDocumentIndex?
  ) -> MarkdownCursorDocumentIndex {
    lock.lock()
    defer { lock.unlock() }

    if cachedRevision == revision, let cachedIndex {
      cachedSelection = selectedRange
      return cachedIndex
    }

    let index: MarkdownCursorDocumentIndex
    if
      let cachedSource,
      let cachedIndex,
      let incrementalIndex = incremental(
        cachedSource,
        cachedIndex,
        cachedBaseRevision,
        cachedSelection
      )
    {
      index = incrementalIndex
      incrementalUpdateCount += 1
    } else {
      index = build()
      buildCount += 1
    }
    cachedRevision = revision
    cachedBaseRevision = revision
    cachedSource = markdown
    cachedSelection = selectedRange
    cachedIndex = index
    return index
  }

  func invalidate() {
    lock.lock()
    cachedRevision = nil
    cachedBaseRevision = nil
    cachedSource = nil
    cachedSelection = nil
    cachedIndex = nil
    lock.unlock()
  }

  func prepareForBodyChange() {
    lock.lock()
    cachedRevision = nil
    lock.unlock()
  }
}
