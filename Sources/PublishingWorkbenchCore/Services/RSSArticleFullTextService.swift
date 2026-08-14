import Foundation

public struct RSSArticleFullTextService: Sendable {
  private let downloadClient: KnowledgeWebDownloadClient
  private let sanitizer: KnowledgeWebContentSanitizer

  public init() {
    self.downloadClient = KnowledgeWebDownloadClient()
    self.sanitizer = KnowledgeWebContentSanitizer()
  }

  init(
    downloadClient: KnowledgeWebDownloadClient,
    sanitizer: KnowledgeWebContentSanitizer
  ) {
    self.downloadClient = downloadClient
    self.sanitizer = sanitizer
  }

  /// Determines whether the article appears to be a truncated snippet or summary
  /// that would benefit from full-text extraction from the original website.
  public func isTruncatedCandidate(_ article: RSSArticle) -> Bool {
    guard let link = article.link,
          let scheme = link.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return false
    }
    let readable = article.readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    // If the text is very short (under 500 characters), or content is empty and only summary exists
    if readable.count < 500 {
      return true
    }
    let content = article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = article.summaryHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.isEmpty && !summary.isEmpty {
      return true
    }
    // If content is just a copy of summary and relatively brief
    if content == summary && readable.count < 900 {
      return true
    }
    return false
  }

  /// Downloads the original webpage for the given article and sanitizes its content
  /// into clean, structured HTML suitable for reading inside the application.
  public func fetchFullText(for article: RSSArticle) async throws -> RSSArticle {
    guard let url = article.link,
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      throw RSSReaderError.persistence("该文章没有有效的原文网页链接。")
    }

    let request = URLRequest(url: url)
    let download = try await downloadClient.download(
      request: request,
      maximumByteCount: 4 * 1024 * 1024
    )

    let sanitized = try sanitizer.sanitize(
      data: download.data,
      sourceName: article.title
    )

    guard !sanitized.sections.isEmpty else {
      throw RSSReaderError.persistence("未能从原文网页中提取到可读的正文内容。")
    }

    let fullTextHTML = renderSectionsToHTML(sanitized.sections)
    guard !fullTextHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RSSReaderError.persistence("提取的正文内容为空。")
    }

    var updated = article
    // Preserve original brief summary if not already set
    if updated.summaryHTML.isEmpty && !updated.contentHTML.isEmpty {
      updated.summaryHTML = updated.contentHTML
    }
    updated.contentHTML = fullTextHTML
    updated.webPageSnapshotHTML = fullTextHTML
    if let title = sanitized.title?.nilIfEmpty, updated.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      updated.title = title
    }
    return updated
  }

  private func renderSectionsToHTML(_ sections: [KnowledgeExtractedSection]) -> String {
    var htmlBlocks: [String] = []
    for section in sections {
      if let heading = section.headingPath?.components(separatedBy: " › ").last?.trimmedForPublishing.nilIfEmpty {
        let tag = (section.headingPath?.contains(" › ") == true) ? "h3" : "h2"
        htmlBlocks.append("<\(tag)>\(escapeHTML(heading))</\(tag)>")
      }
      let paragraphs = section.text.components(separatedBy: "\n\n")
      for paragraph in paragraphs {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        if trimmed.hasPrefix("```") {
          let lines = trimmed.components(separatedBy: "\n")
          let firstLine = lines.first ?? ""
          let lang = firstLine.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
          let codeLines = (lines.count > 1) ? lines.dropFirst().dropLast(trimmed.hasSuffix("```") && lines.count > 2 ? 1 : 0) : []
          let codeContent = codeLines.joined(separator: "\n")
          let langClass = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
          htmlBlocks.append("<pre><code\(langClass)>\(escapeHTML(codeContent))</code></pre>")
        } else if trimmed.hasPrefix("> ") {
          let quoteContent = trimmed.components(separatedBy: "\n").map { line in
            line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
          }.joined(separator: "<br>")
          htmlBlocks.append("<blockquote><p>\(escapeHTML(quoteContent))</p></blockquote>")
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
          let items = trimmed.components(separatedBy: "\n").compactMap { line -> String? in
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineTrimmed.hasPrefix("- ") || lineTrimmed.hasPrefix("* ") else { return nil }
            let text = String(lineTrimmed.dropFirst(2))
            return "<li>\(escapeHTML(text))</li>"
          }.joined()
          if !items.isEmpty {
            htmlBlocks.append("<ul>\(items)</ul>")
          }
        } else if trimmed.hasPrefix("![") && trimmed.contains("](") {
          if let (alt, src) = parseMarkdownImage(trimmed) {
            htmlBlocks.append("<figure><img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\"></figure>")
          } else {
            htmlBlocks.append("<p>\(escapeHTML(trimmed))</p>")
          }
        } else {
          htmlBlocks.append("<p>\(escapeHTML(trimmed))</p>")
        }
      }
    }
    return htmlBlocks.joined(separator: "\n")
  }

  private func parseMarkdownImage(_ text: String) -> (alt: String, src: String)? {
    guard text.hasPrefix("!["),
          let closeBracket = text.firstIndex(of: "]"),
          let openParen = text[closeBracket...].firstIndex(of: "("),
          let closeParen = text[openParen...].firstIndex(of: ")") else {
      return nil
    }
    let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<closeBracket])
    let src = String(text[text.index(after: openParen)..<closeParen])
    return (alt, src)
  }

  private func escapeHTML(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
