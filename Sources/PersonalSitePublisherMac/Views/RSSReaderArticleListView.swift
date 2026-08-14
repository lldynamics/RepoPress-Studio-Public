import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// 后台准备的 RSS 列表派生数据（过滤/排序/分页/分组）。
///
/// Facets, counts and navigation indexes live beside the visible rows so a
/// SwiftUI body recomputation never needs to synchronously rescan the full
/// archive when a prepared snapshot is available.
struct RSSPreparedPresentationSnapshot: Equatable, Sendable {
  let matchingArticles: [RSSArticleHeader]
  let visibleArticles: [RSSArticleHeader]
  let sections: [RSSArticleListSection]
  let unreadMatchingArticleIDs: Set<String>
  let scopedArticleCount: Int
  let unreadArticleCount: Int
  let sourceIDs: Set<UUID>
  let authors: [String]
  let tags: [String]
  let articleIDsByIndex: [String]
  let indexByArticleID: [String: Int]
}
struct RSSArticleList: View {
  @ObservedObject var store: RSSReaderStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @ObservedObject var searchDraft: RSSArticleSearchDraft
  @Binding var selectedArticleID: String?
  let workflowIsBusy: Bool
  let readingProgressByArticle: [String: Double]
  let onBatchSaveToKnowledge: ([String]) -> Void
  @State var feedPendingAddressEdit: RSSFeed?
  @State var isBatchSelectionMode = false
  @State var selectedBatchArticleIDs = Set<String>()
  @FocusState var isArticleListFocused: Bool
  /// 后台准备的列表数据（过滤/排序/分组）。nil 表示首次准备中。
  @State var preparedList: RSSPreparedPresentationSnapshot?

  var body: some View {
    let prepared = preparedList
    let matchingArticles = prepared?.matchingArticles ?? []
    let visibleArticles = prepared?.visibleArticles ?? []
    let visibleArticleSections = prepared?.sections ?? []
    let scopedCount = prepared?.scopedArticleCount ?? 0
    let unreadMatchingArticleIDs = prepared?.unreadMatchingArticleIDs ?? []
    let availableSources = availableSources(
      matchingSourceIDs: prepared?.sourceIDs ?? []
    )
    let availableAuthors = prepared?.authors ?? []
    let availableTags = prepared?.tags ?? []
    let feedLookup = RSSFeedLookup(feeds: store.feeds)
    let currentListState = listState(
      matchingCount: matchingArticles.count,
      cachedCount: scopedCount
    )

    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(scopeTitle)
              .font(.workbenchPageTitle)
              .fixedSize(horizontal: false, vertical: true)
            Text(
              articleCountDescription(
                displayedCount: visibleArticles.count,
                matchingCount: matchingArticles.count,
                scopedCount: scopedCount
              )
            )
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if !isBatchSelectionMode {
            Menu {
              if !unreadMatchingArticleIDs.isEmpty {
                Button {
                  store.markAllRead(articleIDs: unreadMatchingArticleIDs)
                } label: {
                  Label(
                    "全部已读（\(unreadMatchingArticleIDs.count)）",
                    systemImage: "checkmark.circle"
                  )
                }
                .help("将当前列表中的文章标为已读")
                .accessibilityIdentifier("rss-mark-all-read")
              }
              Button("批量选择", systemImage: "checklist") {
                isBatchSelectionMode = true
              }
              .accessibilityLabel("批量选择 RSS 文章")
              .accessibilityIdentifier("rss-batch-select")
            } label: {
              Label("文章操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel("文章操作")
            .accessibilityIdentifier("rss-article-actions")
          }
        }

        filterControls(
          availableSources: availableSources,
          availableAuthors: availableAuthors,
          availableTags: availableTags
        )

        if isBatchSelectionMode {
          batchSelectionControls(visibleArticles: visibleArticles)
        }
      }
      .padding(WorkbenchSpacing.section)

      Divider()

      if prepared == nil {
        RSSArticleListSkeleton()
      } else if let showsRefreshBanner = listContentPresentation(for: currentListState) {
        articleList(
          visibleArticles,
          sections: visibleArticleSections,
          matchingCount: matchingArticles.count,
          feedLookup: feedLookup,
          showsRefreshBanner: showsRefreshBanner
        )
      } else {
        switch currentListState {
        case .loading:
          listProgressState(
            title: String(localized: "正在读取文章…"),
            message: String(localized: "首次刷新完成后，文章会缓存在本机。")
          )
        case .failed(let feedTitle, let message):
          failureState(feedTitle: feedTitle, message: message)
        case .empty:
          emptyState
        case .filteredEmpty:
          filteredEmptyState
        case .content, .refreshing, .staleContent:
          EmptyView()
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-article-list")
    .focusable()
    .focusEffectDisabled()
    .focused($isArticleListFocused)
    .accessibilityHint("点击文章后，可使用上下箭头浏览，按 Return 打开文章")
    .onKeyPress(.upArrow) {
      moveArticleSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveArticleSelection(by: 1)
      return .handled
    }
    .onKeyPress(.return) {
      openSelectedArticle()
      return .handled
    }
    .onExitCommand {
      if isBatchSelectionMode { endBatchSelection() }
    }
    .task(id: searchDraft.text) {
      if !searchDraft.text.isEmpty {
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      guard !Task.isCancelled else { return }
      presentation.debouncedSearchText = searchDraft.text
    }
    .task(id: prepareInput) {
      await prepareList()
    }
    .sheet(item: $feedPendingAddressEdit) { feed in
      RSSEditFeedURLSheet(feed: feed) { newURL in
        try store.updateFeedURL(feedID: feed.id, newURL: newURL)
        Task { await store.refresh(feedID: feed.id, force: true) }
      }
    }
  }

}
