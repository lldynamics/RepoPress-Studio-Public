import Foundation

public enum MarkdownIndentationDirection: Sendable {
  case indent
  case outdent
}

public struct MarkdownSmartEdit: Equatable, Sendable {
  public var replacedRange: NSRange
  public var replacement: String
  public var selectedRange: NSRange

  public init(
    replacedRange: NSRange,
    replacement: String,
    selectedRange: NSRange
  ) {
    self.replacedRange = replacedRange
    self.replacement = replacement
    self.selectedRange = selectedRange
  }

  public var changesText: Bool {
    replacedRange.length > 0 || !replacement.isEmpty
  }
}

public struct MarkdownSmartEditingService: Sendable {
  private let indentationUnit: String

  public init(indentationUnit: String = "  ") {
    self.indentationUnit = indentationUnit.isEmpty ? "  " : indentationUnit
  }

  public func newlineEdit(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard selectedRange.length == 0,
          selectedRange.location >= 0,
          selectedRange.location <= source.length else {
      return nil
    }

    let cursor = selectedRange.location
    let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
    guard !isInsideFencedCodeBlock(source, before: lineRange.location) else {
      return nil
    }

    let contentsEnd = lineContentsEnd(in: source, lineRange: lineRange)
    let fullLineRange = NSRange(
      location: lineRange.location,
      length: max(0, contentsEnd - lineRange.location)
    )
    let fullLine = source.substring(with: fullLineRange)

    if let marker = marker(in: fullLine), marker.content.trimmedForPublishing.isEmpty {
      return MarkdownSmartEdit(
        replacedRange: fullLineRange,
        replacement: "",
        selectedRange: NSRange(location: lineRange.location, length: 0)
      )
    }

    let beforeCursorRange = NSRange(
      location: lineRange.location,
      length: max(0, cursor - lineRange.location)
    )
    let beforeCursor = source.substring(with: beforeCursorRange)
    guard let marker = marker(in: beforeCursor) else {
      return nil
    }

    let replacement = "\n\(marker.continuation)"
    return MarkdownSmartEdit(
      replacedRange: selectedRange,
      replacement: replacement,
      selectedRange: NSRange(
        location: cursor + (replacement as NSString).length,
        length: 0
      )
    )
  }

  public func indentationEdit(
    in markdown: String,
    selectedRange: NSRange,
    direction: MarkdownIndentationDirection
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let clampedSelection = clamped(selectedRange, length: source.length),
          let affectedRange = affectedLineRange(in: source, selection: clampedSelection) else {
      return nil
    }

    let block = source.substring(with: affectedRange) as NSString
    let lines = lineSegments(in: block)
    let nonEmptyLines = lines.filter { !$0.content.trimmedForPublishing.isEmpty }
    guard !nonEmptyLines.isEmpty,
          nonEmptyLines.allSatisfy({ marker(in: $0.content) != nil }) else {
      return nil
    }

    var didChange = false
    var firstLineDelta = 0
    let transformed = lines.enumerated().map { index, line -> String in
      guard !line.content.trimmedForPublishing.isEmpty else {
        return line.content + line.ending
      }

      let updatedContent: String
      switch direction {
      case .indent:
        updatedContent = indentationUnit + line.content
      case .outdent:
        updatedContent = removingOneIndentationLevel(from: line.content)
      }

      let delta = (updatedContent as NSString).length - (line.content as NSString).length
      if index == 0 {
        firstLineDelta = delta
      }
      didChange = didChange || delta != 0
      return updatedContent + line.ending
    }
    .joined()

    guard didChange else {
      return MarkdownSmartEdit(
        replacedRange: NSRange(location: clampedSelection.location, length: 0),
        replacement: "",
        selectedRange: clampedSelection
      )
    }

    let updatedSelection: NSRange
    if clampedSelection.length == 0 {
      let lineStart = affectedRange.location
      updatedSelection = NSRange(
        location: max(lineStart, clampedSelection.location + firstLineDelta),
        length: 0
      )
    } else {
      updatedSelection = NSRange(
        location: affectedRange.location,
        length: (transformed as NSString).length
      )
    }

    return MarkdownSmartEdit(
      replacedRange: affectedRange,
      replacement: transformed,
      selectedRange: updatedSelection
    )
  }

  private func marker(in line: String) -> MarkdownLineMarker? {
    if let captures = captures(
      pattern: #"^([ \t]*)([-+*])[ \t]+\[([ xX])\][ \t]*(.*)$"#,
      in: line
    ) {
      return MarkdownLineMarker(
        continuation: "\(captures[0])\(captures[1]) [ ] ",
        content: captures[3]
      )
    }

    if let captures = captures(
      pattern: #"^([ \t]*)([0-9]+)([.)])[ \t]+(.*)$"#,
      in: line
    ), let number = nextOrderedListNumber(after: captures[1]) {
      return MarkdownLineMarker(
        continuation: "\(captures[0])\(number)\(captures[2]) ",
        content: captures[3]
      )
    }

    if let captures = captures(
      pattern: #"^([ \t]*)([0-9]+)(、)([ \t]*)(.*)$"#,
      in: line
    ), let number = nextOrderedListNumber(after: captures[1]) {
      return MarkdownLineMarker(
        continuation: "\(captures[0])\(number)\(captures[2])\(captures[3])",
        content: captures[4]
      )
    }

    if let captures = captures(
      pattern: #"^([ \t]*)([-+*])[ \t]+(.*)$"#,
      in: line
    ) {
      return MarkdownLineMarker(
        continuation: "\(captures[0])\(captures[1]) ",
        content: captures[2]
      )
    }

    if let captures = captures(
      pattern: #"^([ \t]*)(>+)[ \t]+(.*)$"#,
      in: line
    ) {
      return MarkdownLineMarker(
        continuation: "\(captures[0])\(captures[1]) ",
        content: captures[2]
      )
    }

    return nil
  }

  private func nextOrderedListNumber(after value: String) -> Int? {
    guard let number = Int(value) else { return nil }
    let (nextNumber, overflow) = number.addingReportingOverflow(1)
    return overflow ? nil : nextNumber
  }

  private func captures(pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let source = text as NSString
    let range = NSRange(location: 0, length: source.length)
    guard let match = regex.firstMatch(in: text, range: range),
          match.range == range else {
      return nil
    }

    return (1 ..< match.numberOfRanges).map { index in
      let captureRange = match.range(at: index)
      return captureRange.location == NSNotFound ? "" : source.substring(with: captureRange)
    }
  }

  private func isInsideFencedCodeBlock(_ source: NSString, before location: Int) -> Bool {
    guard location > 0 else { return false }
    let prefix = source.substring(to: min(location, source.length))
    var activeFence: Character?

    prefix.enumerateLines { line, _ in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let fence: Character?
      if trimmed.hasPrefix("```") {
        fence = "`"
      } else if trimmed.hasPrefix("~~~") {
        fence = "~"
      } else {
        fence = nil
      }

      guard let fence else { return }
      if activeFence == fence {
        activeFence = nil
      } else if activeFence == nil {
        activeFence = fence
      }
    }
    return activeFence != nil
  }

  private func lineContentsEnd(in source: NSString, lineRange: NSRange) -> Int {
    var contentsEnd = 0
    source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
    return contentsEnd
  }

  private func affectedLineRange(
    in source: NSString,
    selection: NSRange
  ) -> NSRange? {
    guard selection.location <= source.length else { return nil }
    let startLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
    guard selection.length > 0 else { return startLine }

    let lastSelectedLocation = max(selection.location, NSMaxRange(selection) - 1)
    let endLine = source.lineRange(for: NSRange(location: lastSelectedLocation, length: 0))
    return NSRange(
      location: startLine.location,
      length: NSMaxRange(endLine) - startLine.location
    )
  }

  private func lineSegments(in block: NSString) -> [MarkdownLineSegment] {
    guard block.length > 0 else { return [] }
    var segments: [MarkdownLineSegment] = []
    var location = 0

    while location < block.length {
      var lineEnd = 0
      var contentsEnd = 0
      block.getLineStart(
        nil,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      segments.append(
        MarkdownLineSegment(
          content: block.substring(with: NSRange(location: location, length: contentsEnd - location)),
          ending: block.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
        )
      )
      location = lineEnd
    }
    return segments
  }

  private func removingOneIndentationLevel(from line: String) -> String {
    if line.hasPrefix("\t") {
      return String(line.dropFirst())
    }

    var removableSpaces = 0
    for character in line.prefix(indentationUnit.count) {
      guard character == " " else { break }
      removableSpaces += 1
    }
    return String(line.dropFirst(removableSpaces))
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange? {
    guard range.location >= 0, range.length >= 0 else { return nil }
    let location = min(range.location, length)
    return NSRange(
      location: location,
      length: min(range.length, max(0, length - location))
    )
  }
}

private struct MarkdownLineMarker {
  let continuation: String
  let content: String
}

private struct MarkdownLineSegment {
  let content: String
  let ending: String
}
