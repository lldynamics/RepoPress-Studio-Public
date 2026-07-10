import Foundation

public struct AIPublishingChatDraftParagraph: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var text: String
  public var range: NSRange

  public init(id: String, title: String, text: String, range: NSRange) {
    self.id = id
    self.title = title
    self.text = text
    self.range = range
  }
}

public enum AIPublishingChatDraftParagraphParser {
  public static func extract(from markdown: String) -> [AIPublishingChatDraftParagraph] {
    var paragraphs: [AIPublishingChatDraftParagraph] = []
    var currentLines: [String] = []
    var currentStart: Int?
    var utf16Offset = 0
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

    func flush(until endOffset: Int) {
      guard let start = currentStart, !currentLines.isEmpty else {
        currentLines.removeAll()
        currentStart = nil
        return
      }

      let rawText = currentLines.joined(separator: "\n")
      let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      defer {
        currentLines.removeAll()
        currentStart = nil
      }

      guard trimmed.count >= 6 else {
        return
      }

      let safeEnd = min(endOffset, markdown.utf16.count)
      let range = NSRange(location: start, length: max(0, safeEnd - start))
      paragraphs.append(
        AIPublishingChatDraftParagraph(
          id: "\(range.location)-\(range.length)",
          title: title(for: trimmed, index: paragraphs.count),
          text: trimmed,
          range: range
        )
      )
    }

    for lineSlice in lines {
      let line = String(lineSlice)
      let lineLength = line.utf16.count
      if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        flush(until: utf16Offset)
      } else {
        if currentStart == nil {
          currentStart = utf16Offset
        }
        currentLines.append(line)
      }
      utf16Offset += lineLength + 1
    }

    flush(until: markdown.utf16.count)
    return Array(paragraphs.prefix(40))
  }

  private static func title(for text: String, index: Int) -> String {
    let firstLine = text.components(separatedBy: .newlines).first ?? text
    let cleaned = firstLine
      .replacingOccurrences(
        of: #"^\s*(?:#{1,6}\s*|[-*+]\s+|>\s*|\d+[\).）、]\s*)"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = "段落 \(index + 1)"
    guard !cleaned.isEmpty else {
      return fallback
    }
    return cleaned.count > 36 ? "\(cleaned.prefix(36))..." : cleaned
  }
}
