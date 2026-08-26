import Foundation

public enum MarkdownAdvancedFormattingCommand: Equatable, Sendable {
  case bold
  case italic
  case strikethrough
  case inlineCode
  case blockquote
  case unorderedList
  case orderedList
  case taskList
  case removeFormatting
}

public enum MarkdownLineEditingCommand: Equatable, Sendable {
  case moveUp
  case moveDown
  case duplicateAbove
  case duplicateBelow
  case toggleTaskCompletion
  case deleteLine
  case toggleComment
}

/// Plans advanced Markdown edits without owning editor or undo state.
///
/// Every operation returns one `MarkdownSmartEdit`, so AppKit and SwiftUI
/// callers can apply it as a single undoable transaction.
public struct MarkdownAdvancedEditingService: Sendable {
  public init() {}

  public func formattingEdit(
    in markdown: String,
    selectedRange: NSRange,
    command: MarkdownAdvancedFormattingCommand
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length) else {
      return nil
    }

    switch command {
    case .bold:
      return inlineFormattingEdit(in: source, selection: selection, style: .bold)
    case .italic:
      return inlineFormattingEdit(in: source, selection: selection, style: .italic)
    case .strikethrough:
      return inlineFormattingEdit(in: source, selection: selection, style: .strikethrough)
    case .inlineCode:
      return inlineFormattingEdit(in: source, selection: selection, style: .inlineCode)
    case .blockquote:
      return blockFormattingEdit(in: source, selection: selection, style: .blockquote)
    case .unorderedList:
      return blockFormattingEdit(in: source, selection: selection, style: .unorderedList)
    case .orderedList:
      return blockFormattingEdit(in: source, selection: selection, style: .orderedList)
    case .taskList:
      return blockFormattingEdit(in: source, selection: selection, style: .taskList)
    case .removeFormatting:
      return removeFormattingEdit(in: source, selection: selection)
    }
  }

  public func lineEdit(
    in markdown: String,
    selectedRange: NSRange,
    command: MarkdownLineEditingCommand
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length),
      let affectedRange = affectedLineRange(in: source, selection: selection),
      !intersectsFencedCode(in: source, range: affectedRange)
    else {
      return nil
    }

    switch command {
    case .moveUp:
      return moveUpEdit(in: source, selection: selection, affectedRange: affectedRange)
    case .moveDown:
      return moveDownEdit(in: source, selection: selection, affectedRange: affectedRange)
    case .duplicateAbove:
      return duplicateEdit(
        in: source,
        selection: selection,
        affectedRange: affectedRange,
        above: true
      )
    case .duplicateBelow:
      return duplicateEdit(
        in: source,
        selection: selection,
        affectedRange: affectedRange,
        above: false
      )
    case .toggleTaskCompletion:
      return toggleTaskCompletionEdit(
        in: source,
        selection: selection,
        affectedRange: affectedRange
      )
    case .deleteLine:
      return deleteLineEdit(
        in: source,
        selection: selection,
        affectedRange: affectedRange
      )
    case .toggleComment:
      return toggleCommentEdit(
        in: source,
        selection: selection,
        affectedRange: affectedRange
      )
    }
  }

  /// Plans automatic symbol pairing for text the editor is about to insert.
  ///
  /// Supported inputs include ASCII and Chinese brackets and quotes, one
  /// backtick for inline code, and triple-backtick or triple-tilde fences.
  /// A zero-length replacement with a moved selection means "skip over the
  /// existing closing symbol".
  public func pairingEdit(
    in markdown: String,
    selectedRange: NSRange,
    typedText: String
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length) else {
      return nil
    }

    if typedText == "```" || typedText == "~~~" {
      return fencePairingEdit(in: source, selection: selection, fence: typedText)
    }

    let pairs: [String: String] = [
      "(": ")",
      "[": "]",
      "{": "}",
      "（": "）",
      "【": "】",
      "《": "》",
      "\"": "\"",
      "'": "'",
      "“": "”",
      "‘": "’",
      "`": "`",
    ]

    let closingSymbols = Set(pairs.values)
    if selection.length == 0,
      closingSymbols.contains(typedText) || pairs[typedText] == typedText,
      text(at: selection.location, length: typedText.utf16.count, in: source) == typedText
    {
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: "",
        selectedRange: NSRange(
          location: selection.location + typedText.utf16.count,
          length: 0
        )
      )
    }

    guard let closing = pairs[typedText] else { return nil }
    let selectedText = source.substring(with: selection)
    let replacement = typedText + selectedText + closing
    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: replacement,
      selectedRange: NSRange(
        location: selection.location + typedText.utf16.count,
        length: selection.length
      )
    )
  }

  private func inlineFormattingEdit(
    in source: NSString,
    selection: NSRange,
    style: MarkdownInlineStyle
  ) -> MarkdownSmartEdit? {
    let inspectionRange =
      selection.length == 0
      ? affectedLineRange(in: source, selection: selection) ?? selection
      : selection
    guard !intersectsFencedCode(in: source, range: inspectionRange) else {
      return nil
    }

    if selection.length == 0 {
      let marker = style.defaultMarker
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: marker + marker,
        selectedRange: NSRange(
          location: selection.location + marker.utf16.count,
          length: 0
        )
      )
    }

    let selectedText = source.substring(with: selection)
    if selectedText.contains(where: \.isNewline) {
      return multilineInlineFormattingEdit(
        selectedText,
        selection: selection,
        style: style
      )
    }

    if let unwrapped = unwrappedInlineText(selectedText, style: style) {
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: unwrapped,
        selectedRange: NSRange(
          location: selection.location,
          length: unwrapped.utf16.count
        )
      )
    }

    if let surroundingMarker = surroundingMarker(
      selection,
      in: source,
      style: style
    ) {
      let markerLength = surroundingMarker.utf16.count
      return MarkdownSmartEdit(
        replacedRange: NSRange(
          location: selection.location - markerLength,
          length: selection.length + markerLength * 2
        ),
        replacement: selectedText,
        selectedRange: NSRange(
          location: selection.location - markerLength,
          length: selection.length
        )
      )
    }

    let marker = wrappingMarker(for: selectedText, style: style)
    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: marker + selectedText + marker,
      selectedRange: NSRange(
        location: selection.location + marker.utf16.count,
        length: selection.length
      )
    )
  }

  private func multilineInlineFormattingEdit(
    _ selectedText: String,
    selection: NSRange,
    style: MarkdownInlineStyle
  ) -> MarkdownSmartEdit? {
    let block = selectedText as NSString
    let segments = lineSegments(in: block)
    let formattedSegments = segments.filter {
      !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard !formattedSegments.isEmpty else { return nil }

    let shouldRemove = formattedSegments.allSatisfy {
      unwrappedInlineText($0.content, style: style) != nil
    }
    let replacement = segments.map { segment -> String in
      guard !segment.content.trimmingCharacters(in: .whitespaces).isEmpty else {
        return segment.content + segment.ending
      }

      let content: String
      if shouldRemove {
        content = unwrappedInlineText(segment.content, style: style) ?? segment.content
      } else {
        let marker = wrappingMarker(for: segment.content, style: style)
        content = marker + segment.content + marker
      }
      return content + segment.ending
    }
    .joined()

    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: replacement,
      selectedRange: NSRange(
        location: selection.location,
        length: replacement.utf16.count
      )
    )
  }

  private func blockFormattingEdit(
    in source: NSString,
    selection: NSRange,
    style: MarkdownBlockStyle
  ) -> MarkdownSmartEdit? {
    guard let affectedRange = affectedLineRange(in: source, selection: selection),
      !intersectsFencedCode(in: source, range: affectedRange)
    else {
      return nil
    }

    let block = source.substring(with: affectedRange) as NSString
    let segments = lineSegments(in: block)
    let nonEmptyLines = segments.filter {
      !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard !nonEmptyLines.isEmpty else { return nil }

    let shouldRemove = nonEmptyLines.allSatisfy {
      parsedBlockLine($0.content).style == style
    }
    var orderedNumber = 1
    var firstPrefixChange: MarkdownPrefixChange?

    let replacement = segments.enumerated().map { index, segment -> String in
      guard !segment.content.trimmingCharacters(in: .whitespaces).isEmpty else {
        return segment.content + segment.ending
      }

      let parsed = parsedBlockLine(segment.content)
      let updated: String
      if shouldRemove {
        updated = parsed.indentation + parsed.content
      } else {
        let prefix: String
        switch style {
        case .blockquote:
          prefix = "> "
        case .unorderedList:
          prefix = "- "
        case .orderedList:
          prefix = "\(orderedNumber). "
          orderedNumber += 1
        case .taskList:
          prefix = "- [ ] "
        }
        updated = parsed.indentation + prefix + parsed.content
      }

      if index == 0 {
        firstPrefixChange = MarkdownPrefixChange(
          oldLength: parsed.prefix.utf16.count,
          newLength: max(
            0, updated.utf16.count - parsed.content.utf16.count - parsed.indentation.utf16.count)
        )
      }
      return updated + segment.ending
    }
    .joined()

    let updatedSelection = selectionAfterLineTransformation(
      originalSelection: selection,
      affectedRange: affectedRange,
      replacement: replacement,
      firstPrefixChange: firstPrefixChange
    )
    return MarkdownSmartEdit(
      replacedRange: affectedRange,
      replacement: replacement,
      selectedRange: updatedSelection
    )
  }

  private func removeFormattingEdit(
    in source: NSString,
    selection: NSRange
  ) -> MarkdownSmartEdit? {
    let editRange: NSRange
    if selection.length == 0 {
      guard let lineRange = affectedLineRange(in: source, selection: selection) else {
        return nil
      }
      editRange = lineContentsRange(in: source, lineRange: lineRange)
    } else {
      editRange = selection
    }

    guard !intersectsFencedCode(in: source, range: editRange) else {
      return nil
    }

    let selectedText = source.substring(with: editRange) as NSString
    let segments = lineSegments(in: selectedText)
    let replacement = segments.map { segment -> String in
      let parsed = parsedBlockLine(segment.content)
      return parsed.indentation
        + removingInlineFormatting(from: parsed.content)
        + segment.ending
    }
    .joined()
    guard replacement != selectedText as String else { return nil }

    return MarkdownSmartEdit(
      replacedRange: editRange,
      replacement: replacement,
      selectedRange: NSRange(
        location: editRange.location,
        length: replacement.utf16.count
      )
    )
  }

  private func moveUpEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    guard affectedRange.location > 0 else { return nil }
    let previousRange = source.lineRange(
      for: NSRange(location: affectedRange.location - 1, length: 0)
    )
    let combinedRange = NSRange(
      location: previousRange.location,
      length: NSMaxRange(affectedRange) - previousRange.location
    )
    let parts = lineSegments(in: source.substring(with: combinedRange) as NSString)
    let selectedParts = lineSegments(
      in: source.substring(with: affectedRange) as NSString
    )
    guard parts.count == selectedParts.count + 1 else { return nil }

    let order = Array(1..<parts.count) + [0]
    let reordered = reorderedSegments(parts, order: order)
    let movedParts = Array(reordered.prefix(selectedParts.count))
    let replacement = reordered.map(\.fullText).joined()
    let movedText = movedParts.map(\.fullText).joined()
    let selectedRange = movedSelection(
      originalSelection: selection,
      originalRange: affectedRange,
      originalSegments: selectedParts,
      movedLocation: combinedRange.location,
      movedSegments: movedParts,
      movedTextLength: movedText.utf16.count
    )

    return MarkdownSmartEdit(
      replacedRange: combinedRange,
      replacement: replacement,
      selectedRange: selectedRange
    )
  }

  private func moveDownEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    guard NSMaxRange(affectedRange) < source.length else { return nil }
    let nextRange = source.lineRange(
      for: NSRange(location: NSMaxRange(affectedRange), length: 0)
    )
    let combinedRange = NSRange(
      location: affectedRange.location,
      length: NSMaxRange(nextRange) - affectedRange.location
    )
    let parts = lineSegments(in: source.substring(with: combinedRange) as NSString)
    let selectedParts = lineSegments(
      in: source.substring(with: affectedRange) as NSString
    )
    guard parts.count == selectedParts.count + 1 else { return nil }

    let order = [parts.count - 1] + Array(0..<parts.count - 1)
    let reordered = reorderedSegments(parts, order: order)
    let movedParts = Array(reordered.dropFirst())
    let replacement = reordered.map(\.fullText).joined()
    let firstPartLength = reordered[0].fullText.utf16.count
    let movedText = movedParts.map(\.fullText).joined()
    let movedLocation = combinedRange.location + firstPartLength
    let selectedRange = movedSelection(
      originalSelection: selection,
      originalRange: affectedRange,
      originalSegments: selectedParts,
      movedLocation: movedLocation,
      movedSegments: movedParts,
      movedTextLength: movedText.utf16.count
    )

    return MarkdownSmartEdit(
      replacedRange: combinedRange,
      replacement: replacement,
      selectedRange: selectedRange
    )
  }

  private func duplicateEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange,
    above: Bool
  ) -> MarkdownSmartEdit? {
    let block = source.substring(with: affectedRange)
    guard !block.isEmpty else { return nil }
    let newline = preferredNewline(in: source as String)
    let hasTrailingNewline = block.last?.isNewline == true

    let insertionLocation: Int
    let insertion: String
    let duplicateLocation: Int
    if above {
      insertionLocation = affectedRange.location
      insertion = hasTrailingNewline ? block : block + newline
      duplicateLocation = insertionLocation
    } else {
      insertionLocation = NSMaxRange(affectedRange)
      insertion = hasTrailingNewline ? block : newline + block
      duplicateLocation = insertionLocation + (hasTrailingNewline ? 0 : newline.utf16.count)
    }

    let selectedRange: NSRange
    if selection.length == 0 {
      let relativeCursor = max(0, selection.location - affectedRange.location)
      selectedRange = NSRange(
        location: duplicateLocation + min(relativeCursor, block.utf16.count),
        length: 0
      )
    } else {
      selectedRange = NSRange(
        location: duplicateLocation,
        length: block.utf16.count
      )
    }

    return MarkdownSmartEdit(
      replacedRange: NSRange(location: insertionLocation, length: 0),
      replacement: insertion,
      selectedRange: selectedRange
    )
  }

  private func toggleTaskCompletionEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    let block = source.substring(with: affectedRange) as NSString
    let segments = lineSegments(in: block)
    let taskStates = segments.compactMap { taskState(in: $0.content) }
    guard !taskStates.isEmpty else { return nil }
    let shouldCheck = taskStates.contains(false)

    var didChange = false
    let replacement = segments.map { segment -> String in
      guard let match = taskMatch(in: segment.content) else {
        return segment.fullText
      }
      let sourceLine = segment.content as NSString
      let marker = shouldCheck ? "x" : " "
      let updated = sourceLine.replacingCharacters(
        in: match.range(at: 3),
        with: marker
      )
      didChange = didChange || updated != segment.content
      return updated + segment.ending
    }
    .joined()
    guard didChange else { return nil }

    return MarkdownSmartEdit(
      replacedRange: affectedRange,
      replacement: replacement,
      selectedRange: selection.length == 0
        ? selection
        : NSRange(location: affectedRange.location, length: replacement.utf16.count)
    )
  }

  private func deleteLineEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    var rangeToDelete = affectedRange
    // If deleting the last line which has no trailing newline, consume preceding newline if available
    if NSMaxRange(rangeToDelete) == source.length, rangeToDelete.location > 0 {
      let prevCharRange = NSRange(location: rangeToDelete.location - 1, length: 1)
      let prevChar = source.substring(with: prevCharRange)
      if prevChar == "\n" || prevChar == "\r" {
        rangeToDelete = NSRange(location: rangeToDelete.location - 1, length: rangeToDelete.length + 1)
      }
    }
    let remainingLength = max(0, source.length - rangeToDelete.length)
    let newCursorLocation = min(rangeToDelete.location, remainingLength)
    return MarkdownSmartEdit(
      replacedRange: rangeToDelete,
      replacement: "",
      selectedRange: NSRange(location: newCursorLocation, length: 0)
    )
  }

  private func toggleCommentEdit(
    in source: NSString,
    selection: NSRange,
    affectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    let block = source.substring(with: affectedRange) as NSString
    let segments = lineSegments(in: block)
    guard !segments.isEmpty else { return nil }

    let commentPrefix = "<!-- "
    let commentSuffix = " -->"
    let compactPrefix = "<!--"
    let compactSuffix = "-->"

    let isCommented: (String) -> Bool = { content in
      let trimmed = content.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return true }
      return trimmed.hasPrefix(compactPrefix) && trimmed.hasSuffix(compactSuffix)
    }

    let nonWhitespaceSegments = segments.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
    let allCommented = !nonWhitespaceSegments.isEmpty && nonWhitespaceSegments.allSatisfy { isCommented($0.content) }

    let replacement = segments.map { segment -> String in
      let content = segment.content
      let trimmed = content.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return segment.fullText }

      if allCommented {
        var unwrapped = trimmed
        if unwrapped.hasPrefix(commentPrefix) {
          unwrapped = String(unwrapped.dropFirst(commentPrefix.count))
        } else if unwrapped.hasPrefix(compactPrefix) {
          unwrapped = String(unwrapped.dropFirst(compactPrefix.count))
        }
        if unwrapped.hasSuffix(commentSuffix) {
          unwrapped = String(unwrapped.dropLast(commentSuffix.count))
        } else if unwrapped.hasSuffix(compactSuffix) {
          unwrapped = String(unwrapped.dropLast(compactSuffix.count))
        }
        let parsed = parsedBlockLine(content)
        return parsed.indentation + unwrapped + segment.ending
      } else {
        let parsed = parsedBlockLine(content)
        return parsed.indentation + commentPrefix + parsed.content + commentSuffix + segment.ending
      }
    }.joined()

    return MarkdownSmartEdit(
      replacedRange: affectedRange,
      replacement: replacement,
      selectedRange: selection.length == 0
        ? NSRange(location: min(selection.location, affectedRange.location + replacement.utf16.count), length: 0)
        : NSRange(location: affectedRange.location, length: replacement.utf16.count)
    )
  }

  private func fencePairingEdit(
    in source: NSString,
    selection: NSRange,
    fence: String
  ) -> MarkdownSmartEdit {
    let selectedText = source.substring(with: selection)
    let newline = preferredNewline(in: source as String)
    if selection.length == 0 {
      let replacement = fence + newline + newline + fence
      return MarkdownSmartEdit(
        replacedRange: selection,
        replacement: replacement,
        selectedRange: NSRange(
          location: selection.location + fence.utf16.count + newline.utf16.count,
          length: 0
        )
      )
    }

    let suffix = selectedText.last?.isNewline == true ? fence : newline + fence
    let prefix = fence + newline
    return MarkdownSmartEdit(
      replacedRange: selection,
      replacement: prefix + selectedText + suffix,
      selectedRange: NSRange(
        location: selection.location + prefix.utf16.count,
        length: selection.length
      )
    )
  }

  private func unwrappedInlineText(
    _ text: String,
    style: MarkdownInlineStyle
  ) -> String? {
    let source = text as NSString
    switch style {
    case .bold:
      return unwrapped(source, markerLength: 2, character: "*")
        ?? unwrapped(source, markerLength: 2, character: "_")
    case .italic:
      if let value = unwrappedOddMarker(source, character: "*") {
        return value
      }
      return unwrappedOddMarker(source, character: "_")
    case .strikethrough:
      return unwrapped(source, markerLength: 2, character: "~")
    case .inlineCode:
      let leading = repeatedCharacterCount("`", fromStartOf: source)
      let trailing = repeatedCharacterCount("`", fromEndOf: source)
      guard leading > 0,
        leading == trailing,
        source.length >= leading * 2
      else {
        return nil
      }
      return source.substring(
        with: NSRange(
          location: leading,
          length: source.length - leading * 2
        ))
    }
  }

  private func unwrapped(
    _ source: NSString,
    markerLength: Int,
    character: String
  ) -> String? {
    guard source.length >= markerLength * 2,
      repeatedCharacterCount(character, fromStartOf: source) >= markerLength,
      repeatedCharacterCount(character, fromEndOf: source) >= markerLength
    else {
      return nil
    }
    return source.substring(
      with: NSRange(
        location: markerLength,
        length: source.length - markerLength * 2
      ))
  }

  private func unwrappedOddMarker(
    _ source: NSString,
    character: String
  ) -> String? {
    let leading = repeatedCharacterCount(character, fromStartOf: source)
    let trailing = repeatedCharacterCount(character, fromEndOf: source)
    guard leading % 2 == 1,
      trailing % 2 == 1,
      source.length >= 2
    else {
      return nil
    }
    return source.substring(with: NSRange(location: 1, length: source.length - 2))
  }

  private func surroundingMarker(
    _ selection: NSRange,
    in source: NSString,
    style: MarkdownInlineStyle
  ) -> String? {
    let character: String
    let requiredCount: Int
    switch style {
    case .bold:
      character = "*"
      requiredCount = 2
    case .italic:
      character = "*"
      requiredCount = 1
    case .strikethrough:
      character = "~"
      requiredCount = 2
    case .inlineCode:
      character = "`"
      requiredCount = 1
    }

    let leading = repeatedCharacterCount(
      character,
      before: selection.location,
      in: source
    )
    let trailing = repeatedCharacterCount(
      character,
      after: NSMaxRange(selection),
      in: source
    )

    let markerCount: Int
    switch style {
    case .italic:
      guard leading % 2 == 1, trailing % 2 == 1 else { return nil }
      markerCount = 1
    case .inlineCode:
      guard leading > 0, leading == trailing else { return nil }
      markerCount = leading
    case .bold, .strikethrough:
      guard leading >= requiredCount, trailing >= requiredCount else { return nil }
      markerCount = requiredCount
    }
    return String(repeating: character, count: markerCount)
  }

  private func wrappingMarker(
    for text: String,
    style: MarkdownInlineStyle
  ) -> String {
    guard style == .inlineCode else { return style.defaultMarker }
    let source = text as NSString
    var longestRun = 0
    var currentRun = 0
    for index in 0..<source.length {
      if source.substring(with: NSRange(location: index, length: 1)) == "`" {
        currentRun += 1
        longestRun = max(longestRun, currentRun)
      } else {
        currentRun = 0
      }
    }
    return String(repeating: "`", count: max(1, longestRun + 1))
  }

  private func parsedBlockLine(_ line: String) -> MarkdownParsedBlockLine {
    let patterns: [(MarkdownBlockStyle, String, Int, Int)] = [
      (.taskList, #"^([ \t]*)([-+*][ \t]+\[[ xX]\][ \t]*)(.*)$"#, 1, 3),
      (.blockquote, #"^([ \t]*)(>+[ \t]+)(.*)$"#, 1, 3),
      (.orderedList, #"^([ \t]*)([0-9]+[.)][ \t]+)(.*)$"#, 1, 3),
      (.orderedList, #"^([ \t]*)([0-9]+、[ \t]*)(.*)$"#, 1, 3),
      (.unorderedList, #"^([ \t]*)([-+*][ \t]+)(.*)$"#, 1, 3),
    ]

    for (style, pattern, indentationIndex, contentIndex) in patterns {
      guard let match = firstMatch(pattern: pattern, in: line) else { continue }
      let source = line as NSString
      let indentation = source.substring(with: match.range(at: indentationIndex))
      let prefixRange = match.range(at: 2)
      return MarkdownParsedBlockLine(
        indentation: indentation,
        prefix: source.substring(with: prefixRange),
        content: source.substring(with: match.range(at: contentIndex)),
        style: style
      )
    }

    let source = line as NSString
    let indentationMatch = firstMatch(pattern: #"^([ \t]*)(.*)$"#, in: line)
    let indentation =
      indentationMatch.map {
        source.substring(with: $0.range(at: 1))
      } ?? ""
    return MarkdownParsedBlockLine(
      indentation: indentation,
      prefix: "",
      content: source.substring(from: indentation.utf16.count),
      style: nil
    )
  }

  private func removingInlineFormatting(from text: String) -> String {
    var result = text
    let replacements: [(String, String)] = [
      (#"(`+)([^\n]*?)\1"#, "$2"),
      (#"\*\*([^\n]+?)\*\*"#, "$1"),
      (#"__([^\n]+?)__"#, "$1"),
      (#"~~([^\n]+?)~~"#, "$1"),
      (#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, "$1"),
      (#"(?<![[:alnum:]])_([^_\n]+?)_(?![[:alnum:]])"#, "$1"),
    ]
    for (pattern, template) in replacements {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let source = result as NSString
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(location: 0, length: source.length),
        withTemplate: template
      )
    }
    return result
  }

  private func reorderedSegments(
    _ segments: [MarkdownAdvancedLineSegment],
    order: [Int]
  ) -> [MarkdownAdvancedLineSegment] {
    order.enumerated().map { destination, sourceIndex in
      MarkdownAdvancedLineSegment(
        content: segments[sourceIndex].content,
        ending: segments[destination].ending
      )
    }
  }

  private func movedSelection(
    originalSelection: NSRange,
    originalRange: NSRange,
    originalSegments: [MarkdownAdvancedLineSegment],
    movedLocation: Int,
    movedSegments: [MarkdownAdvancedLineSegment],
    movedTextLength: Int
  ) -> NSRange {
    guard originalSelection.length == 0 else {
      return NSRange(location: movedLocation, length: movedTextLength)
    }

    let relativeLocation = max(0, originalSelection.location - originalRange.location)
    let cursor = lineAndColumn(
      at: relativeLocation,
      in: originalSegments
    )
    let newRelativeLocation = location(
      line: cursor.line,
      column: cursor.column,
      in: movedSegments
    )
    return NSRange(location: movedLocation + newRelativeLocation, length: 0)
  }

  private func lineAndColumn(
    at location: Int,
    in segments: [MarkdownAdvancedLineSegment]
  ) -> (line: Int, column: Int) {
    var offset = 0
    for (index, segment) in segments.enumerated() {
      let lineLength = segment.fullText.utf16.count
      if location <= offset + lineLength || index == segments.count - 1 {
        return (
          index,
          min(max(0, location - offset), segment.content.utf16.count)
        )
      }
      offset += lineLength
    }
    return (0, 0)
  }

  private func location(
    line: Int,
    column: Int,
    in segments: [MarkdownAdvancedLineSegment]
  ) -> Int {
    let safeLine = min(max(0, line), max(0, segments.count - 1))
    let prefixLength = segments.prefix(safeLine).reduce(0) {
      $0 + $1.fullText.utf16.count
    }
    guard segments.indices.contains(safeLine) else { return prefixLength }
    return prefixLength + min(column, segments[safeLine].content.utf16.count)
  }

  private func selectionAfterLineTransformation(
    originalSelection: NSRange,
    affectedRange: NSRange,
    replacement: String,
    firstPrefixChange: MarkdownPrefixChange?
  ) -> NSRange {
    guard originalSelection.length == 0,
      let change = firstPrefixChange
    else {
      return NSRange(
        location: affectedRange.location,
        length: replacement.utf16.count
      )
    }

    let relativeCursor = originalSelection.location - affectedRange.location
    let newRelativeCursor: Int
    if relativeCursor <= change.oldLength {
      newRelativeCursor = change.newLength
    } else {
      newRelativeCursor = relativeCursor + change.newLength - change.oldLength
    }
    return NSRange(
      location: affectedRange.location + max(0, newRelativeCursor),
      length: 0
    )
  }

  private func taskState(in line: String) -> Bool? {
    guard let match = taskMatch(in: line) else { return nil }
    let source = line as NSString
    return source.substring(with: match.range(at: 3)).lowercased() == "x"
  }

  private func taskMatch(in line: String) -> NSTextCheckingResult? {
    firstMatch(
      pattern: #"^([ \t]*)([-+*])[ \t]+\[([ xX])\]([ \t]*)(.*)$"#,
      in: line
    )
  }

  private func firstMatch(
    pattern: String,
    in text: String
  ) -> NSTextCheckingResult? {
    let source = text as NSString
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: text,
        range: NSRange(location: 0, length: source.length)
      ),
      match.range == NSRange(location: 0, length: source.length)
    else {
      return nil
    }
    return match
  }

  private func repeatedCharacterCount(
    _ character: String,
    fromStartOf source: NSString
  ) -> Int {
    var count = 0
    while count < source.length,
      source.substring(with: NSRange(location: count, length: 1)) == character
    {
      count += 1
    }
    return count
  }

  private func repeatedCharacterCount(
    _ character: String,
    fromEndOf source: NSString
  ) -> Int {
    var count = 0
    while count < source.length,
      source.substring(
        with: NSRange(
          location: source.length - count - 1,
          length: 1
        )) == character
    {
      count += 1
    }
    return count
  }

  private func repeatedCharacterCount(
    _ character: String,
    before location: Int,
    in source: NSString
  ) -> Int {
    var count = 0
    while location - count - 1 >= 0,
      source.substring(
        with: NSRange(
          location: location - count - 1,
          length: 1
        )) == character
    {
      count += 1
    }
    return count
  }

  private func repeatedCharacterCount(
    _ character: String,
    after location: Int,
    in source: NSString
  ) -> Int {
    var count = 0
    while location + count < source.length,
      source.substring(
        with: NSRange(
          location: location + count,
          length: 1
        )) == character
    {
      count += 1
    }
    return count
  }

  private func lineSegments(in block: NSString) -> [MarkdownAdvancedLineSegment] {
    if block.length == 0 {
      return [MarkdownAdvancedLineSegment(content: "", ending: "")]
    }

    var segments: [MarkdownAdvancedLineSegment] = []
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
        MarkdownAdvancedLineSegment(
          content: block.substring(
            with: NSRange(
              location: location,
              length: contentsEnd - location
            )),
          ending: block.substring(
            with: NSRange(
              location: contentsEnd,
              length: lineEnd - contentsEnd
            ))
        )
      )
      location = lineEnd
    }
    return segments
  }

  private func affectedLineRange(
    in source: NSString,
    selection: NSRange
  ) -> NSRange? {
    guard selection.location <= source.length else { return nil }
    let startLine = source.lineRange(
      for: NSRange(location: selection.location, length: 0)
    )
    guard selection.length > 0 else { return startLine }
    let lastSelectedLocation = max(selection.location, NSMaxRange(selection) - 1)
    let endLine = source.lineRange(
      for: NSRange(location: lastSelectedLocation, length: 0)
    )
    return NSRange(
      location: startLine.location,
      length: NSMaxRange(endLine) - startLine.location
    )
  }

  private func lineContentsRange(
    in source: NSString,
    lineRange: NSRange
  ) -> NSRange {
    var contentsEnd = 0
    source.getLineStart(
      nil,
      end: nil,
      contentsEnd: &contentsEnd,
      for: lineRange
    )
    return NSRange(
      location: lineRange.location,
      length: max(0, contentsEnd - lineRange.location)
    )
  }

  private func intersectsFencedCode(
    in source: NSString,
    range: NSRange
  ) -> Bool {
    let lineRange = source.lineRange(
      for: NSRange(location: min(range.location, source.length), length: 0)
    )
    if isInsideFencedCodeBlock(source, before: lineRange.location) {
      return true
    }

    guard range.length > 0 else { return false }
    let text = source.substring(with: range) as NSString
    return lineSegments(in: text).contains { segment in
      let trimmed = segment.content.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }
  }

  private func isInsideFencedCodeBlock(
    _ source: NSString,
    before location: Int
  ) -> Bool {
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

  private func preferredNewline(in text: String) -> String {
    if text.contains("\r\n") {
      return "\r\n"
    }
    if text.contains("\r") {
      return "\r"
    }
    return "\n"
  }

  private func text(
    at location: Int,
    length: Int,
    in source: NSString
  ) -> String? {
    guard location >= 0,
      length >= 0,
      location + length <= source.length
    else {
      return nil
    }
    return source.substring(with: NSRange(location: location, length: length))
  }

  private func clamped(
    _ range: NSRange,
    length: Int
  ) -> NSRange? {
    guard range.location >= 0, range.length >= 0 else { return nil }
    let location = min(range.location, length)
    return NSRange(
      location: location,
      length: min(range.length, max(0, length - location))
    )
  }
}

private enum MarkdownInlineStyle: Equatable {
  case bold
  case italic
  case strikethrough
  case inlineCode

  var defaultMarker: String {
    switch self {
    case .bold:
      return "**"
    case .italic:
      return "*"
    case .strikethrough:
      return "~~"
    case .inlineCode:
      return "`"
    }
  }
}

private enum MarkdownBlockStyle: Equatable {
  case blockquote
  case unorderedList
  case orderedList
  case taskList
}

private struct MarkdownParsedBlockLine {
  var indentation: String
  var prefix: String
  var content: String
  var style: MarkdownBlockStyle?
}

private struct MarkdownAdvancedLineSegment {
  var content: String
  var ending: String

  var fullText: String {
    content + ending
  }
}

private struct MarkdownPrefixChange {
  var oldLength: Int
  var newLength: Int
}
