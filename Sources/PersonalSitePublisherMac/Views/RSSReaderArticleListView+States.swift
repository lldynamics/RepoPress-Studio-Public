import Foundation
import SwiftUI
import PublishingWorkbenchCore

extension RSSArticleList {
  func listState(
    matchingCount: Int,
    cachedCount: Int
  ) -> RSSArticleListPresentationState {
    let failure = scopeFailure
    return RSSArticlePresentationSupport.listState(
      isRefreshing: scopeIsRefreshing,
      cachedCount: cachedCount,
      visibleCount: matchingCount,
      hasActiveFilters: hasActiveFilters,
      failedFeedTitle: failure?.title,
      failedFeedMessage: failure?.message
    )
  }

  func listContentPresentation(
    for state: RSSArticleListPresentationState
  ) -> Bool? {
    switch state {
    case .content:
      return false
    case .refreshing:
      return true
    case .staleContent:
      return false
    case .loading, .failed, .empty, .filteredEmpty:
      return nil
    }
  }

  var scopeFailure: (title: String, message: String)? {
    let failedFeeds: [RSSFeed]
    if let selectedFeed {
      failedFeeds =
        RSSArticlePresentationSupport.feedNeedsAttention(selectedFeed)
        ? [selectedFeed]
        : []
    } else {
      failedFeeds = store.feeds.filter { RSSArticlePresentationSupport.feedNeedsAttention($0) }
    }
    guard let first = failedFeeds.first else { return nil }
    if failedFeeds.count == 1 {
      return (
        first.displayTitle,
        first.lastIssue?.userMessage ?? first.lastError ?? String(localized: "订阅刷新失败。")
      )
    }
    let names = failedFeeds.prefix(3).map(\.displayTitle).joined(separator: "、")
    return (
      String(localized: "\(failedFeeds.count) 个订阅"),
      String(localized: "\(names) 等订阅刷新失败；可在左侧“需要处理”中逐项重试或修改地址。")
    )
  }

  func availableSources(matchingSourceIDs sourceIDs: Set<UUID>) -> [RSSFeed] {
    return store.feeds
      .filter { sourceIDs.contains($0.id) }
      .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
  }

  func availableAuthors(in articles: [RSSArticleHeader]) -> [String] {
    Array(Set(articles.compactMap { $0.author?.trimmedForPublishing.nilIfEmpty }))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  func availableTags(in articles: [RSSArticleHeader]) -> [String] {
    Array(Set(articles.flatMap(\.tags)))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  var scopeTitle: String {
    switch selectedScope {
    case .all:
      return "全部文章"
    case .unread:
      return "未读"
    case .starred:
      return "稍后阅读"
    case .feed(let feedID):
      return store.feeds.first { $0.id == feedID }?.displayTitle ?? "订阅"
    }
  }

  func articleCountDescription(
    displayedCount: Int,
    matchingCount: Int,
    scopedCount: Int
  ) -> String {
    if displayedCount < matchingCount {
      return String(localized: "显示 \(displayedCount) / 匹配 \(matchingCount) 篇 · 本机 \(scopedCount) 篇")
    }
    if hasActiveFilters {
      return String(localized: "匹配 \(matchingCount) 篇 · 本机 \(scopedCount) 篇")
    }
    return String(localized: "\(matchingCount) 篇 · 已抓取内容保存在本机")
  }

  func clearFilters() {
    searchDraft.text = ""
    presentation.debouncedSearchText = ""
    presentation.unreadOnly = false
    presentation.selectedSourceID = nil
    presentation.selectedAuthor = nil
    presentation.selectedTag = nil
    presentation.dateRange = .all
  }

  var emptyState: some View {
    VStack(spacing: 14) {
      RSSReaderEmptyState(
        title: emptyStateTitle,
        message: emptyStateMessage,
        systemImage: "tray"
      )
      Button("刷新", systemImage: "arrow.clockwise", action: retrySelectedScope)
        .buttonStyle(.bordered)
        .disabled(scopeIsRefreshing)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  var emptyStateTitle: LocalizedStringKey {
    switch selectedScope {
    case .unread: "没有未读文章"
    case .starred: "还没有稍后阅读的文章"
    case .feed where selectedFeed?.lastUpdatedAt != nil: "订阅有效，目前没有文章"
    default: "还没有文章"
    }
  }

  var emptyStateMessage: LocalizedStringKey {
    switch selectedScope {
    case .unread: "新文章到达后会出现在这里。"
    case .starred: "在文章行上选择“加入稍后阅读”，文章会收集到这里。"
    case .feed where selectedFeed?.lastUpdatedAt != nil: "该 RSS / Atom 已成功读取，只是尚未发布条目。"
    default: "刷新订阅后，文章会保存在本机供离线阅读。"
    }
  }

  var filteredEmptyState: some View {
    VStack(spacing: 14) {
      RSSReaderEmptyState(
        title: "没有匹配文章",
        message: "可以清除搜索、来源、作者、标签、日期或未读筛选。",
        systemImage: "line.3.horizontal.decrease.circle"
      )
      Button("清除全部筛选", action: clearFilters)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  func listProgressState(title: String, message: String) -> some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(title).font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)，\(message)")
  }

  func failureState(feedTitle: String, message: String) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 34))
        .foregroundStyle(WorkbenchTheme.risk)
        .accessibilityHidden(true)
      Text("“\(feedTitle)”读取失败")
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
      HStack(spacing: 10) {
        Button("重试", systemImage: "arrow.clockwise", action: retrySelectedScope)
          .buttonStyle(.bordered)
          .disabled(scopeIsRefreshing)
        if let selectedFeed {
          Button("修改地址", systemImage: "pencil") {
            feedPendingAddressEdit = selectedFeed
          }
          .workbenchProminentActionStyle()
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  func articleList(
    _ articles: [RSSArticleHeader],
    sections: [RSSArticleListSection],
    matchingCount: Int,
    feedLookup: RSSFeedLookup,
    showsRefreshBanner: Bool
  ) -> some View {
    VStack(spacing: 0) {
      if showsRefreshBanner {
        RSSArticleRefreshProgressLine()
      }
      if articles.isEmpty {
        filteredEmptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(
              alignment: .leading,
              spacing: 0,
              pinnedViews: [.sectionHeaders]
            ) {
              ForEach(sections) { section in
                Section {
                  ForEach(section.articles) { article in
                    articleRow(article, feed: feedLookup[article.feedID])
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(
                        selectedArticleID == article.id
                          ? Color.accentColor.opacity(0.12)
                          : Color.clear
                      )
                      .overlay(alignment: .leading) {
                        if selectedArticleID == article.id {
                          Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .frame(maxHeight: .infinity)
                            .allowsHitTesting(false)
                        }
                      }
                      .contentShape(Rectangle())
                      .id(article.id)
                      .onTapGesture {
                        selectArticle(article.id)
                      }
                  }
                } header: {
                  if let title = section.title {
                    Text(title)
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.secondary)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(.horizontal, 12)
                      .padding(.top, 12)
                      .padding(.bottom, 5)
                      .background(.regularMaterial)
                  } else {
                    EmptyView()
                  }
                }
              }

              if articles.count < matchingCount {
                Button {
                  presentation.loadMoreArticles(totalCount: matchingCount)
                } label: {
                  HStack {
                    Spacer()
                    Label(
                      "继续显示 \(min(RSSReaderPresentationState.articlePageSize, matchingCount - articles.count)) 篇",
                      systemImage: "chevron.down.circle"
                    )
                    Spacer()
                  }
                  .contentShape(Rectangle())
                  .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(
                  "继续显示本机文章，当前 \(articles.count) 篇，共 \(matchingCount) 篇"
                )
              }
            }
            .thinRedScroller()
          }
          .accessibilityLabel("RSS 文章列表")
          .accessibilityIdentifier("rss-article-list")
        }
      }
    }
  }

  func articleRow(_ article: RSSArticleHeader, feed: RSSFeed?) -> some View {
    RSSArticleRow(
      article: article,
      feed: feed,
      summary: article.readableSummary,
      readingProgress: readingProgressByArticle[article.id] ?? 0,
      isBatchSelectionMode: isBatchSelectionMode,
      isBatchSelected: selectedBatchArticleIDs.contains(article.id),
      onToggleBatchSelection: { toggleBatchSelection(article.id) },
      onToggleRead: { store.markRead(article.id, isRead: !article.isRead) },
      onToggleStarred: { store.toggleStarred(article.id) },
      onOpenOriginal: { openOriginal(article) }
    )
    .tag(article.id)
    .accessibilityIdentifier("rss-article-row-\(article.id)")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      selectArticle(article.id)
    }
    .contextMenu {
      Button(article.isRead ? "标为未读" : "标为已读") {
        store.markRead(article.id, isRead: !article.isRead)
      }
      Button(article.isStarred ? "移出稍后阅读" : "加入稍后阅读") {
        store.toggleStarred(article.id)
      }
      if article.link != nil {
        Divider()
        Button("打开原文") { openOriginal(article) }
      }
    }
  }

  private func selectArticle(_ articleID: String) {
    presentation.revealArticle(articleID, in: store)
    selectedArticleID = articleID
    isArticleListFocused = true
  }
}
