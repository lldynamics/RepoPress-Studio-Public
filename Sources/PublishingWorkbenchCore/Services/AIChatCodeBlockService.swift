import Foundation

/// A fenced Markdown block returned by an AI assistant.
///
/// The fenced source is kept alongside the display content so applying a
/// Markdown block to an article does not silently lose its language marker.
public struct AIChatCodeBlock: Hashable, Identifiable, Sendable {
  public let id: String
  public let language: String?
  public let content: String
  public let fencedMarkdown: String

  public init(
    id: String,
    language: String?,
    content: String,
    fencedMarkdown: String
  ) {
    self.id = id
    self.language = language
    self.content = content
    self.fencedMarkdown = fencedMarkdown
  }

  public var isMermaidDiagram: Bool {
    guard let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return false
    }
    return lang == "mermaid" || lang == "diagram" || lang == "plantuml"
  }
}

/// The renderable parts of an assistant message.
public enum AIChatContentSegment: Hashable, Identifiable, Sendable {
  case text(id: String, content: String)
  case code(AIChatCodeBlock)

  public var id: String {
    switch self {
    case let .text(id, _):
      return id
    case let .code(block):
      return block.id
    }
  }
}

/// Parses complete fenced blocks without hiding a still-streaming, unclosed
/// fence. This keeps partial AI replies readable while they are being written.
public enum AIChatCodeBlockPresentationService {
  public static func segments(in markdown: String) -> [AIChatContentSegment] {
    let source = markdown as NSString
    guard source.length > 0 else { return [] }

    var segments: [AIChatContentSegment] = []
    var textStart = 0
    var cursor = 0
    var nextTextID = 0
    var nextCodeID = 0
    var opening: OpeningFence?
    var codeContentStart = 0

    while cursor < source.length {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: cursor, length: 0)
      )
      let contentRange = NSRange(
        location: lineStart,
        length: max(0, contentsEnd - lineStart)
      )

      if let activeOpening = opening {
        if isClosingFence(activeOpening, source: source, lineRange: contentRange) {
          appendText(
            from: textStart,
            to: activeOpening.start,
            source: source,
            nextTextID: &nextTextID,
            segments: &segments
          )

          let rawContent = source.substring(with: NSRange(
            location: codeContentStart,
            length: max(0, lineStart - codeContentStart)
          ))
          let codeContent = trimTrailingLineBreak(from: rawContent)
          let fencedMarkdown = source.substring(with: NSRange(
            location: activeOpening.start,
            length: max(0, contentsEnd - activeOpening.start)
          ))
          segments.append(.code(AIChatCodeBlock(
            id: "ai-code-block-" + String(nextCodeID),
            language: activeOpening.language,
            content: codeContent,
            fencedMarkdown: fencedMarkdown
          )))
          nextCodeID += 1
          opening = nil
          textStart = lineEnd
        }
      } else if let newOpening = openingFence(source: source, lineRange: contentRange) {
        opening = newOpening
        codeContentStart = lineEnd
      }

      cursor = max(lineEnd, cursor + 1)
    }

    // An unclosed fence is deliberately emitted as ordinary text. The next
    // streaming update can then turn it into a card once the closing fence
    // arrives, without making the visible transcript jump around prematurely.
    appendText(
      from: textStart,
      to: source.length,
      source: source,
      nextTextID: &nextTextID,
      segments: &segments
    )
    return segments
  }

  private struct OpeningFence {
    let marker: unichar
    let length: Int
    let start: Int
    let language: String?
  }

  private static func appendText(
    from start: Int,
    to end: Int,
    source: NSString,
    nextTextID: inout Int,
    segments: inout [AIChatContentSegment]
  ) {
    guard end > start else { return }
    let text = source.substring(with: NSRange(location: start, length: end - start))
    guard !text.isEmpty else { return }
    segments.append(.text(id: "ai-chat-text-" + String(nextTextID), content: text))
    nextTextID += 1
  }

  private static func openingFence(
    source: NSString,
    lineRange: NSRange
  ) -> OpeningFence? {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var indentation = 0
    while cursor < end, source.character(at: cursor) == 32, indentation < 4 {
      indentation += 1
      cursor += 1
    }
    guard indentation <= 3, cursor < end else { return nil }

    let marker = source.character(at: cursor)
    guard marker == 96 || marker == 126 else { return nil }
    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == marker {
      cursor += 1
    }
    let length = cursor - markerStart
    guard length >= 3 else { return nil }

    let info = source.substring(with: NSRange(location: cursor, length: end - cursor))
    if marker == 96, info.contains("`") {
      return nil
    }
    let language = info
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .first
      .map(String.init)
      .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    return OpeningFence(
      marker: marker,
      length: length,
      start: lineRange.location,
      language: language
    )
  }

  private static func isClosingFence(
    _ opening: OpeningFence,
    source: NSString,
    lineRange: NSRange
  ) -> Bool {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var indentation = 0
    while cursor < end, source.character(at: cursor) == 32, indentation < 4 {
      indentation += 1
      cursor += 1
    }
    guard indentation <= 3, cursor < end,
          source.character(at: cursor) == opening.marker else { return false }

    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == opening.marker {
      cursor += 1
    }
    guard cursor - markerStart >= opening.length else { return false }
    while cursor < end {
      let character = source.character(at: cursor)
      guard character == 32 || character == 9 else { return false }
      cursor += 1
    }
    return true
  }

  private static func trimTrailingLineBreak(from value: String) -> String {
    guard value.hasSuffix("\n") else { return value }
    let withoutNewline = String(value.dropLast())
    return withoutNewline.hasSuffix("\r")
      ? String(withoutNewline.dropLast())
      : withoutNewline
  }
}

public enum AIChatMarkdownInsertionMode: Sendable {
  /// Replace the current selection, or insert at the current cursor when the
  /// selection is empty.
  case applyToCurrentEditor
  /// Insert at the selection start while preserving selected text.
  case insertAtCursor
}

public struct AIChatMarkdownInsertionResult: Hashable, Sendable {
  public let updatedBodyMarkdown: String
  public let insertedRange: NSRange

  public init(updatedBodyMarkdown: String, insertedRange: NSRange) {
    self.updatedBodyMarkdown = updatedBodyMarkdown
    self.insertedRange = insertedRange
  }
}

public enum AIChatMarkdownInsertionService {
  public static func inserting(
    _ markdown: String,
    into bodyMarkdown: String,
    selection: NSRange?,
    mode: AIChatMarkdownInsertionMode
  ) -> AIChatMarkdownInsertionResult? {
    let fragment = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fragment.isEmpty else { return nil }

    let body = bodyMarkdown as NSString
    let selection = selection ?? NSRange(location: body.length, length: 0)
    guard selection.location >= 0,
          selection.length >= 0,
          NSMaxRange(selection) <= body.length else {
      return nil
    }

    let replacementRange: NSRange
    switch mode {
    case .applyToCurrentEditor:
      replacementRange = selection
    case .insertAtCursor:
      replacementRange = NSRange(location: selection.location, length: 0)
    }

    let before = body.substring(with: NSRange(
      location: 0,
      length: replacementRange.location
    ))
    let afterStart = NSMaxRange(replacementRange)
    let after = body.substring(with: NSRange(
      location: afterStart,
      length: body.length - afterStart
    ))
    let leadingSeparator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n"
    let trailingSeparator = after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n"
    let replacement = leadingSeparator + fragment + trailingSeparator
    let updatedBody = body.replacingCharacters(in: replacementRange, with: replacement)
    let insertedLocation = replacementRange.location + (leadingSeparator as NSString).length
    let insertedLength = (fragment as NSString).length

    return AIChatMarkdownInsertionResult(
      updatedBodyMarkdown: updatedBody,
      insertedRange: NSRange(
        location: insertedLocation + insertedLength,
        length: 0
      )
    )
  }
}
