import Foundation

public struct MarkdownCodeRangeScanResult: Hashable, Sendable {
  public var blockRanges: [NSRange]
  public var inlineRanges: [NSRange]

  public init(blockRanges: [NSRange], inlineRanges: [NSRange]) {
    self.blockRanges = blockRanges
    self.inlineRanges = inlineRanges
  }

  public var allRanges: [NSRange] {
    Self.merged(blockRanges + inlineRanges)
  }

  private static func merged(_ ranges: [NSRange]) -> [NSRange] {
    let ordered = ranges
      .filter { $0.location != NSNotFound && $0.length > 0 }
      .sorted {
        if $0.location == $1.location { return $0.length > $1.length }
        return $0.location < $1.location
      }
    var result: [NSRange] = []
    for range in ordered {
      guard let last = result.last else {
        result.append(range)
        continue
      }
      if range.location < NSMaxRange(last) {
        result[result.count - 1] = NSRange(
          location: last.location,
          length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
        )
      } else {
        result.append(range)
      }
    }
    return result
  }
}

struct MarkdownFenceResynchronizationWindow: Equatable {
  var previousRange: NSRange
  var currentRange: NSRange
}

/// Finds Markdown regions whose contents must remain literal source.
///
/// The scanner deliberately works in UTF-16 so its ranges can be shared by
/// AppKit, diagnostics, and preview preparation without coordinate conversion.
public enum MarkdownCodeRangeScanner {
  public static func scan(_ markdown: String) -> MarkdownCodeRangeScanResult {
    scan(markdown as NSString)
  }

  /// Scans an already bridged UTF-16 source without creating another
  /// `String`/substring. The editor uses this overload to keep AppKit's
  /// UTF-16 coordinates throughout an incremental scan.
  static func scan(_ source: NSString) -> MarkdownCodeRangeScanResult {
    let blocks = blockRanges(in: source)
    let inline = inlineRanges(in: source, excluding: blocks)
    return MarkdownCodeRangeScanResult(blockRanges: blocks, inlineRanges: inline)
  }

  /// Scans only the requested UTF-16 range and keeps returned coordinates
  /// absolute. The editor passes line-padded ranges, so fenced-code state is
  /// bounded to the same incremental region as the lexer.
  static func scan(_ source: NSString, in range: NSRange) -> MarkdownCodeRangeScanResult {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          range.location <= source.length,
          range.length <= source.length - range.location else {
      return MarkdownCodeRangeScanResult(blockRanges: [], inlineRanges: [])
    }
    let blocks = blockRanges(in: source, within: range)
    let inline = inlineRanges(in: source, excluding: blocks, within: range)
    return MarkdownCodeRangeScanResult(blockRanges: blocks, inlineRanges: inline)
  }

  /// Returns true only when at least one line begins with a CommonMark-style
  /// fenced-code marker (up to three leading spaces, then 3+ backticks/tildes).
  public static func containsFenceLine(in markdown: String) -> Bool {
    let source = markdown as NSString
    return containsFenceLine(
      in: source,
      range: NSRange(location: 0, length: source.length)
    )
  }

  static func containsFenceLine(in source: NSString, range: NSRange) -> Bool {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          range.location <= source.length,
          range.length <= source.length - range.location,
          range.length > 0 else {
      return false
    }
    let upperBound = NSMaxRange(range)
    var location = range.location
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
      let boundedLineStart = max(lineStart, range.location)
      let boundedContentsEnd = min(contentsEnd, upperBound)
      if openingFence(
        source: source,
        lineRange: NSRange(
          location: boundedLineStart,
          length: max(0, boundedContentsEnd - boundedLineStart)
        )
      ) != nil {
        return true
      }
      location = max(lineEnd, location + 1)
    }
    return false
  }

  /// Finds the smallest line-aligned old/new windows after a structural fence
  /// edit where both scanners have returned to the outside-fence state in the
  /// unchanged suffix. If either side remains inside an unclosed fence, the
  /// corresponding window conservatively extends to EOF.
  static func fenceResynchronizationWindow(
    previous: NSString,
    current: NSString,
    previousAnchor: Int,
    currentAnchor: Int,
    replacedRange: NSRange,
    currentChangeRange: NSRange
  ) -> MarkdownFenceResynchronizationWindow {
    // This mapping relies on `current` being the direct result of replacing
    // `replacedRange` in `previous` with `currentChangeRange`. Outside that
    // single edit, old UTF-16 boundaries map to new ones by the same delta.
    let safePreviousAnchor = min(max(0, previousAnchor), previous.length)
    let safeCurrentAnchor = min(max(0, currentAnchor), current.length)
    let previousAffectedEnd = NSMaxRange(previous.lineRange(for: replacedRange))
    let currentAffectedEnd = NSMaxRange(current.lineRange(for: currentChangeRange))
    let delta = currentChangeRange.length - replacedRange.length
    var previousScanner = FenceBoundaryScanner(
      source: previous,
      location: safePreviousAnchor
    )
    var currentScanner = FenceBoundaryScanner(
      source: current,
      location: safeCurrentAnchor
    )
    var previousBoundary = previousScanner.nextOutsideBoundary(
      atOrAfter: previousAffectedEnd
    )
    var currentBoundary = currentScanner.nextOutsideBoundary(
      atOrAfter: currentAffectedEnd
    )

    while let oldBoundary = previousBoundary,
      let newBoundary = currentBoundary
    {
      let mappedOldBoundary = oldBoundary + delta
      if mappedOldBoundary == newBoundary {
        return MarkdownFenceResynchronizationWindow(
          previousRange: NSRange(
            location: safePreviousAnchor,
            length: oldBoundary - safePreviousAnchor
          ),
          currentRange: NSRange(
            location: safeCurrentAnchor,
            length: newBoundary - safeCurrentAnchor
          )
        )
      }
      if mappedOldBoundary < newBoundary {
        previousBoundary = previousScanner.nextOutsideBoundary(
          atOrAfter: previousAffectedEnd
        )
      } else {
        currentBoundary = currentScanner.nextOutsideBoundary(
          atOrAfter: currentAffectedEnd
        )
      }
    }

    return MarkdownFenceResynchronizationWindow(
      previousRange: NSRange(
        location: safePreviousAnchor,
        length: previous.length - safePreviousAnchor
      ),
      currentRange: NSRange(
        location: safeCurrentAnchor,
        length: current.length - safeCurrentAnchor
      )
    )
  }

  private struct Fence {
    var marker: unichar
    var length: Int
    var start: Int
  }

  private struct FenceBoundaryScanner {
    let source: NSString
    var location: Int
    var fence: Fence?

    mutating func nextOutsideBoundary(atOrAfter minimumBoundary: Int) -> Int? {
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
        let contentRange = NSRange(
          location: lineStart,
          length: max(0, contentsEnd - lineStart)
        )
        if let activeFence = fence {
          if MarkdownCodeRangeScanner.isClosingFence(
            activeFence,
            source: source,
            lineRange: contentRange
          ) {
            fence = nil
          }
        } else if let opening = MarkdownCodeRangeScanner.openingFence(
          source: source,
          lineRange: contentRange
        ) {
          fence = Fence(
            marker: opening.marker,
            length: opening.length,
            start: lineStart
          )
        }
        location = max(lineEnd, location + 1)
        let boundary = min(lineEnd, source.length)
        if fence == nil, boundary >= minimumBoundary {
          return boundary
        }
      }
      return nil
    }
  }

  private struct DelimiterRun {
    var range: NSRange
    var length: Int
  }

  private static func blockRanges(in source: NSString) -> [NSRange] {
    blockRanges(in: source, within: nil)
  }

  private static func blockRanges(
    in source: NSString,
    within requestedRange: NSRange?
  ) -> [NSRange] {
    guard source.length > 0 else { return [] }
    let lowerBound = requestedRange?.location ?? 0
    let upperBound = requestedRange.map(NSMaxRange) ?? source.length
    var ranges: [NSRange] = []
    var fence: Fence?
    var location = lowerBound

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
      let boundedLineStart = max(lineStart, lowerBound)
      let boundedContentsEnd = min(contentsEnd, upperBound)
      let contentRange = NSRange(
        location: boundedLineStart,
        length: max(0, boundedContentsEnd - boundedLineStart)
      )

      if let activeFence = fence {
        if isClosingFence(activeFence, source: source, lineRange: contentRange) {
          ranges.append(NSRange(
            location: activeFence.start,
            length: max(0, boundedContentsEnd - activeFence.start)
          ))
          fence = nil
        }
      } else if let opening = openingFence(source: source, lineRange: contentRange) {
        fence = Fence(
          marker: opening.marker,
          length: opening.length,
          start: boundedLineStart
        )
      } else if isIndentedCodeLine(source: source, lineRange: contentRange) {
        ranges.append(NSRange(
          location: boundedLineStart,
          length: max(0, min(lineEnd, upperBound) - boundedLineStart)
        ))
      }

      location = max(lineEnd, location + 1)
    }

    if let fence {
      ranges.append(NSRange(
        location: fence.start,
        length: max(0, upperBound - fence.start)
      ))
    }
    return merged(ranges)
  }

  private static func openingFence(
    source: NSString,
    lineRange: NSRange
  ) -> (marker: unichar, length: Int)? {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
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
    let length = cursor - markerStart
    guard length >= 3 else { return nil }
    if marker == 96 {
      while cursor < end {
        guard source.character(at: cursor) != 96 else { return nil }
        cursor += 1
      }
    }
    return (marker, length)
  }

  private static func isClosingFence(
    _ fence: Fence,
    source: NSString,
    lineRange: NSRange
  ) -> Bool {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var spaces = 0
    while cursor < end, source.character(at: cursor) == 32, spaces < 4 {
      spaces += 1
      cursor += 1
    }
    guard spaces <= 3, cursor < end,
          source.character(at: cursor) == fence.marker else { return false }
    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == fence.marker {
      cursor += 1
    }
    guard cursor - markerStart >= fence.length else { return false }
    while cursor < end {
      let character = source.character(at: cursor)
      guard character == 32 || character == 9 else { return false }
      cursor += 1
    }
    return true
  }

  private static func isIndentedCodeLine(
    source: NSString,
    lineRange: NSRange
  ) -> Bool {
    guard lineRange.length > 0 else { return false }
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    if source.character(at: cursor) == 9 { return true }
    var spaces = 0
    while cursor < end, source.character(at: cursor) == 32 {
      spaces += 1
      cursor += 1
      if spaces >= 4 { return cursor < end }
    }
    return false
  }

  private static func inlineRanges(
    in source: NSString,
    excluding blockRanges: [NSRange]
  ) -> [NSRange] {
    inlineRanges(in: source, excluding: blockRanges, within: nil)
  }

  private static func inlineRanges(
    in source: NSString,
    excluding blockRanges: [NSRange],
    within requestedRange: NSRange?
  ) -> [NSRange] {
    var runsByLength: [Int: [DelimiterRun]] = [:]
    var blockIndex = 0
    let upperBound = requestedRange.map(NSMaxRange) ?? source.length
    var cursor = requestedRange?.location ?? 0

    while cursor < upperBound {
      while blockIndex < blockRanges.count,
            NSMaxRange(blockRanges[blockIndex]) <= cursor {
        blockIndex += 1
      }
      if blockIndex < blockRanges.count,
         blockRanges[blockIndex].location <= cursor {
        cursor = NSMaxRange(blockRanges[blockIndex])
        continue
      }
      guard source.character(at: cursor) == 96 else {
        cursor += 1
        continue
      }
      let start = cursor
      while cursor < upperBound, source.character(at: cursor) == 96 {
        cursor += 1
      }
      let length = cursor - start
      runsByLength[length, default: []].append(DelimiterRun(
        range: NSRange(location: start, length: length),
        length: length
      ))
    }

    var candidates: [NSRange] = []
    for runs in runsByLength.values {
      var index = 0
      while index + 1 < runs.count {
        let opening = runs[index]
        let closing = runs[index + 1]
        candidates.append(NSRange(
          location: opening.range.location,
          length: NSMaxRange(closing.range) - opening.range.location
        ))
        index += 2
      }
    }

    candidates.sort {
      if $0.location == $1.location { return $0.length > $1.length }
      return $0.location < $1.location
    }
    var result: [NSRange] = []
    var consumedUntil = 0
    for candidate in candidates where candidate.location >= consumedUntil {
      result.append(candidate)
      consumedUntil = NSMaxRange(candidate)
    }
    return result
  }

  private static func merged(_ ranges: [NSRange]) -> [NSRange] {
    let ordered = ranges.sorted { $0.location < $1.location }
    var result: [NSRange] = []
    for range in ordered where range.length > 0 {
      guard let last = result.last else {
        result.append(range)
        continue
      }
      if range.location < NSMaxRange(last) {
        result[result.count - 1] = NSRange(
          location: last.location,
          length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
        )
      } else {
        result.append(range)
      }
    }
    return result
  }
}
