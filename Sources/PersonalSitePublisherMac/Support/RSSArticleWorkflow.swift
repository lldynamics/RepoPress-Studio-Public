import Foundation
import PublishingWorkbenchCore

enum RSSArticleWorkflow {
  static func summary(for article: RSSArticle, maximumCharacters: Int = 360) -> String {
    let feedSummary = RSSHTMLTextSanitizer.plainText(from: article.summaryHTML)
    let source = feedSummary.isEmpty ? article.readableText : feedSummary
    return clipped(source, maximumCharacters: maximumCharacters)
  }

  static func excerpt(for article: RSSArticle, maximumCharacters: Int = 900) -> String {
    clipped(article.readableText, maximumCharacters: maximumCharacters)
  }

  static func sourceDomain(for article: RSSArticle) -> String? {
    guard let link = article.link else { return nil }
    return KnowledgeSmartCollectionService().sourceDomain(for: link)
  }

  /// Reuses the same source-domain organization signal as browser captures.
  /// If there is no prior folder history for this domain, the imported
  /// document still participates in the existing source-domain smart
  /// collection through its source URL.
  static func preferredImportDestination(
    article: RSSArticle,
    documents: [KnowledgeDocument],
    folders: [KnowledgeFolder]
  ) -> KnowledgeImportDestination {
    guard let sourceURL = article.link else { return .preserveExisting }
    let suggestions = KnowledgeSmartCollectionService().browserOrganizationSuggestions(
      sourceURL: sourceURL,
      authors: article.author.map { [$0] } ?? [],
      tags: article.tags,
      documents: documents,
      folders: folders,
      limit: 3
    )
    guard let suggestion = suggestions.folders.first(where: {
      $0.reasons.contains(.sourceDomain)
    }) else {
      return .preserveExisting
    }
    return .folder(suggestion.folder.id)
  }

  static func safeReferenceMarkdown(
    article: RSSArticle,
    summary: String,
    excerpt: String,
    sourceURL: URL?
  ) -> String {
    let title = markdownText(article.title)
    let source = sourceURL.map { "[打开原文](\($0.absoluteString))" } ?? "原文地址不可用"
    let quote = excerpt
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \($0)" }
      .joined(separator: "\n")
    return """
    ### \(title)

    **摘要**：\(summary.isEmpty ? "（无摘要）" : summary)

    **摘录**：
    \(quote.isEmpty ? "> （无可用摘录）" : quote)

    **来源**：\(source)
    """
  }

  static func insertionMarkdown(
    article: RSSArticle,
    highlight: RSSArticleHighlight?,
    style: KnowledgeArticleInsertionStyle
  ) -> String {
    let excerpt = (highlight?.text ?? excerpt(for: article))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !excerpt.isEmpty else { return "" }

    switch style {
    case .blockquote:
      let quote = excerpt
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "> \(markdownText(String($0)))" }
        .joined(separator: "\n")
      let source = sourceMarkdown(for: article)
      let kind = highlight == nil ? "RSS 摘录" : "RSS 高亮"
      let note = highlight?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let noteLine = note.isEmpty ? "" : "\n>\n> 注：\(markdownText(note))"
      return "\(quote)\n>\n> — \(source)（\(kind)）\(noteLine)"
    case .footnote:
      return "[^\(footnoteKey(for: article, highlight: highlight))]"
    }
  }

  static func appendingFootnote(
    to markdown: String,
    article: RSSArticle,
    highlight: RSSArticleHighlight?
  ) -> String {
    let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    let excerpt = (highlight?.text ?? excerpt(for: article))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !excerpt.isEmpty else { return body }

    let key = footnoteKey(for: article, highlight: highlight)
    guard !body.contains("[^\(key)]:") else { return body }
    let kind = highlight == nil ? "RSS 摘录" : "RSS 高亮"
    let note = highlight?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let noteSuffix = note.isEmpty ? "" : "；批注：\(markdownText(note))"
    let definition = "[^\(key)]: \(sourceMarkdown(for: article))（\(kind)）— \(markdownText(excerpt))\(noteSuffix)"
    let heading = "## RSS 来源"

    if body.contains(heading) {
      return [body, definition].joined(separator: "\n\n")
    }
    return [body, heading, definition].joined(separator: "\n\n")
  }

  private static func clipped(_ value: String, maximumCharacters: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maximumCharacters else { return trimmed }
    return String(trimmed.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func markdownText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func sourceMarkdown(for article: RSSArticle) -> String {
    let title = markdownText(article.title)
    guard let link = article.link else { return title }
    return "[\(title)](\(link.absoluteString))"
  }

  private static func footnoteKey(
    for article: RSSArticle,
    highlight: RSSArticleHighlight?
  ) -> String {
    let articleToken = safeToken(article.id, fallback: "article")
    let highlightToken = highlight.map { safeToken($0.id.uuidString, fallback: "excerpt") } ?? "excerpt"
    return "rss-\(articleToken)-\(highlightToken)"
  }

  private static func safeToken(_ value: String, fallback: String) -> String {
    let token = value.map { character in
      character.isLetter || character.isNumber || character == "-" ? character : "-"
    }
    let trimmed = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(trimmed.prefix(48)).nilIfEmpty ?? fallback
  }
}
