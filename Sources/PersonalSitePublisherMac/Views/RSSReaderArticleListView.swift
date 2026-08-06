import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// 后台准备的 RSS 列表派生数据（过滤/排序/分页/分组）。
private struct RSSPreparedArticleList: Equatable, Sendable {
  let matchingArticles: [RSSArticleHeader]
  let visibleArticles: [RSSArticleHeader]
  let sections: [RSSArticleListSection]
  let unreadMatchingArticleIDs: Set<String>
}

/// 决定何时需要重新准备列表的输入快照。
private struct RSSPrepareInput: Equatable {
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

/// RSS 文章列表的骨架屏占位：模拟文章行，列表在后台准备时显示，
/// 避免空白或转圈带来的跳动感。
private struct RSSArticleListSkeleton: View {
  @State private var isPulsing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(0..<8, id: \.self) { _ in
        skeletonRow
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .opacity(isPulsing ? 0.55 : 1)
    .animation(WorkbenchMotion.ambientPulse, value: isPulsing)
    .onAppear { isPulsing = true }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("正在准备文章列表")
  }

  private var skeletonRow: some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(Color.primary.opacity(0.06))
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.08))
          .frame(height: 12)
          .frame(maxWidth: 260)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.05))
          .frame(height: 10)
          .frame(maxWidth: 190)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.04))
          .frame(height: 10)
          .frame(maxWidth: 150)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

/// 刷新期间只保留轻量的顶部进度线，避免把正文列表推下去。
private struct RSSArticleRefreshProgressLine: View {
  @State private var isAnimating = false

  var body: some View {
    GeometryReader { geometry in
      let segmentWidth = max(48, geometry.size.width * 0.24)
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(Color.accentColor.opacity(0.14))
        Rectangle()
          .fill(Color.accentColor.opacity(0.9))
          .frame(width: segmentWidth)
          .offset(x: isAnimating ? geometry.size.width : -segmentWidth)
      }
    }
    .frame(height: 2)
    .clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("正在刷新文章列表")
    .accessibilityIdentifier("rss-article-refresh-progress")
    .onAppear {
      isAnimating = true
    }
    .onDisappear {
      isAnimating = false
    }
    .animation(
      .linear(duration: 1.15).repeatForever(autoreverses: false),
      value: isAnimating
    )
  }
}

struct RSSArticleList: View {
  @ObservedObject var store: RSSReaderStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @ObservedObject var searchDraft: RSSArticleSearchDraft
  @Binding var selectedArticleID: String?
  let workflowIsBusy: Bool
  let readingProgressByArticle: [String: Double]
  let onBatchSaveToKnowledge: ([String]) -> Void
  @State private var feedPendingAddressEdit: RSSFeed?
  @State private var isBatchSelectionMode = false
  @State private var selectedBatchArticleIDs = Set<String>()
  @FocusState private var isArticleListFocused: Bool
  /// 后台准备的列表数据（过滤/排序/分组）。nil 表示首次准备中。
  @State private var preparedList: RSSPreparedArticleList?

  var body: some View {
    let prepared = preparedList
    let matchingArticles = prepared?.matchingArticles ?? []
    let visibleArticles = prepared?.visibleArticles ?? []
    let visibleArticleSections = prepared?.sections ?? []
    let scopedArticles = presentation.scopedArticles(in: store)
    let unreadMatchingArticleIDs = prepared?.unreadMatchingArticleIDs ?? []
    let availableSources = availableSources(
      matchingSourceIDs: presentation.scopedSourceIDs(in: store)
    )
    let availableAuthors = presentation.scopedAuthors(in: store)
    let availableTags = presentation.scopedTags(in: store)
    let feedLookup = RSSFeedLookup(feeds: store.feeds)
    let currentListState = listState(
      matchingCount: matchingArticles.count,
      cachedCount: scopedArticles.count
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
                scopedCount: scopedArticles.count
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
        case let .failed(feedTitle, message):
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

  private var selectedScope: RSSArticleScope {
    presentation.selectedScope ?? .all
  }

  private var isSingleFeedScope: Bool {
    if case .feed = selectedScope { return true }
    return false
  }

  private var selectedFeed: RSSFeed? {
    guard case let .feed(feedID) = selectedScope else { return nil }
    return store.feeds.first { $0.id == feedID }
  }

  private var scopeIsRefreshing: Bool {
    if let selectedFeed {
      return store.refreshingFeedIDs.contains(selectedFeed.id)
    }
    return store.isRefreshing
  }

  private var hasActiveFilters: Bool {
    !presentation.debouncedSearchText.trimmedForPublishing.isEmpty
      || presentation.unreadOnly
      || presentation.selectedSourceID != nil
      || presentation.selectedAuthor != nil
      || presentation.selectedTag != nil
      || presentation.dateRange != .all
  }

  private var activeFilterCount: Int {
    var count = 0
    if !presentation.debouncedSearchText.trimmedForPublishing.isEmpty { count += 1 }
    if presentation.unreadOnly { count += 1 }
    if presentation.selectedSourceID != nil { count += 1 }
    if presentation.selectedAuthor != nil { count += 1 }
    if presentation.selectedTag != nil { count += 1 }
    if presentation.dateRange != .all { count += 1 }
    return count
  }

  private var articleFilterSortAccessibilityValue: String {
    var components: [String] = []
    if activeFilterCount == 0 {
      components.append("未启用筛选")
    } else {
      components.append("启用 \(activeFilterCount) 项筛选")
    }
    components.append("排序 \(presentation.sortOrder.title)")
    components.append(presentation.groupsByDate ? "按日期分组" : "不按日期分组")
    return components.joined(separator: "，")
  }

  private var advancedFilterCount: Int {
    var count = 0
    if presentation.selectedSourceID != nil { count += 1 }
    if presentation.selectedAuthor != nil { count += 1 }
    if presentation.selectedTag != nil { count += 1 }
    return count
  }

  @ViewBuilder
  private func filterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      wideFilterControls(
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )
      compactFilterControls(
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章筛选与排序")
    .accessibilityValue(articleFilterSortAccessibilityValue)
    .accessibilityIdentifier("rss-article-filter-sort")
  }

  private func wideFilterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Toggle("只看未读", isOn: $presentation.unreadOnly)
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("rss-unread-filter")

      Picker("日期", selection: $presentation.dateRange) {
        ForEach(RSSArticleDateRange.allCases) { range in
          Text(range.title).tag(range)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-date-filter")

      Picker("排序", selection: $presentation.sortOrder) {
        ForEach(RSSArticleSortOrder.allCases) { order in
          Text(order.title).tag(order)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-sort-picker")

      moreFilterMenu(
        label: advancedFilterCount > 0 ? "更多 \(advancedFilterCount)" : "更多",
        systemImage: advancedFilterCount > 0
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle",
        includesDate: false,
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )

      if activeFilterCount > 0 {
        Text("已启用 \(activeFilterCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      clearFiltersButton(showTitle: true)
      Spacer(minLength: 0)
    }
  }

  private func compactFilterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Toggle(isOn: $presentation.unreadOnly) {
        Image(systemName: presentation.unreadOnly ? "envelope.badge" : "envelope")
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .help("只看未读")
      .accessibilityLabel("只看未读")
      .accessibilityValue(presentation.unreadOnly ? "已启用" : "未启用")
      .accessibilityIdentifier("rss-unread-filter")

      Picker("排序", selection: $presentation.sortOrder) {
        ForEach(RSSArticleSortOrder.allCases) { order in
          Text(order.title).tag(order)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-sort-picker")

      moreFilterMenu(
        label: advancedFilterCount > 0 ? "筛选 \(advancedFilterCount)" : "筛选",
        systemImage: "line.3.horizontal.decrease.circle",
        includesDate: true,
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )

      clearFiltersButton(showTitle: false)
      Spacer(minLength: 0)
    }
  }

  private func moreFilterMenu(
    label: String,
    systemImage: String,
    includesDate: Bool,
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    Menu {
      Section("更多筛选") {
        if includesDate {
          Picker("日期", selection: $presentation.dateRange) {
            ForEach(RSSArticleDateRange.allCases) { range in
              Text(range.title).tag(range)
            }
          }
        }

        if !availableSources.isEmpty, !isSingleFeedScope {
          Picker("来源", selection: $presentation.selectedSourceID) {
            Text("全部来源").tag(UUID?.none)
            ForEach(availableSources) { feed in
              Text(feed.displayTitle).tag(Optional(feed.id))
            }
          }
        }

        if !availableAuthors.isEmpty {
          Picker("作者", selection: $presentation.selectedAuthor) {
            Text("全部作者").tag(String?.none)
            ForEach(availableAuthors, id: \.self) { author in
              Text(author).tag(Optional(author))
            }
          }
        }

        if !availableTags.isEmpty {
          Picker("标签", selection: $presentation.selectedTag) {
            Text("全部标签").tag(String?.none)
            ForEach(availableTags, id: \.self) { tag in
              Text(tag).tag(Optional(tag))
            }
          }
        }
      }

      Divider()
      Toggle("按日期分组", isOn: $presentation.groupsByDate)
    } label: {
      Label(label, systemImage: systemImage)
    }
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .accessibilityLabel("更多筛选")
    .accessibilityValue(
      advancedFilterCount > 0
        ? "已启用 \(advancedFilterCount) 项来源、作者或标签筛选"
        : "未启用来源、作者或标签筛选"
    )
    .accessibilityIdentifier("rss-more-filters")
  }

  private func clearFiltersButton(showTitle: Bool) -> some View {
    Button(
      showTitle ? "清除" : "",
      systemImage: "xmark.circle",
      action: clearFilters
    )
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(!hasActiveFilters)
    .help("清除所有筛选条件")
    .accessibilityLabel("清除筛选")
    .accessibilityIdentifier("rss-clear-filters")
  }

  @ViewBuilder
  private func batchSelectionControls(visibleArticles: [RSSArticleHeader]) -> some View {
    HStack(spacing: 8) {
      Text(String(format: String(localized: "已选择 %lld 篇"), selectedBatchArticleIDs.count))
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityLabel("已选择 \(selectedBatchArticleIDs.count) 篇文章")

      Button("全选当前显示文章", systemImage: "checklist.checked") {
        selectedBatchArticleIDs.formUnion(visibleArticles.map(\.id))
      }
      .buttonStyle(.borderless)
      .disabled(visibleArticles.isEmpty)

      Button("清除选择", systemImage: "xmark.circle") {
        selectedBatchArticleIDs.removeAll()
      }
      .buttonStyle(.borderless)
      .disabled(selectedBatchArticleIDs.isEmpty)

      Button("保存所选文章", systemImage: "tray.and.arrow.down") {
        onBatchSaveToKnowledge(Array(selectedBatchArticleIDs))
      }
      .workbenchProminentActionStyle()
      .disabled(selectedBatchArticleIDs.isEmpty || workflowIsBusy)
      .accessibilityLabel("将已选择的 \(selectedBatchArticleIDs.count) 篇文章保存到资料库")

      Button("退出批量选择（Esc）", systemImage: "escape") {
        endBatchSelection()
      }
      .buttonStyle(.borderless)
    }
    .controlSize(.small)
    .padding(.top, 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("RSS 文章批量操作")
  }

  private func toggleBatchSelection(_ articleID: String) {
    if selectedBatchArticleIDs.contains(articleID) {
      selectedBatchArticleIDs.remove(articleID)
    } else {
      selectedBatchArticleIDs.insert(articleID)
    }
  }

  private func endBatchSelection() {
    isBatchSelectionMode = false
    selectedBatchArticleIDs.removeAll()
  }

  private func listState(
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

  private func listContentPresentation(
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

  private var scopeFailure: (title: String, message: String)? {
    let failedFeeds: [RSSFeed]
    if let selectedFeed {
      failedFeeds = RSSArticlePresentationSupport.feedNeedsAttention(selectedFeed)
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

  private func availableSources(matchingSourceIDs sourceIDs: Set<UUID>) -> [RSSFeed] {
    return store.feeds
      .filter { sourceIDs.contains($0.id) }
      .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
  }

  private func availableAuthors(in articles: [RSSArticleHeader]) -> [String] {
    Array(Set(articles.compactMap { $0.author?.trimmedForPublishing.nilIfEmpty }))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private func availableTags(in articles: [RSSArticleHeader]) -> [String] {
    Array(Set(articles.flatMap(\.tags)))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private var scopeTitle: String {
    switch selectedScope {
    case .all:
      return "全部文章"
    case .unread:
      return "未读"
    case .starred:
      return "稍后阅读"
    case let .feed(feedID):
      return store.feeds.first { $0.id == feedID }?.displayTitle ?? "订阅"
    }
  }

  private func articleCountDescription(
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

  private func clearFilters() {
    searchDraft.text = ""
    presentation.debouncedSearchText = ""
    presentation.unreadOnly = false
    presentation.selectedSourceID = nil
    presentation.selectedAuthor = nil
    presentation.selectedTag = nil
    presentation.dateRange = .all
  }

  private var prepareInput: RSSPrepareInput {
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
  private func prepareList() async {
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
      return RSSPreparedArticleList(
        matchingArticles: matching,
        visibleArticles: visible,
        sections: sections,
        unreadMatchingArticleIDs: unreadIDs
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

  private func openOriginal(_ article: RSSArticleHeader) {
    guard let link = article.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      presentation.errorMessage = message
    }
  }

  private func moveArticleSelection(by offset: Int) {
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

  private func openSelectedArticle() {
    if let selectedArticleID,
       store.articleHeader(id: selectedArticleID) != nil {
      presentation.revealArticle(selectedArticleID, in: store)
      self.selectedArticleID = selectedArticleID
    } else {
      moveArticleSelection(by: 1)
    }
  }

  private func retrySelectedScope() {
    if let selectedFeed {
      Task { await store.refresh(feedID: selectedFeed.id, force: true) }
    } else {
      Task { await store.refreshAll() }
    }
  }

  private var emptyState: some View {
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

  private var emptyStateTitle: LocalizedStringKey {
    switch selectedScope {
    case .unread: "没有未读文章"
    case .starred: "还没有稍后阅读的文章"
    case .feed where selectedFeed?.lastUpdatedAt != nil: "订阅有效，目前没有文章"
    default: "还没有文章"
    }
  }

  private var emptyStateMessage: LocalizedStringKey {
    switch selectedScope {
    case .unread: "新文章到达后会出现在这里。"
    case .starred: "在文章行上选择“加入稍后阅读”，文章会收集到这里。"
    case .feed where selectedFeed?.lastUpdatedAt != nil: "该 RSS / Atom 已成功读取，只是尚未发布条目。"
    default: "刷新订阅后，文章会保存在本机供离线阅读。"
    }
  }

  private var filteredEmptyState: some View {
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

  private func listProgressState(title: String, message: String) -> some View {
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

  private func failureState(feedTitle: String, message: String) -> some View {
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

  private func articleList(
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
                          selectedArticleID = article.id
                          isArticleListFocused = true
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
          .onChange(of: selectedArticleID) { _, articleID in
            guard let articleID else { return }
            DispatchQueue.main.async {
              withAnimation(WorkbenchMotion.quick) {
                proxy.scrollTo(articleID, anchor: .center)
              }
            }
          }
        }
      }
    }
  }

  private func articleRow(_ article: RSSArticleHeader, feed: RSSFeed?) -> some View {
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
}

struct RSSArticleRow: View {
  let article: RSSArticleHeader
  let feed: RSSFeed?
  let summary: String
  let readingProgress: Double
  let isBatchSelectionMode: Bool
  let isBatchSelected: Bool
  let onToggleBatchSelection: () -> Void
  let onToggleRead: () -> Void
  let onToggleStarred: () -> Void
  let onOpenOriginal: () -> Void
  @State private var isHovering = false

  var body: some View {
    let relativeDate = (article.publishedAt ?? article.fetchedAt).formatted(
      .relative(presentation: .named, unitsStyle: .abbreviated)
    )
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
      if isBatchSelectionMode {
        Toggle(
          "选择文章",
          isOn: Binding(
            get: { isBatchSelected },
            set: { _ in onToggleBatchSelection() }
          )
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .accessibilityLabel("选择文章：\(article.title)")
        .accessibilityValue(isBatchSelected ? "已选择" : "未选择")
      }
      Circle()
        .fill(article.isRead ? Color.clear : Color.accentColor)
        .frame(width: 7, height: 7)
        .scaleEffect(isHovering && !article.isRead ? 1.15 : 1)
        .animation(.easeInOut(duration: 0.16), value: isHovering)
        .overlay {
          Circle()
            .stroke(article.isRead ? Color.secondary.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .padding(.top, 6)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(article.title)
          .font(article.isRead ? .body : .body.weight(.semibold))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          if let feed {
            Text(feed.displayTitle)
          }
          if let author = article.author?.trimmedForPublishing.nilIfEmpty {
            Text(author)
          }
          Text(relativeDate)
          if article.isStarred {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .accessibilityHidden(true)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)

        if summary.isEmpty {
          Text("暂无摘要")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else {
          Text(summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(article.title)
      .accessibilityValue(accessibilityValue(relativeDate: relativeDate))

      if let coverURL = article.coverURL {
        RSSArticleCoverThumbnail(articleID: article.id, url: coverURL)
      }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .contain)

      if normalizedReadingProgress > 0 {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(Color.accentColor.opacity(0.12))
            Rectangle()
              .fill(Color.accentColor)
              .frame(width: geometry.size.width * normalizedReadingProgress)
          }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !isBatchSelectionMode {
        articleActionButtons
          .padding(.top, 6)
          .padding(.trailing, 8)
          .opacity(isHovering ? 1 : 0)
          .allowsHitTesting(isHovering)
      }
    }
    .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
    .onHover { isHovering = $0 }
    .accessibilityIdentifier("rss-article-row-content-\(article.id)")
    .accessibilityElement(children: .contain)
  }

  private var articleActionButtons: some View {
    HStack(spacing: 3) {
      Button(action: onToggleRead) {
        Image(systemName: article.isRead ? "envelope.badge" : "checkmark.circle")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(article.isRead ? "标为未读" : "标为已读")
      .accessibilityLabel(article.isRead ? "标为未读" : "标为已读")

      Button(action: onToggleStarred) {
        Image(systemName: article.isStarred ? "star.slash" : "star")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(article.isStarred ? "移出稍后阅读" : "加入稍后阅读")
      .accessibilityLabel(article.isStarred ? "移出稍后阅读" : "加入稍后阅读")

      if article.link != nil {
        Button(action: onOpenOriginal) {
          Image(systemName: "safari")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("打开原文")
        .accessibilityLabel("打开原文")
      }
    }
    .padding(4)
    .background(.regularMaterial, in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章操作")
  }

  private func accessibilityValue(relativeDate: String) -> String {
    var components = [
      feed?.displayTitle ?? "RSS",
      relativeDate,
      article.isRead ? String(localized: "已读") : String(localized: "未读"),
    ]
    if let author = article.author?.trimmedForPublishing.nilIfEmpty {
      components.append(String(localized: "作者 \(author)"))
    }
    if article.isStarred { components.append(String(localized: "稍后阅读")) }
    if !article.tags.isEmpty {
      components.append(String(localized: "标签 \(article.tags.joined(separator: "、"))"))
    }
    if summary.isEmpty {
      components.append(String(localized: "暂无摘要"))
    } else {
      components.append(String(localized: "摘要 \(String(summary.prefix(240)))"))
    }
    components.append(String(localized: "已读 \(readingProgressPercentage)%"))
    return components.joined(separator: "，")
  }

  private var normalizedReadingProgress: Double {
    min(max(readingProgress, 0), 1)
  }

  private var readingProgressPercentage: Int {
    Int((normalizedReadingProgress * 100).rounded())
  }

}
