import Foundation

/// Builds a small, local-only retrieval query from the article currently being
/// edited. It deliberately keeps the query bounded so typing never causes the
/// whole article to be sent through the semantic index.
public enum KnowledgeContextQueryService {
  public static func query(
    for draft: ArticleDraft,
    bodyMarkdown: String? = nil,
    selectedRange: NSRange? = nil,
    maximumCharacters: Int = 3_600
  ) -> String {
    let body = bodyMarkdown ?? draft.bodyMarkdown
    let headings = body
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { line in
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes)
          && line.dropFirst(hashes).first == " "
      }
      .prefix(12)

    let bodyContext = boundedBodyContext(body, maximumCharacters: maximumCharacters)
    let paragraphContext: String?
    if let selectedRange {
      paragraphContext = Self.currentParagraph(in: body, selectedRange: selectedRange)
        .map { boundedBodyContext($0, maximumCharacters: 1_200) }
    } else {
      paragraphContext = nil
    }

    var parts: [String] = []
    if let title = draft.title.trimmedForPublishing.nilIfEmpty {
      parts.append("标题：\(title)")
    }
    if let summary = draft.summary.trimmedForPublishing.nilIfEmpty {
      parts.append("摘要：\(summary)")
    }
    let tags = draft.tags.joined(separator: "、").trimmedForPublishing
    if let tags = tags.nilIfEmpty {
      parts.append("标签：\(tags)")
    }
    if !headings.isEmpty {
      parts.append("章节：\(headings.joined(separator: "、"))")
    }
    if let paragraphContext {
      parts.append("当前段落：\(paragraphContext)")
    }
    if let bodyContext = bodyContext.nilIfEmpty {
      parts.append("正文上下文：\(bodyContext)")
    }
    return parts.joined(separator: "\n")
  }

  /// Returns the Markdown paragraph containing the caret or selection.
  ///
  /// Markdown paragraphs are separated by a blank line, which is more useful
  /// for retrieval than `NSString.paragraphRange` (which only understands
  /// individual lines). The range is expressed in UTF-16 offsets to match the
  /// AppKit text editor state.
  public static func currentParagraph(
    in bodyMarkdown: String,
    selectedRange: NSRange
  ) -> String? {
    let paragraphs = bodyMarkdown.components(separatedBy: "\n\n")
    guard !paragraphs.isEmpty else { return nil }

    let bodyLength = (bodyMarkdown as NSString).length
    let location = min(max(selectedRange.location, 0), bodyLength)
    let selectionEnd = min(
      bodyLength,
      location + max(0, selectedRange.length)
    )
    var offset = 0
    var nearestParagraph: String?

    for paragraph in paragraphs {
      let paragraphLength = (paragraph as NSString).length
      let range = NSRange(location: offset, length: paragraphLength)
      let intersectsSelection = selectedRange.length > 0
        ? NSMaxRange(range) >= location && range.location <= selectionEnd
        : location >= range.location && location <= NSMaxRange(range)
      let normalized = paragraph
        .replacingOccurrences(of: "```", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if !normalized.isEmpty {
        nearestParagraph = normalized
      }
      if intersectsSelection, !normalized.isEmpty {
        return normalized
      }
      offset += paragraphLength + 2
    }

    return nearestParagraph
  }

  private static func boundedBodyContext(
    _ body: String,
    maximumCharacters: Int
  ) -> String {
    let limit = max(600, maximumCharacters)
    let compact = body
      .replacingOccurrences(of: "```", with: " ")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > limit else { return compact }

    let headLength = max(1, limit * 2 / 3)
    let tailLength = max(1, limit - headLength)
    let head = String(compact.prefix(headLength))
    let tail = String(compact.suffix(tailLength))
    return "\(head) … \(tail)"
  }
}
