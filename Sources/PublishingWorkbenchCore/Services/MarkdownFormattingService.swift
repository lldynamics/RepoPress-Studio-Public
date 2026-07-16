import Foundation

public enum MarkdownFormattingCommand: Equatable, Sendable {
  case bold
  case italic
  case link
  case heading(level: Int)
}

public struct MarkdownFormattingService: Sendable {
  public init() {}

  public func edit(
    in markdown: String,
    selectedRange: NSRange,
    command: MarkdownFormattingCommand
  ) -> MarkdownSmartEdit? {
    switch command {
    case .bold:
      return inlineEdit(in: markdown, selectedRange: selectedRange, delimiter: "**")
    case .italic:
      return inlineEdit(in: markdown, selectedRange: selectedRange, delimiter: "*")
    case .link:
      return linkEdit(in: markdown, selectedRange: selectedRange)
    case .heading(let level):
      return headingEdit(in: markdown, selectedRange: selectedRange, level: level)
    }
  }

  private func inlineEdit(
    in markdown: String,
    selectedRange: NSRange,
    delimiter: String
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length) else { return nil }
    let delimiterLength = (delimiter as NSString).length

    if selection.length == 0 {
      let replacement = delimiter + delimiter
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: replacement,
        selectedRange: NSRange(location: selection.location + delimiterLength, length: 0)
      )
    }

    let selectedText = source.substring(with: selection)
    let selectedSource = selectedText as NSString
    if selectedSource.length >= delimiterLength * 2,
       hasToggleableMarkers(aroundContentsOf: selectedText, delimiter: delimiter) {
      let innerRange = NSRange(
        location: delimiterLength,
        length: selectedSource.length - delimiterLength * 2
      )
      let innerText = selectedSource.substring(with: innerRange)
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: innerText,
        selectedRange: NSRange(location: selection.location, length: innerRange.length)
      )
    }

    if hasToggleableMarkers(
      around: selection,
      in: source,
      delimiter: delimiter
    ) {
      return MarkdownSmartEdit(
        replacedRange: NSRange(
          location: selection.location - delimiterLength,
          length: selection.length + delimiterLength * 2
        ),
        replacement: selectedText,
        selectedRange: NSRange(
          location: selection.location - delimiterLength,
          length: selection.length
        )
      )
    }

    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: delimiter + selectedText + delimiter,
      selectedRange: NSRange(
        location: selection.location + delimiterLength,
        length: selection.length
      )
    )
  }

  private func hasToggleableMarkers(
    aroundContentsOf text: String,
    delimiter: String
  ) -> Bool {
    if delimiter == "*" {
      let leadingCount = text.prefix { $0 == "*" }.count
      let trailingCount = text.reversed().prefix { $0 == "*" }.count
      return leadingCount % 2 == 1 && trailingCount % 2 == 1
    }
    return text.hasPrefix(delimiter) && text.hasSuffix(delimiter)
  }

  private func hasToggleableMarkers(
    around selection: NSRange,
    in source: NSString,
    delimiter: String
  ) -> Bool {
    let delimiterLength = (delimiter as NSString).length
    guard selection.location >= delimiterLength,
          NSMaxRange(selection) + delimiterLength <= source.length else {
      return false
    }

    if delimiter == "*" {
      var leadingCount = 0
      var location = selection.location - 1
      while location >= 0,
            source.substring(with: NSRange(location: location, length: 1)) == "*" {
        leadingCount += 1
        location -= 1
      }

      var trailingCount = 0
      location = NSMaxRange(selection)
      while location < source.length,
            source.substring(with: NSRange(location: location, length: 1)) == "*" {
        trailingCount += 1
        location += 1
      }
      return leadingCount % 2 == 1 && trailingCount % 2 == 1
    }

    return source.substring(with: NSRange(
      location: selection.location - delimiterLength,
      length: delimiterLength
    )) == delimiter
      && source.substring(with: NSRange(
        location: NSMaxRange(selection),
        length: delimiterLength
      )) == delimiter
  }

  private func linkEdit(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length) else { return nil }

    if selection.length == 0 {
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: "[](https://)",
        selectedRange: NSRange(location: selection.location + 1, length: 0)
      )
    }

    let selectedText = source.substring(with: selection)
    if let label = markdownLinkLabel(in: selectedText) {
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: label,
        selectedRange: NSRange(location: selection.location, length: (label as NSString).length)
      )
    }

    if let surroundingRange = surroundingLinkRange(in: source, selection: selection) {
      return MarkdownSmartEdit(
        replacedRange: surroundingRange,
        replacement: selectedText,
        selectedRange: NSRange(location: surroundingRange.location, length: selection.length)
      )
    }

    let label = selectedText
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: "]", with: #"\]"#)
    let destination = "https://"
    let replacement = "[\(label)](\(destination))"
    let destinationLocation = selection.location
      + ("[\(label)](" as NSString).length
    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: replacement,
      selectedRange: NSRange(
        location: destinationLocation,
        length: (destination as NSString).length
      )
    )
  }

  private func headingEdit(
    in markdown: String,
    selectedRange: NSRange,
    level: Int
  ) -> MarkdownSmartEdit? {
    guard (1 ... 6).contains(level) else { return nil }
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length),
          let affectedRange = affectedLineRange(in: source, selection: selection),
          !isInsideFencedCodeBlock(source, before: affectedRange.location) else {
      return nil
    }

    let block = source.substring(with: affectedRange) as NSString
    guard !containsFenceDelimiter(block) else { return nil }
    let lines = lineSegments(in: block)
    let isSingleEmptyLine = lines.count == 1 && lines[0].content.isEmpty
    var firstLinePrefixChange: MarkdownHeadingPrefixChange?

    let transformed = lines.enumerated().map { index, line -> String in
      guard !line.content.trimmedForPublishing.isEmpty || isSingleEmptyLine else {
        return line.content + line.ending
      }
      let result = formattedHeadingLine(line.content, level: level)
      if index == 0 {
        firstLinePrefixChange = result.prefixChange
      }
      return result.text + line.ending
    }
    .joined()

    let updatedSelection: NSRange
    if selection.length == 0, let prefixChange = firstLinePrefixChange {
      let relativeCursor = selection.location - affectedRange.location
      let location: Int
      if relativeCursor <= prefixChange.oldLength {
        location = affectedRange.location + prefixChange.newLength
      } else {
        location = selection.location + prefixChange.newLength - prefixChange.oldLength
      }
      updatedSelection = NSRange(location: max(affectedRange.location, location), length: 0)
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

  private func formattedHeadingLine(
    _ line: String,
    level: Int
  ) -> (text: String, prefixChange: MarkdownHeadingPrefixChange) {
    let source = line as NSString
    let pattern = #"^( {0,3})(#{1,6})[ \t]+"#
    let range = NSRange(location: 0, length: source.length)
    let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: range)

    if let match {
      let indentation = source.substring(with: match.range(at: 1))
      let currentLevel = match.range(at: 2).length
      let newPrefix = currentLevel == level
        ? indentation
        : indentation + String(repeating: "#", count: level) + " "
      let contents = source.substring(from: NSMaxRange(match.range))
      return (
        newPrefix + contents,
        MarkdownHeadingPrefixChange(oldLength: match.range.length, newLength: (newPrefix as NSString).length)
      )
    }

    let prefix = String(repeating: "#", count: level) + " "
    return (
      prefix + line,
      MarkdownHeadingPrefixChange(oldLength: 0, newLength: (prefix as NSString).length)
    )
  }

  private func markdownLinkLabel(in text: String) -> String? {
    let source = text as NSString
    let pattern = #"^\[([^\]]*)\]\((.+)\)$"#
    guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ), match.range.location == 0, match.range.length == source.length else {
      return nil
    }
    return source.substring(with: match.range(at: 1))
      .replacingOccurrences(of: #"\]"#, with: "]")
      .replacingOccurrences(of: #"\\"#, with: #"\"#)
  }

  private func surroundingLinkRange(in source: NSString, selection: NSRange) -> NSRange? {
    guard selection.location > 0,
          source.substring(with: NSRange(location: selection.location - 1, length: 1)) == "[",
          NSMaxRange(selection) + 2 <= source.length,
          source.substring(with: NSRange(location: NSMaxRange(selection), length: 2)) == "](" else {
      return nil
    }

    let suffix = source.substring(from: NSMaxRange(selection) + 2) as NSString
    let closingRange = suffix.range(of: ")")
    guard closingRange.location != NSNotFound else { return nil }
    return NSRange(
      location: selection.location - 1,
      length: selection.length + 3 + closingRange.location + 1
    )
  }

  private func affectedLineRange(in source: NSString, selection: NSRange) -> NSRange? {
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

  private func lineSegments(in block: NSString) -> [MarkdownFormattingLineSegment] {
    if block.length == 0 {
      return [MarkdownFormattingLineSegment(content: "", ending: "")]
    }
    var result: [MarkdownFormattingLineSegment] = []
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
      result.append(
        MarkdownFormattingLineSegment(
          content: block.substring(with: NSRange(location: location, length: contentsEnd - location)),
          ending: block.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
        )
      )
      location = lineEnd
    }
    return result
  }

  private func containsFenceDelimiter(_ block: NSString) -> Bool {
    lineSegments(in: block).contains { line in
      let trimmed = line.content.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
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

  private func clamped(_ range: NSRange, length: Int) -> NSRange? {
    guard range.location >= 0, range.length >= 0 else { return nil }
    let location = min(range.location, length)
    return NSRange(
      location: location,
      length: min(range.length, max(0, length - location))
    )
  }
}

private struct MarkdownHeadingPrefixChange {
  let oldLength: Int
  let newLength: Int
}

private struct MarkdownFormattingLineSegment {
  let content: String
  let ending: String
}
