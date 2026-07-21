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

/// Finds Markdown regions whose contents must remain literal source.
///
/// The scanner deliberately works in UTF-16 so its ranges can be shared by
/// AppKit, diagnostics, and preview preparation without coordinate conversion.
public enum MarkdownCodeRangeScanner {
  public static func scan(_ markdown: String) -> MarkdownCodeRangeScanResult {
    let source = markdown as NSString
    let blocks = blockRanges(in: source)
    let inline = inlineRanges(in: source, excluding: blocks)
    return MarkdownCodeRangeScanResult(blockRanges: blocks, inlineRanges: inline)
  }

  private struct Fence {
    var marker: unichar
    var length: Int
    var start: Int
  }

  private struct DelimiterRun {
    var range: NSRange
    var length: Int
  }

  private static func blockRanges(in source: NSString) -> [NSRange] {
    guard source.length > 0 else { return [] }
    var ranges: [NSRange] = []
    var fence: Fence?
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
      let contentRange = NSRange(
        location: lineStart,
        length: max(0, contentsEnd - lineStart)
      )

      if let activeFence = fence {
        if isClosingFence(activeFence, source: source, lineRange: contentRange) {
          ranges.append(NSRange(
            location: activeFence.start,
            length: contentsEnd - activeFence.start
          ))
          fence = nil
        }
      } else if let opening = openingFence(source: source, lineRange: contentRange) {
        fence = Fence(
          marker: opening.marker,
          length: opening.length,
          start: lineStart
        )
      } else if isIndentedCodeLine(source: source, lineRange: contentRange) {
        ranges.append(NSRange(location: lineStart, length: lineEnd - lineStart))
      }

      location = max(lineEnd, location + 1)
    }

    if let fence {
      ranges.append(NSRange(
        location: fence.start,
        length: source.length - fence.start
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
      let info = source.substring(with: NSRange(location: cursor, length: end - cursor))
      guard !info.contains("`") else { return nil }
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
    var runsByLength: [Int: [DelimiterRun]] = [:]
    var blockIndex = 0
    var cursor = 0

    while cursor < source.length {
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
      while cursor < source.length, source.character(at: cursor) == 96 {
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
