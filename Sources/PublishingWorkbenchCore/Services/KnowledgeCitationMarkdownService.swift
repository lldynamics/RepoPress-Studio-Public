import Foundation

public enum KnowledgeCitationMarkdownService {
  public static func appendingCitations(
    to markdown: String,
    citations: [KnowledgeCitation]
  ) -> String {
    let content = markdown.trimmedForPublishing
    guard !citations.isEmpty else { return content }
    let unique = citations.reduce(into: [KnowledgeCitation]()) { result, citation in
      guard !result.contains(where: { $0.documentID == citation.documentID && $0.chunkID == citation.chunkID }) else {
        return
      }
      result.append(citation)
    }
    let definitions = unique.enumerated().map { index, citation in
      let key = footnoteKey(for: citation, fallbackIndex: index + 1)
      let authors = citation.authors.joined(separator: "、")
      let location = citation.locator?.trimmedForPublishing.nilIfEmpty
      let metadata = [authors.nilIfEmpty, location].compactMap { $0 }.joined(separator: "，")
      let source = citation.sourceURL.map { "[来源](\($0.absoluteString))" }
      let suffix = [metadata.nilIfEmpty, source].compactMap { $0 }.joined(separator: "；")
      return "[^\(key)]: \(citation.title)\(suffix.isEmpty ? "" : "（\(suffix)）")。\(citation.excerpt.trimmedForPublishing)"
    }
    return [content, "## 资料来源\n\n" + definitions.joined(separator: "\n")]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  public static func footnoteKey(for citation: KnowledgeCitation, fallbackIndex: Int) -> String {
    let normalized = citation.id.lowercased().map { character -> Character in
      character.isLetter || character.isNumber || character == "-" ? character : "-"
    }
    let key = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "kb-\(key.isEmpty ? String(fallbackIndex) : key)"
  }
}
