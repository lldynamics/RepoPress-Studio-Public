import Foundation
import PublishingWorkbenchCore

struct RSSHighlightDraft: Identifiable {
  let id: UUID
  let articleID: String
  let text: String
  let existingID: UUID?
  let initialNote: String
  let initialTags: [String]

  init(
    articleID: String,
    text: String,
    existingID: UUID? = nil,
    initialNote: String = "",
    initialTags: [String] = []
  ) {
    self.id = existingID ?? UUID()
    self.articleID = articleID
    self.text = text
    self.existingID = existingID
    self.initialNote = initialNote
    self.initialTags = initialTags
  }
}

struct RSSArticleLoadRequest: Equatable {
  let articleID: String?
  let retryToken: Int
  let articleRevision: Date?
}

struct RSSArticleTranslationCacheKey: Hashable {
  let articleID: String
  let fetchedAt: Date
  /// The reader can switch between the feed summary and a locally cached
  /// full-text extraction without changing `fetchedAt`.  Keep results for the
  /// two bodies separate so the visible body and translated body stay aligned.
  let contentVersion: UInt64
  let targetCode: String
  let backend: RSSArticleTranslationBackend
}

enum RSSArticleTranslationContentVersion {
  static func make(for article: RSSArticle) -> UInt64 {
    // FNV-1a is small, deterministic, and avoids retaining a full HTML body in
    // each cache key. This is a cache discriminator, not a security digest.
    var hash: UInt64 = 1_469_598_103_934_665_603
    for component in [
      article.title,
      article.summaryHTML,
      article.contentHTML,
      article.webPageSnapshotHTML ?? "",
    ] {
      for byte in component.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0
      hash &*= 1_099_511_628_211
    }
    return hash
  }
}

struct RSSReaderFilterChangeToken: Equatable {
  let scope: RSSArticleScope?
  let searchText: String
  let unreadOnly: Bool
  let sourceID: UUID?
  let author: String?
  let tag: String?
  let dateRange: String
  let sortOrder: String
  let mutationRevision: UInt64

  var filterOnly: RSSReaderFilterChangeToken {
    RSSReaderFilterChangeToken(
      scope: scope,
      searchText: searchText,
      unreadOnly: unreadOnly,
      sourceID: sourceID,
      author: author,
      tag: tag,
      dateRange: dateRange,
      sortOrder: sortOrder,
      mutationRevision: 0
    )
  }
}
