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
  let targetCode: String
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

struct RSSStatusEvent: Equatable {
  let title: String
  let details: [String]
  let isError: Bool
}
