import Foundation
import PublishingCoreSupport

public struct RSSWorkspacePaletteSearchResult: Hashable, Sendable, Identifiable {
  public var id: String { article.id }
  public let article: RSSArticleHeader
  public let snippet: String

  public init(article: RSSArticleHeader, snippet: String) {
    self.article = article
    self.snippet = snippet
  }
}

@MainActor
extension RSSReaderStore {
  /// Searches the persisted RSS FTS archive, including valid cached original
  /// page text. It does not read or change the RSS reader's visible-page,
  /// scope, or filter state.
  public func workspacePaletteSearch(
    query: String,
    limit: Int = 12
  ) async throws -> [RSSWorkspacePaletteSearchResult] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

    let database = self.database
    let legacyArticles = database == nil ? self.legacyArticles : []
    let resultLimit = min(limit, 24)
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      if let database {
        let headers = try database.articleHeaders(
          for: .all,
          searchText: normalizedQuery,
          unreadOnly: false,
          limit: resultLimit
        )
        var results: [RSSWorkspacePaletteSearchResult] = []
        results.reserveCapacity(headers.count)
        for header in headers {
          try Task.checkCancellation()
          let record = try database.fullTextRecord(articleID: header.id)
          let cachedText: String
          if record?.status == .ready,
            record?.sourceURL?.absoluteString == header.link?.absoluteString
          {
            cachedText = record?.plainText ?? ""
          } else {
            cachedText = ""
          }
          let needsFeedBodySnippet = !RSSWorkspacePaletteSearchPresentation.containsMatch(
            query: normalizedQuery,
            sources: [cachedText, header.readableSummary, header.title]
          )
          let feedBodyText: String
          if needsFeedBodySnippet, let article = try database.article(id: header.id) {
            feedBodyText = RSSWorkspacePaletteSearchPresentation.preferredFeedBodyText(
              query: normalizedQuery,
              contentHTML: article.contentHTML,
              snapshotHTML: article.webPageSnapshotHTML
            )
          } else {
            feedBodyText = ""
          }
          results.append(
            RSSWorkspacePaletteSearchResult(
              article: header,
              snippet: RSSWorkspacePaletteSearchPresentation.snippet(
                query: normalizedQuery,
                title: header.title,
                summary: header.readableSummary,
                cachedText: cachedText,
                feedBodyText: feedBodyText
              )
            )
          )
        }
        return results
      }

      return
        legacyArticles
        .filter { article in
          RSSWorkspacePaletteSearchPresentation.matches(article, query: normalizedQuery)
        }
        .sorted(by: RSSWorkspacePaletteSearchPresentation.newestFirst)
        .prefix(resultLimit)
        .map { article in
          RSSWorkspacePaletteSearchResult(
            article: RSSArticleHeader(article: article),
            snippet: RSSWorkspacePaletteSearchPresentation.snippet(
              query: normalizedQuery,
              title: article.title,
              summary: RSSHTMLTextSanitizer.plainText(from: article.summaryHTML),
              cachedText: "",
              feedBodyText: RSSHTMLTextSanitizer.plainText(from: article.contentHTML)
            )
          )
        }
    }

    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

enum RSSWorkspacePaletteSearchPresentation {
  static func matches(_ article: RSSArticle, query: String) -> Bool {
    let text = [
      article.title,
      article.author ?? "",
      RSSHTMLTextSanitizer.plainText(from: article.summaryHTML),
      RSSHTMLTextSanitizer.plainText(from: article.contentHTML),
    ].joined(separator: "\n")
    return text.localizedCaseInsensitiveContains(query)
  }

  static func newestFirst(_ lhs: RSSArticle, _ rhs: RSSArticle) -> Bool {
    let leftDate = lhs.publishedAt ?? lhs.fetchedAt
    let rightDate = rhs.publishedAt ?? rhs.fetchedAt
    if leftDate != rightDate { return leftDate > rightDate }
    return lhs.id < rhs.id
  }

  static func snippet(
    query: String,
    title: String,
    summary: String,
    cachedText: String,
    feedBodyText: String,
    maximumCharacters: Int = 180
  ) -> String {
    let sources = [cachedText, feedBodyText, summary, title]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let source =
      sources.first(where: { $0.localizedCaseInsensitiveContains(query) })
      ?? sources.first
      ?? ""
    guard source.count > maximumCharacters else { return source }

    let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    let start: String.Index
    if let range {
      start =
        source.index(
          range.lowerBound,
          offsetBy: -(maximumCharacters / 3),
          limitedBy: source.startIndex
        ) ?? source.startIndex
    } else {
      start = source.startIndex
    }
    let end =
      source.index(start, offsetBy: maximumCharacters, limitedBy: source.endIndex)
      ?? source.endIndex
    let prefix = start == source.startIndex ? "" : "…"
    let suffix = end == source.endIndex ? "" : "…"
    return prefix + String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
      + suffix
  }

  static func containsMatch(query: String, sources: [String]) -> Bool {
    sources.contains { $0.localizedCaseInsensitiveContains(query) }
  }

  static func preferredFeedBodyText(
    query: String,
    contentHTML: String,
    snapshotHTML: String?
  ) -> String {
    let sources = [
      RSSHTMLTextSanitizer.plainText(from: contentHTML),
      RSSHTMLTextSanitizer.plainText(from: snapshotHTML ?? ""),
    ]
    return sources.first(where: { $0.localizedCaseInsensitiveContains(query) })
      ?? sources.first(where: { !$0.isEmpty })
      ?? ""
  }
}
