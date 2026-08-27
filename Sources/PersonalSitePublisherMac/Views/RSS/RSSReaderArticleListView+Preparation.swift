import Foundation
import PublishingWorkbenchCore

struct RSSPrepareInput: Equatable {
  let revision: UInt64
  let scope: RSSArticleScope
  let searchText: String
  let unreadOnly: Bool
  let sourceID: UUID?
  let author: String?
  let tag: String?
  let dateRange: String
  let sortOrder: String
  let groupsByDate: Bool
  let displayLimit: Int
}

extension RSSArticleList {
  var prepareInput: RSSPrepareInput {
    RSSPrepareInput(
      revision: store.mutationRevision,
      scope: presentation.selectedScope ?? .all,
      searchText: presentation.debouncedSearchText,
      unreadOnly: presentation.unreadOnly,
      sourceID: presentation.selectedSourceID,
      author: presentation.selectedAuthor,
      tag: presentation.selectedTag,
      dateRange: presentation.dateRange.rawValue,
      sortOrder: presentation.sortOrder.rawValue,
      groupsByDate: presentation.groupsByDate,
      displayLimit: presentation.articleDisplayLimit
    )
  }

  /// 在后台计算过滤/排序/分组结果并填充 preparedList，避免首次进入或
  /// 数据刷新后在主页线程同步处理几千篇文章。
  func prepareList() async {
    let scope = presentation.selectedScope ?? .all
    let searchText = presentation.debouncedSearchText
    let unreadOnly = presentation.unreadOnly
    let sourceID = presentation.selectedSourceID
    let author = presentation.selectedAuthor
    let tag = presentation.selectedTag
    let dateRange = presentation.dateRange
    let sortOrder = presentation.sortOrder
    let groupsByDate = presentation.groupsByDate
    let displayLimit = presentation.articleDisplayLimit
    // Search and secondary facets must include the archive, not merely the
    // first bootstrap window. Completing this utility read before querying
    // keeps the main actor free while preserving exact FTS semantics.
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      await store.loadRemainingArticleHeadersIfNeeded()
    }
    let base = await store.articleHeadersAsync(
      for: scope,
      searchText: searchText,
      unreadOnly: unreadOnly
    )

    let result = await Task.detached(priority: .userInitiated) {
      let matching = RSSArticlePresentationSupport.applyFiltersAndSort(
        to: base,
        sourceID: sourceID,
        author: author,
        tag: tag,
        dateRange: dateRange,
        sortOrder: sortOrder
      )
      let visible = Array(matching.prefix(displayLimit))
      let sections = RSSArticlePresentationSupport.sections(
        for: visible,
        groupsByDate: groupsByDate,
        sortOrder: sortOrder
      )
      let unreadIDs = Set(matching.lazy.filter { !$0.isRead }.map(\.id))
      let sourceIDs = Set(base.map(\.feedID))
      let authors = Array(Set(base.compactMap { $0.author?.trimmedForPublishing.nilIfEmpty }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      let tags = Array(Set(base.flatMap(\.tags)))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      let articleIDsByIndex = matching.map(\.id)
      let indexByArticleID = Dictionary(
        uniqueKeysWithValues: articleIDsByIndex.enumerated().map { ($1, $0) }
      )
      return RSSPreparedPresentationSnapshot(
        matchingArticles: matching,
        visibleArticles: visible,
        sections: sections,
        unreadMatchingArticleIDs: unreadIDs,
        scopedArticleCount: base.count,
        unreadArticleCount: unreadIDs.count,
        sourceIDs: sourceIDs,
        authors: authors,
        tags: tags,
        articleIDsByIndex: articleIDsByIndex,
        indexByArticleID: indexByArticleID
      )
    }.value

    guard !Task.isCancelled else { return }
    presentation.cachePreparedMatchingArticles(
      result.matchingArticles,
      unreadArticleIDs: result.unreadMatchingArticleIDs,
      in: store
    )
    preparedList = result
  }

  func openOriginal(_ article: RSSArticleHeader) {
    guard let link = article.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      presentation.errorMessage = message
    }
  }

  func moveArticleSelection(by offset: Int) {
    guard offset != 0 else { return }
    let articles = preparedList?.matchingArticles ?? []
    guard !articles.isEmpty else { return }

    let currentIndex = selectedArticleID.flatMap { selectedID in
      articles.firstIndex { $0.id == selectedID }
    }
    let targetIndex: Int
    if let currentIndex {
      targetIndex = currentIndex + offset
    } else {
      targetIndex = offset > 0 ? 0 : articles.count - 1
    }
    guard articles.indices.contains(targetIndex) else { return }

    let targetArticleID = articles[targetIndex].id
    presentation.revealArticle(targetArticleID, in: store)
    selectedArticleID = targetArticleID
  }

  func openSelectedArticle() {
    if let selectedArticleID,
      store.articleHeader(id: selectedArticleID) != nil
    {
      presentation.revealArticle(selectedArticleID, in: store)
      self.selectedArticleID = selectedArticleID
    } else {
      moveArticleSelection(by: 1)
    }
  }

  func retrySelectedScope() {
    if let selectedFeed {
      Task { await store.refresh(feedID: selectedFeed.id, force: true) }
    } else {
      Task { await store.refreshAll() }
    }
  }
}
