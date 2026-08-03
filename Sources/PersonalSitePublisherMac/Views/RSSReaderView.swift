import AppKit
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class RSSArticleSearchDraft: ObservableObject {
  @Published var text = ""
}

@MainActor
final class RSSReaderPresentationState: ObservableObject {
  private struct ArticleScopeCacheKey: Equatable {
    let revision: UInt64
    let scope: RSSArticleScope
  }

  private struct ArticleQueryCacheKey: Equatable {
    let revision: UInt64
    let scope: RSSArticleScope
    let searchText: String
    let unreadOnly: Bool
    let sourceID: UUID?
    let author: String?
    let tag: String?
    let dateRange: String
    let sortOrder: String
  }

  private struct ArticleFacets {
    let sourceIDs: Set<UUID>
    let authors: [String]
    let tags: [String]
  }

  private struct ReaderMetricsCacheEntry {
    let fetchedAt: Date
    let hasReadableText: Bool
    let readingMinutes: Int
  }

  static let articlePageSize = 120

  @Published var selectedScope: RSSArticleScope? = .all
  @Published var selectedArticleID: String?
  @Published var debouncedSearchText = ""
  @Published var unreadOnly = false
  @Published var sortOrder: RSSArticleSortOrder = .newest
  @Published var groupsByDate = true
  @Published var selectedSourceID: UUID?
  @Published var selectedAuthor: String?
  @Published var selectedTag: String?
  @Published var dateRange: RSSArticleDateRange = .all
  @Published var isAddSubscriptionPresented = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published private(set) var articleDisplayLimit = 120
  fileprivate let searchDraft = RSSArticleSearchDraft()

  private var scopedArticlesCache: (key: ArticleScopeCacheKey, articles: [RSSArticleHeader])?
  private var matchingArticlesCache: (
    key: ArticleQueryCacheKey,
    articles: [RSSArticleHeader],
    unreadArticleIDs: Set<String>
  )?
  private var articleFacetsCache: (key: ArticleScopeCacheKey, facets: ArticleFacets)?
  private var readerMetricsCache: [String: ReaderMetricsCacheEntry] = [:]
  private var readerMetricsLRU: [String] = []
  private var sidebarCountsCache: (revision: UInt64, counts: RSSFeedSidebarCounts)?

  func matchingArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    let key = articleQueryCacheKey(in: store)
    if let matchingArticlesCache, matchingArticlesCache.key == key {
      return matchingArticlesCache.articles
    }
    let base = store.articleHeaders(
      for: selectedScope ?? .all,
      searchText: debouncedSearchText,
      unreadOnly: unreadOnly
    )
    let result = RSSArticlePresentationSupport.applyFiltersAndSort(
      to: base,
      sourceID: selectedSourceID,
      author: selectedAuthor,
      tag: selectedTag,
      dateRange: dateRange,
      sortOrder: sortOrder
    )
    matchingArticlesCache = (
      key,
      result,
      Set(result.lazy.filter { !$0.isRead }.map(\.id))
    )
    return result
  }

  func unreadMatchingArticleIDs(in store: RSSReaderStore) -> Set<String> {
    let key = articleQueryCacheKey(in: store)
    if let matchingArticlesCache, matchingArticlesCache.key == key {
      return matchingArticlesCache.unreadArticleIDs
    }
    _ = matchingArticles(in: store)
    return matchingArticlesCache?.unreadArticleIDs ?? []
  }

  func scopedArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    let scope = selectedScope ?? .all
    let key = ArticleScopeCacheKey(revision: store.mutationRevision, scope: scope)
    if let scopedArticlesCache, scopedArticlesCache.key == key {
      return scopedArticlesCache.articles
    }
    let result = store.articleHeaders(for: scope)
    scopedArticlesCache = (key, result)
    return result
  }

  func visibleArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    Array(matchingArticles(in: store).prefix(articleDisplayLimit))
  }

  func scopedSourceIDs(in store: RSSReaderStore) -> Set<UUID> {
    scopedFacets(in: store).sourceIDs
  }

  func scopedAuthors(in store: RSSReaderStore) -> [String] {
    scopedFacets(in: store).authors
  }

  func scopedTags(in store: RSSReaderStore) -> [String] {
    scopedFacets(in: store).tags
  }

  func resetArticleDisplayLimit() {
    guard articleDisplayLimit != Self.articlePageSize else { return }
    articleDisplayLimit = Self.articlePageSize
  }

  func loadMoreArticles(totalCount: Int) {
    let nextLimit = min(totalCount, articleDisplayLimit + Self.articlePageSize)
    guard nextLimit != articleDisplayLimit else { return }
    articleDisplayLimit = nextLimit
  }

  func revealArticle(_ articleID: String, in store: RSSReaderStore) {
    let matching = matchingArticles(in: store)
    guard let index = matching.firstIndex(where: { $0.id == articleID }) else { return }
    let requiredLimit = ((index / Self.articlePageSize) + 1) * Self.articlePageSize
    let nextLimit = min(matching.count, max(articleDisplayLimit, requiredLimit))
    guard nextLimit != articleDisplayLimit else { return }
    articleDisplayLimit = nextLimit
  }

  func sidebarCounts(in store: RSSReaderStore) -> RSSFeedSidebarCounts {
    if let sidebarCountsCache, sidebarCountsCache.revision == store.mutationRevision {
      return sidebarCountsCache.counts
    }
    let counts = RSSFeedSidebarCounts(articles: store.articleHeaders)
    sidebarCountsCache = (store.mutationRevision, counts)
    return counts
  }

  func articleHeader(id: String?, in store: RSSReaderStore) -> RSSArticleHeader? {
    guard let id else { return nil }
    return store.articleHeader(id: id)
  }

  func readerMetrics(for article: RSSArticle) -> (hasReadableText: Bool, readingMinutes: Int) {
    if let cached = readerMetricsCache[article.id],
       cached.fetchedAt == article.fetchedAt {
      touchReaderMetrics(article.id)
      return (cached.hasReadableText, cached.readingMinutes)
    }
    let text = article.readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    let latinWords = text.split { $0.isWhitespace || $0.isPunctuation }.count
    let cjkCharacters = text.unicodeScalars.filter { scalar in
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
        true
      default:
        false
      }
    }.count
    let readingUnits = max(latinWords, cjkCharacters)
    let metrics = ReaderMetricsCacheEntry(
      fetchedAt: article.fetchedAt,
      hasReadableText: !text.isEmpty,
      readingMinutes: max(1, Int(ceil(Double(readingUnits) / 220.0)))
    )
    readerMetricsCache[article.id] = metrics
    touchReaderMetrics(article.id)
    if readerMetricsLRU.count > 100 {
      let evictedID = readerMetricsLRU.removeFirst()
      readerMetricsCache.removeValue(forKey: evictedID)
    }
    return (metrics.hasReadableText, metrics.readingMinutes)
  }

  private func touchReaderMetrics(_ articleID: String) {
    readerMetricsLRU.removeAll { $0 == articleID }
    readerMetricsLRU.append(articleID)
  }

  private func articleQueryCacheKey(in store: RSSReaderStore) -> ArticleQueryCacheKey {
    ArticleQueryCacheKey(
      revision: store.mutationRevision,
      scope: selectedScope ?? .all,
      searchText: debouncedSearchText,
      unreadOnly: unreadOnly,
      sourceID: selectedSourceID,
      author: selectedAuthor,
      tag: selectedTag,
      dateRange: dateRange.rawValue,
      sortOrder: sortOrder.rawValue
    )
  }

  private func scopedFacets(in store: RSSReaderStore) -> ArticleFacets {
    let scope = selectedScope ?? .all
    let key = ArticleScopeCacheKey(revision: store.mutationRevision, scope: scope)
    if let articleFacetsCache, articleFacetsCache.key == key {
      return articleFacetsCache.facets
    }
    let articles = scopedArticles(in: store)
    let facets = ArticleFacets(
      sourceIDs: Set(articles.map(\.feedID)),
      authors: Array(Set(articles.compactMap { $0.author?.trimmedForPublishing.nilIfEmpty }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      tags: Array(Set(articles.flatMap(\.tags)))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    )
    articleFacetsCache = (key, facets)
    return facets
  }

  func synchronizeSelection(
    in store: RSSReaderStore,
    preservingExistingArticle: Bool = false
  ) {
    guard let selectedArticleID else { return }
    if preservingExistingArticle,
       store.articleHeader(id: selectedArticleID) != nil {
      return
    }
    if !matchingArticles(in: store).contains(where: { $0.id == selectedArticleID }) {
      self.selectedArticleID = nil
    }
  }

  func addSubscription(_ value: String, to store: RSSReaderStore) {
    let trimmedValue = value.trimmedForPublishing
    guard let url = URL(string: trimmedValue) else {
      errorMessage = RSSReaderError.invalidFeedURL.localizedDescription
      return
    }
    isAddSubscriptionPresented = false
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let discovered = (try? await RSSFeedDiscoveryService().discover(from: url)) ?? []
        let feedURLs = discovered.isEmpty ? [url] : discovered
        var feedIDs: [UUID] = []
        for feedURL in feedURLs {
          feedIDs.append(try store.addFeed(url: feedURL))
        }
        guard let firstFeedID = feedIDs.first else {
          throw RSSReaderError.invalidFeedURL
        }
        selectedScope = .feed(firstFeedID)
        selectedArticleID = nil
        for feedID in feedIDs {
          await store.refresh(feedID: feedID)
        }
        synchronizeSelection(in: store)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func importOPML(from store: RSSReaderStore) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      .xml,
      UTType(filenameExtension: "opml") ?? .data
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else {
        throw RSSReaderError.invalidOPML("文件超过 5 MB")
      }
      let originalData = try Data(contentsOf: url)
      let subscriptions = try RSSOPMLParser.parse(data: originalData)
      let riskReport = RSSOPMLWriter.scanExportRisks(subscriptions: subscriptions)
      let importData: Data
      if riskReport.hasSuspectedCredentialQueryParameters {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "OPML 中的地址可能包含访问凭证")
        alert.informativeText = credentialRiskDescription(
          report: riskReport,
          actionDescription: String(
            localized: "可以将疑似凭证值替换为 REDACTED 后导入，或排除有风险的订阅。脱敏后需要有效凭证的订阅可能无法刷新。"
          )
        )
        alert.addButton(withTitle: String(localized: "脱敏后导入"))
        alert.addButton(withTitle: String(localized: "排除后导入"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
          importData = try RSSOPMLWriter.prepareDocument(
            subscriptions: subscriptions,
            privacyAction: .redactCredentialQueryValues
          ).data
        case .alertSecondButtonReturn:
          importData = try RSSOPMLWriter.prepareDocument(
            subscriptions: subscriptions,
            privacyAction: .excludeSubscriptionsWithCredentialQuery
          ).data
        default:
          return
        }
      } else {
        importData = originalData
      }

      let ids = try store.importOPML(data: importData)
      isAddSubscriptionPresented = false
      selectedScope = ids.first.map(RSSArticleScope.feed) ?? .all
      selectedArticleID = nil
      Task { @MainActor [weak self] in
        for feedID in ids {
          await store.refresh(feedID: feedID)
        }
        self?.synchronizeSelection(in: store)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func exportOPML(from store: RSSReaderStore) {
    errorMessage = nil
    guard !store.feeds.isEmpty else {
      statusMessage = String(localized: "没有可导出的 RSS 订阅。")
      return
    }

    do {
      let subscriptions = store.feeds.map {
        RSSOPMLSubscription(title: $0.displayTitle, url: $0.url, siteURL: $0.siteURL)
      }
      let riskReport = RSSOPMLWriter.scanExportRisks(subscriptions: subscriptions)
      guard !riskReport.hasBlockingUserInfo else {
        throw RSSReaderError.invalidOPML("订阅地址包含 URL 用户名或密码，请先修改地址。")
      }

      let privacyAction: RSSOPMLExportPrivacyAction
      if riskReport.hasSuspectedCredentialQueryParameters {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "导出前处理可能的访问凭证")
        alert.informativeText = credentialRiskDescription(
          report: riskReport,
          actionDescription: String(
            localized: "可以保留订阅并将疑似凭证值替换为 REDACTED，或整个排除这些订阅。"
          )
        )
        alert.addButton(withTitle: String(localized: "脱敏导出"))
        alert.addButton(withTitle: String(localized: "排除风险订阅"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
          privacyAction = .redactCredentialQueryValues
        case .alertSecondButtonReturn:
          privacyAction = .excludeSubscriptionsWithCredentialQuery
        default:
          return
        }
      } else {
        privacyAction = .redactCredentialQueryValues
      }

      let prepared = try RSSOPMLWriter.prepareDocument(
        subscriptions: subscriptions,
        title: "RepoPress Studio RSS 订阅",
        privacyAction: privacyAction
      )

      let panel = NSSavePanel()
      panel.title = String(localized: "导出 OPML")
      panel.message = String(
        localized: "OPML 仅包含订阅名称与地址，不包含文章缓存或阅读状态。"
      )
      panel.prompt = String(localized: "导出")
      panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = "rss-subscriptions.opml"
      guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

      let destinationURL = selectedURL.pathExtension.isEmpty
        ? selectedURL.appendingPathExtension("opml")
        : selectedURL
      try prepared.data.write(to: destinationURL, options: .atomic)
      let excludedSuffix = prepared.excludedSubscriptionCount > 0
        ? String(localized: "，已排除 \(prepared.excludedSubscriptionCount) 个风险订阅")
        : ""
      statusMessage = String(
        localized: "已导出 \(prepared.exportedSubscriptionCount) 个订阅到 \(destinationURL.lastPathComponent)\(excludedSuffix)。"
      )
    } catch {
      statusMessage = nil
      errorMessage = String(
        format: String(localized: "OPML 导出失败：%@"),
        error.localizedDescription
      )
    }
  }

  private func credentialRiskDescription(
    report: RSSSubscriptionURLPrivacyReport,
    actionDescription: String
  ) -> String {
    let names = report.suspectedCredentialQueryParameterNames
      .prefix(8)
      .joined(separator: "、")
    let parameterSummary = names.isEmpty
      ? String(localized: "未识别具体参数名。")
      : String(localized: "疑似参数：\(names)。")
    return String(
      localized: "检测到 \(report.affectedSubscriptionCount) 个订阅可能包含访问凭证。\(parameterSummary)\n\n\(actionDescription)"
    )
  }

}

private struct RSSHighlightDraft: Identifiable {
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

private struct RSSArticleLoadRequest: Equatable {
  let articleID: String?
  let retryToken: Int
  let articleRevision: Date?
}

struct RSSReaderView: View {
  @ObservedObject var store: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @State private var excerptNoteArticle: RSSArticle?
  @State private var highlightDraft: RSSHighlightDraft?
  @State private var tagEditorArticle: RSSArticle?
  @State private var selectedReaderText = ""
  @State private var allowRemoteImages = false
  @State private var workflowMessage: String?
  @State private var workflowIsBusy = false
  @State private var usesNarrowLayout = false
  @State private var selectedArticlePayload: RSSArticle?
  @State private var selectedArticleLoadError: String?
  @State private var selectedArticleIsLoading = false
  @State private var selectedArticleReloadToken = 0
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    let loadRequest = selectedArticleLoadRequest
    VStack(spacing: 0) {
      readerSplitView
      statusBar
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-workspace")
    .focusedValue(\.rssReaderCommandActions, readerCommandActions)
    .onAppear {
      presentation.synchronizeSelection(in: store)
    }
    .onChange(of: presentation.selectedScope) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.selectedArticleID = nil
      presentation.selectedSourceID = nil
      selectedReaderText = ""
      allowRemoteImages = false
      presentation.synchronizeSelection(in: store)
    }
    .onChange(of: presentation.selectedArticleID) { _, _ in
      selectedReaderText = ""
      allowRemoteImages = false
      selectedArticlePayload = nil
      selectedArticleLoadError = nil
      selectedArticleIsLoading = false
    }
    .task(id: loadRequest) {
      await loadSelectedArticle(loadRequest)
    }
    .onChange(of: presentation.debouncedSearchText) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.unreadOnly) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.selectedSourceID) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.selectedAuthor) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.selectedTag) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.dateRange) { _, _ in
      presentation.resetArticleDisplayLimit()
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .onChange(of: presentation.sortOrder) { _, _ in
      presentation.resetArticleDisplayLimit()
    }
    .onChange(of: store.mutationRevision) { _, _ in
      presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    }
    .sheet(item: $excerptNoteArticle) { article in
      RSSExcerptNoteSheet(article: article) { excerpt, note in
        saveExcerptNote(for: article, excerpt: excerpt, note: note)
      }
    }
    .sheet(isPresented: $presentation.isAddSubscriptionPresented) {
      RSSAddSubscriptionView(
        onAdd: { value in presentation.addSubscription(value, to: store) },
        onImportOPML: { presentation.importOPML(from: store) }
      )
    }
    .sheet(item: $highlightDraft) { draft in
      RSSHighlightEditorSheet(
        text: draft.text,
        initialNote: draft.initialNote,
        initialTags: draft.initialTags,
        onSave: { note, tags in
          saveHighlight(draft, note: note, tags: tags)
        }
      )
    }
    .sheet(item: $tagEditorArticle) { article in
      RSSArticleTagsSheet(
        article: article,
        onSave: { tags in
          store.setArticleTags(tags, for: article.id)
          selectedArticlePayload?.tags = store.articleHeader(id: article.id)?.tags ?? tags
          workflowMessage = String(localized: "文章标签已保存。")
          tagEditorArticle = nil
        }
      )
    }
    .alert("RSS 操作失败", isPresented: errorAlertBinding) {
      Button("确定") { presentation.errorMessage = nil }
    } message: {
      Text(presentation.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var statusBar: some View {
    if store.statusMessage != nil || store.lastError != nil || presentation.statusMessage != nil
      || workflowMessage != nil || store.canUndoLastDeletion || store.canUndoLastBatchRead {
      Divider()
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          if let summary = store.lastRefreshSummary {
            Text(refreshSummaryText(summary))
              .fontWeight(summary.failureCount == 0 ? .regular : .semibold)
          }
          if let statusMessage = store.statusMessage,
             store.lastRefreshSummary?.statusText != statusMessage {
            Text(statusMessage)
              .foregroundStyle(.secondary)
          }
          if let lastError = store.lastError {
            Text(lastError)
              .foregroundStyle(WorkbenchTheme.risk)
              .textSelection(.enabled)
          }
          if let workflowMessage {
            Text(workflowMessage)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          if let presentationStatusMessage = presentation.statusMessage {
            Text(presentationStatusMessage)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        if store.canUndoLastBatchRead {
          Button("撤销全部已读") {
            store.undoLastBatchRead()
          }
          .buttonStyle(.bordered)
          .accessibilityLabel("撤销上一次批量标记已读")
        }
        if store.canUndoLastDeletion {
          Button("撤销删除") {
            store.undoLastDeletion()
          }
          .buttonStyle(.bordered)
          .accessibilityLabel("撤销删除订阅和本地缓存")
        }
      }
      .padding(.horizontal, WorkbenchSpacing.section)
      .padding(.vertical, 8)
      .background(WorkbenchBackgroundStyle.panel)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(store.lastError == nil ? "RSS 状态" : "RSS 错误")
    }
  }

  @ViewBuilder
  private var readerSplitView: some View {
    if store.feeds.isEmpty {
      RSSReaderWelcomeView(
        onAdd: { presentation.isAddSubscriptionPresented = true },
        onImportOPML: { presentation.importOPML(from: store) },
        onDiscover: { value in presentation.addSubscription(value, to: store) }
      )
    } else {
      GeometryReader { geometry in
        let isWide = geometry.size.width >= 900
        let showsArticleList = isWide || selectedArticleHeader == nil
        let articleWidth = isWide
          ? min(max(geometry.size.width * 0.36, 340), 420)
          : (showsArticleList ? geometry.size.width : 0)
        let dividerWidth: CGFloat = isWide ? 1 : 0
        let readerWidth = max(0, geometry.size.width - articleWidth - dividerWidth)

        HStack(spacing: 0) {
          articleColumn
            .frame(width: articleWidth, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(showsArticleList)
            .accessibilityHidden(!showsArticleList)

          Divider()
            .frame(width: dividerWidth)
            .opacity(isWide ? 1 : 0)

          readerColumn(showsBackButton: !isWide)
            .frame(width: readerWidth, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(isWide || !showsArticleList)
            .accessibilityHidden(!isWide && showsArticleList)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        .onAppear { usesNarrowLayout = !isWide }
        .onChange(of: geometry.size.width) { _, width in
          usesNarrowLayout = width < 900
        }
      }
    }
  }

  private var articleColumn: some View {
    RSSArticleList(
      store: store,
      presentation: presentation,
      searchDraft: presentation.searchDraft,
      selectedArticleID: $presentation.selectedArticleID,
      isSearchFocused: $isSearchFocused
    )
  }

  private func readerColumn(showsBackButton: Bool) -> some View {
    let article = selectedArticle
    let metrics = article.map { presentation.readerMetrics(for: $0) }
    return RSSArticleReader(
      articleHeader: selectedArticleHeader,
      article: article,
      isLoading: selectedArticleIsLoading,
      loadError: selectedArticleLoadError,
      feedTitle: selectedFeedTitle,
      feedIconURL: selectedFeed?.iconURL,
      highlights: article.map { store.highlights(for: $0.id) } ?? [],
      mediaAssets: article.map { store.mediaAssets(for: $0.id) } ?? [],
      mediaCacheDirectoryURL: store.mediaCacheDirectoryURL,
      hasReadableText: metrics?.hasReadableText ?? false,
      readingMinutes: metrics?.readingMinutes ?? 1,
      allowRemoteImages: $allowRemoteImages,
      selectedText: $selectedReaderText,
      onBack: showsBackButton ? { presentation.selectedArticleID = nil } : nil,
      onRetryLoad: { selectedArticleReloadToken &+= 1 },
      onPrevious: { selectRelativeArticle(-1) },
      onNext: { selectRelativeArticle(1) },
      canNavigatePrevious: relativeArticle(offset: -1) != nil,
      canNavigateNext: relativeArticle(offset: 1) != nil,
      onOpenOriginal: openOriginal,
      onToggleStarred: toggleSelectedArticleStarred,
      onToggleRead: toggleSelectedArticleRead,
      onNavigationError: { message in workflowMessage = message },
      onBeginHighlight: { beginHighlight(withNote: false) },
      onBeginNote: { beginHighlight(withNote: true) },
      onEditTags: { tagEditorArticle = selectedArticle },
      onDeleteHighlight: { store.deleteHighlight($0) },
      onSaveToKnowledge: saveToKnowledge,
      onAddExcerptNote: { excerptNoteArticle = $0 },
      onInsertReference: insertReference,
      onCreateInspirationDraft: createInspirationDraft,
      workflowIsBusy: workflowIsBusy
    )
  }

  private var selectedArticle: RSSArticle? {
    selectedArticlePayload
  }

  private var selectedArticleLoadRequest: RSSArticleLoadRequest {
    RSSArticleLoadRequest(
      articleID: presentation.selectedArticleID,
      retryToken: selectedArticleReloadToken,
      articleRevision: selectedArticleHeader?.fetchedAt
    )
  }

  private func loadSelectedArticle(_ request: RSSArticleLoadRequest) async {
    guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
    selectedArticlePayload = nil
    selectedArticleLoadError = nil
    guard let articleID = request.articleID else {
      selectedArticleIsLoading = false
      return
    }

    selectedArticleIsLoading = true
    do {
      guard let article = try await store.loadArticle(id: articleID) else {
        guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
        selectedArticleLoadError = String(localized: "找不到这篇文章的本地正文。")
        selectedArticleIsLoading = false
        return
      }
      guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
      selectedArticlePayload = article
      selectedArticleIsLoading = false
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
      selectedArticleLoadError = error.localizedDescription
      selectedArticleIsLoading = false
    }
  }

  private var selectedArticleHeader: RSSArticleHeader? {
    presentation.articleHeader(id: presentation.selectedArticleID, in: store)
  }

  private var selectedFeedTitle: String? {
    guard let article = selectedArticleHeader else { return nil }
    return store.feeds.first { $0.id == article.feedID }?.displayTitle
  }

  private var selectedFeed: RSSFeed? {
    guard let article = selectedArticleHeader else { return nil }
    return store.feeds.first { $0.id == article.feedID }
  }

  private var readerCommandActions: RSSReaderCommandActions? {
    return RSSReaderCommandActions(
      canNavigatePrevious: relativeArticle(offset: -1) != nil,
      canNavigateNext: relativeArticle(offset: 1) != nil,
      canActOnArticle: selectedArticle != nil,
      focusSearch: {
        if usesNarrowLayout, presentation.selectedArticleID != nil {
          presentation.selectedArticleID = nil
          Task { @MainActor in
            await Task.yield()
            isSearchFocused = true
          }
        } else {
          isSearchFocused = true
        }
      },
      navigatePrevious: { selectRelativeArticle(-1) },
      navigateNext: { selectRelativeArticle(1) },
      toggleStarred: toggleSelectedArticleStarred,
      toggleRead: toggleSelectedArticleRead,
      openOriginal: openOriginal,
      createHighlight: { beginHighlight(withNote: false) },
      addNote: { beginHighlight(withNote: true) },
      editTags: { tagEditorArticle = selectedArticle }
    )
  }

  private func selectRelativeArticle(_ offset: Int) {
    guard let article = relativeArticle(offset: offset) else { return }
    presentation.revealArticle(article.id, in: store)
    presentation.selectedArticleID = article.id
  }

  private func toggleSelectedArticleStarred() {
    guard let article = selectedArticleHeader else { return }
    let nextValue = !article.isStarred
    store.toggleStarred(article.id)
    selectedArticlePayload?.isStarred = nextValue
  }

  private func toggleSelectedArticleRead() {
    guard let article = selectedArticleHeader else { return }
    let nextValue = !article.isRead
    store.markRead(article.id, isRead: nextValue)
    selectedArticlePayload?.readAt = nextValue
      ? (selectedArticlePayload?.readAt ?? Date())
      : nil
  }

  private func relativeArticle(offset: Int) -> RSSArticleHeader? {
    guard offset != 0 else { return nil }
    let matching = presentation.matchingArticles(in: store)
    guard !matching.isEmpty else { return nil }
    guard let selectedArticleID = presentation.selectedArticleID else {
      return offset > 0 ? matching.first : matching.last
    }
    if let currentIndex = matching.firstIndex(where: { $0.id == selectedArticleID }) {
      let nextIndex = currentIndex + offset
      guard matching.indices.contains(nextIndex) else { return nil }
      return matching[nextIndex]
    }
    guard let current = store.articleHeader(id: selectedArticleID) else {
      return offset > 0 ? matching.first : matching.last
    }
    let currentDate = current.publishedAt ?? current.fetchedAt
    switch (presentation.sortOrder, offset > 0) {
    case (.oldest, true):
      return matching.first { ($0.publishedAt ?? $0.fetchedAt) >= currentDate }
    case (.oldest, false):
      return matching.last { ($0.publishedAt ?? $0.fetchedAt) <= currentDate }
    case (_, true):
      return matching.first { ($0.publishedAt ?? $0.fetchedAt) <= currentDate }
    case (_, false):
      return matching.last { ($0.publishedAt ?? $0.fetchedAt) >= currentDate }
    }
  }

  private func openOriginal() {
    guard let link = selectedArticleHeader?.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      workflowMessage = message
    }
  }

  private func openOriginal(_ article: RSSArticleHeader) {
    guard let link = article.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      presentation.errorMessage = message
    }
  }

  private func beginHighlight(withNote: Bool) {
    guard let article = selectedArticle else { return }
    let text = selectedReaderText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      workflowMessage = String(localized: withNote ? "请先在正文中选取要批注的文字。" : "请先在正文中选取要高亮的文字。")
      return
    }
    highlightDraft = RSSHighlightDraft(
      articleID: article.id,
      text: text,
      initialNote: withNote ? "" : ""
    )
  }

  private func saveHighlight(_ draft: RSSHighlightDraft, note: String, tags: [String]) {
    do {
      let highlight = try store.saveHighlight(
        articleID: draft.articleID,
        text: draft.text,
        note: note,
        tags: tags,
        existingID: draft.existingID
      )
      highlightDraft = nil
      selectedReaderText = ""
      guard let article = selectedArticle, article.id == draft.articleID else { return }
      guard !highlight.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        workflowMessage = String(localized: "高亮已保存；可继续添加批注或标签。")
        return
      }
      runWorkflow(
        for: article,
        success: String(localized: "高亮和批注已保存，并已同步到资料库。")
      ) { article, knowledge in
        let document = try await Self.importArticle(article, into: knowledge)
        let citation = await knowledge.makeCitationForDocument(
          documentID: document.id,
          excerpt: highlight.text
        )
        let annotation = KnowledgeAnnotation(
          documentID: document.id,
          revisionID: document.currentRevisionID,
          chunkID: citation?.chunkID,
          locator: citation?.locator ?? "RSS 高亮",
          highlightedText: highlight.text,
          note: highlight.note
        )
        guard knowledge.saveAnnotation(annotation) else {
          throw RSSReaderError.persistence("资料库批注保存失败")
        }
        knowledge.addTags(highlight.tags, to: [document.id])
      }
    } catch {
      workflowMessage = String(localized: "高亮保存失败：\(error.localizedDescription)")
    }
  }

  private var errorAlertBinding: Binding<Bool> {
    Binding(
      get: { presentation.errorMessage != nil },
      set: { isPresented in
        if !isPresented { presentation.errorMessage = nil }
      }
    )
  }

  private func refreshSummaryText(_ summary: RSSRefreshSummary) -> String {
    if summary.skippedCount > 0 {
      return String(
        localized: "刷新完成：成功 \(summary.successCount)、失败 \(summary.failureCount)、暂缓 \(summary.skippedCount)"
      )
    }
    return String(
      localized: "刷新完成：成功 \(summary.successCount)、失败 \(summary.failureCount)"
    )
  }

  private func saveToKnowledge(_ article: RSSArticle) {
    runWorkflow(
      for: article,
      success: String(localized: "已保存到资料库；资料仅保存在本机。")
    ) { article, knowledge in
      _ = try await Self.importArticle(article, into: knowledge)
    }
  }

  private func saveExcerptNote(for article: RSSArticle, excerpt: String, note: String) {
    runWorkflow(
      for: article,
      success: String(localized: "摘录和笔记已保存到资料库。")
    ) { article, knowledge in
      let document = try await Self.importArticle(article, into: knowledge)
      let citation = await knowledge.makeCitationForDocument(
        documentID: document.id,
        excerpt: excerpt
      )
      let annotation = KnowledgeAnnotation(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        chunkID: citation?.chunkID,
        locator: citation?.locator ?? "RSS 摘录",
        highlightedText: String(excerpt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)),
        note: note.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      guard knowledge.saveAnnotation(annotation) else {
        throw RSSReaderError.persistence("资料标注保存失败")
      }
    }
  }

  private func insertReference(_ article: RSSArticle) {
    runWorkflow(
      for: article,
      success: String(localized: "已插入安全引用：只包含摘要、摘录和来源。")
    ) { article, knowledge in
      let document = try await Self.importArticle(article, into: knowledge)
      let excerpt = RSSArticleWorkflow.excerpt(for: article)
      let citation = await knowledge.makeCitationForDocument(
        documentID: document.id,
        excerpt: excerpt
      )
      guard KnowledgeArticleInsertionService.insertRSSReference(
        article: article,
        summary: RSSArticleWorkflow.summary(for: article),
        excerpt: excerpt,
        citation: citation,
        into: workbenchStore
      ) else {
        throw RSSReaderError.persistence("当前文章未能写入引用")
      }
    }
  }

  private func createInspirationDraft(_ article: RSSArticle) {
    runWorkflow(
      for: article,
      success: String(localized: "已新建灵感草稿，并插入安全引用。")
    ) { article, knowledge in
      let document = try await Self.importArticle(article, into: knowledge)
      workbenchStore.createGeneralDraft()
      if var draft = workbenchStore.selectedDraft {
        draft.title = "灵感：\(article.title)"
        workbenchStore.updateDraft(draft)
      }
      let excerpt = RSSArticleWorkflow.excerpt(for: article)
      let citation = await knowledge.makeCitationForDocument(
        documentID: document.id,
        excerpt: excerpt
      )
      guard KnowledgeArticleInsertionService.insertRSSReference(
        article: article,
        summary: RSSArticleWorkflow.summary(for: article),
        excerpt: excerpt,
        citation: citation,
        into: workbenchStore
      ) else {
        throw RSSReaderError.persistence("灵感草稿未能写入引用")
      }
    }
  }

  private func runWorkflow(
    for article: RSSArticle,
    success: String,
    operation: @escaping @MainActor (RSSArticle, KnowledgeStore) async throws -> Void
  ) {
    guard !workflowIsBusy else { return }
    workflowIsBusy = true
    workflowMessage = String(localized: "正在处理“\(article.title)”…")
    Task { @MainActor in
      defer { workflowIsBusy = false }
      do {
        try await operation(article, workbenchStore.knowledge)
        workflowMessage = success
      } catch {
        workflowMessage = String(localized: "操作失败：\(error.localizedDescription)")
      }
    }
  }

  private static func importArticle(
    _ article: RSSArticle,
    into knowledge: KnowledgeStore
  ) async throws -> KnowledgeDocument {
    guard let link = article.link else {
      throw RSSReaderError.invalidFeedURL
    }
    let preview = try await knowledge.makeWebImportPreview(url: link)
    let result = try await knowledge.commit(preview)
    guard let documentID = result.documentIDs.first,
          let document = knowledge.documents.first(where: { $0.id == documentID })
    else {
      throw RSSReaderError.persistence("资料导入完成但没有返回资料记录")
    }
    return document
  }

}

struct RSSReaderWorkspaceSidebar: View {
  @ObservedObject var store: RSSReaderStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @State private var feedPendingDeletion: RSSFeed?
  @State private var feedPendingAddressEdit: RSSFeed?

  var body: some View {
    RSSFeedSidebar(
      store: store,
      counts: presentation.sidebarCounts(in: store),
      selectedScope: $presentation.selectedScope,
      isAddSubscriptionPresented: $presentation.isAddSubscriptionPresented,
      removeFeed: { feedPendingDeletion = $0 },
      editFeedAddress: { feedPendingAddressEdit = $0 },
      importOPML: { presentation.importOPML(from: store) },
      exportOPML: { presentation.exportOPML(from: store) }
    )
    .sheet(item: $feedPendingAddressEdit) { feed in
      RSSEditFeedURLSheet(feed: feed) { newURL in
        try store.updateFeedURL(feedID: feed.id, newURL: newURL)
        Task { await store.refresh(feedID: feed.id, force: true) }
      }
    }
    .confirmationDialog(
      "删除订阅？",
      isPresented: deletionConfirmationBinding,
      titleVisibility: .visible
    ) {
      Button("删除订阅与本地缓存", role: .destructive) {
        guard let pendingFeed = feedPendingDeletion else { return }
        if case let .feed(feedID) = presentation.selectedScope, feedID == pendingFeed.id {
          presentation.selectedScope = .all
          presentation.selectedArticleID = nil
        }
        store.removeFeed(id: pendingFeed.id)
        feedPendingDeletion = nil
      }
      Button("取消", role: .cancel) {
        feedPendingDeletion = nil
      }
    } message: {
      Text(
        "将删除“\(feedPendingDeletion?.displayTitle ?? "该订阅")”及本机缓存文章（包括收藏）。删除后可在底部立即撤销。"
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-sidebar")
  }

  private var deletionConfirmationBinding: Binding<Bool> {
    Binding(
      get: { feedPendingDeletion != nil },
      set: { isPresented in
        if !isPresented { feedPendingDeletion = nil }
      }
    )
  }
}

struct RSSFeedSidebar: View {
  @ObservedObject var store: RSSReaderStore
  let counts: RSSFeedSidebarCounts
  @Binding var selectedScope: RSSArticleScope?
  @Binding var isAddSubscriptionPresented: Bool
  @State private var isAttentionSectionExpanded = false
  let removeFeed: (RSSFeed) -> Void
  let editFeedAddress: (RSSFeed) -> Void
  let importOPML: () -> Void
  let exportOPML: () -> Void

  var body: some View {
    let feedGroups = RSSFeedSidebarFeedGroups(feeds: store.feeds)

    VStack(spacing: 0) {
      WorkspaceContextListHeader(title: "订阅") {
        Text("\(store.feeds.count) 个订阅 · \(counts.unreadCount) 篇未读\n已抓取文章默认保存在本机")
      } actions: {
        Button {
          isAddSubscriptionPresented = true
        } label: {
          WorkspaceSidebarHeaderIcon("plus")
        }
        .workbenchProminentActionStyle()
        .help("添加 RSS 或 Atom 订阅")
        .accessibilityLabel("添加 RSS 或 Atom 订阅")

        Menu {
          Button {
            Task { await store.refreshAll() }
          } label: {
            Label(store.isRefreshing ? "正在刷新…" : "刷新全部", systemImage: "arrow.clockwise")
          }
          .disabled(store.isRefreshing || store.feeds.isEmpty)
          .keyboardShortcut("r", modifiers: [.command])
          Divider()
          Button("导入 OPML", action: importOPML)
          Button("导出 OPML", action: exportOPML)
            .disabled(store.feeds.isEmpty)
        } label: {
          WorkspaceSidebarHeaderIcon("ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("刷新及 OPML 管理")
        .accessibilityLabel("RSS 订阅管理")
      }
      .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
      .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)

      Divider()

      List(selection: $selectedScope) {
        Section("阅读列表") {
          scopeRow(
            title: "全部文章",
            systemImage: "tray.full",
            scope: .all,
            count: store.articleHeaders.count
          )
          scopeRow(
            title: "未读",
            systemImage: "circle",
            scope: .unread,
            count: counts.unreadCount
          )
          scopeRow(
            title: "稍后阅读",
            systemImage: "star",
            scope: .starred,
            count: counts.starredCount
          )
        }

        if !feedGroups.needsAttention.isEmpty {
          DisclosureGroup(isExpanded: $isAttentionSectionExpanded) {
            ForEach(feedGroups.needsAttention) { feed in
              feedRow(
                feed,
                unreadCount: counts.unreadCount(for: feed.id),
                showsRecoveryAction: true
              )
            }
          } label: {
            HStack(spacing: 8) {
              Label("需要处理", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkbenchTheme.risk)
              Spacer(minLength: 4)
              Text(feedGroups.needsAttention.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(WorkbenchTheme.risk)
                .accessibilityHidden(true)
            }
          }
          .accessibilityLabel("需要处理")
          .accessibilityValue(
            String(
              format: String(localized: "%lld 个订阅"),
              Int64(feedGroups.needsAttention.count)
            )
          )
        }

        Section("我的订阅") {
          if store.feeds.isEmpty {
            Text("还没有订阅")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            ForEach(feedGroups.regular) { feed in
              feedRow(
                feed,
                unreadCount: counts.unreadCount(for: feed.id),
                showsRecoveryAction: false
              )
            }
          }
        }
      }
      .listStyle(.sidebar)
      .accessibilityLabel("RSS 订阅和阅读范围")
    }
  }

  private func feedRow(
    _ feed: RSSFeed,
    unreadCount: Int,
    showsRecoveryAction: Bool
  ) -> some View {
    let isRefreshing = store.refreshingFeedIDs.contains(feed.id)
    let now = Date()
    let health = feed.healthStatus(now: now)
    let status = feedSecondaryStatus(feed, now: now)
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: health.systemImage)
            .foregroundStyle(health.tint)
            .accessibilityHidden(true)
          Text(feed.displayTitle)
            .lineLimit(2)
          Spacer(minLength: 4)
          if unreadCount > 0 {
            Text(unreadCount.formatted())
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        Text(status.text)
          .font(.workbenchMetadata)
          .foregroundStyle(status.isFailure ? WorkbenchTheme.risk : Color.secondary)
          .lineLimit(1)
          .help(status.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(feed.displayTitle)
      .accessibilityValue(
        RSSArticlePresentationSupport.feedAccessibilityValue(feed, unreadCount: unreadCount)
      )

      Menu {
        Button {
          Task { await store.refresh(feedID: feed.id, force: true) }
        } label: {
          Label(showsRecoveryAction ? "重试订阅" : "刷新此订阅", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshing)
        Button("修改订阅地址", systemImage: "pencil") {
          editFeedAddress(feed)
        }
        Button("复制订阅地址", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(feed.url.absoluteString, forType: .string)
        }
        Divider()
        Button("删除订阅", systemImage: "trash", role: .destructive) {
          removeFeed(feed)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .frame(width: 20, height: 20)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.small)
      .foregroundStyle(showsRecoveryAction ? WorkbenchTheme.risk : Color.secondary)
      .help("订阅操作")
      .accessibilityLabel("\(feed.displayTitle) 的订阅操作")
    }
    .tag(RSSArticleScope.feed(feed.id))
    .contextMenu {
      Button("刷新此订阅") {
        Task { await store.refresh(feedID: feed.id, force: true) }
      }
      .disabled(isRefreshing)
      Button("复制订阅地址") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(feed.url.absoluteString, forType: .string)
      }
      Button("修改订阅地址") {
        editFeedAddress(feed)
      }
      Divider()
      Button("删除订阅", role: .destructive) {
        removeFeed(feed)
      }
    }
  }

  private func feedSecondaryStatus(
    _ feed: RSSFeed,
    now: Date
  ) -> (text: String, isFailure: Bool) {
    if let issueMessage = feed.lastIssue?.userMessage ?? feed.lastError {
      if let retry = retryDescription(for: feed, now: now) {
        return ("\(issueMessage) · \(retry)", true)
      }
      return (issueMessage, true)
    }
    if let lastUpdatedAt = feed.lastUpdatedAt {
      return (
        "上次更新 \(lastUpdatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))",
        false
      )
    }
    return ("尚未成功刷新", false)
  }

  private func retryDescription(for feed: RSSFeed, now: Date) -> String? {
    if let issue = feed.lastIssue {
      switch issue.retryStrategy {
      case .requiresAction:
        return String(localized: "需要修改地址、证书或访问权限后再重试。")
      case .manual:
        return String(localized: "不会自动重试，可手动重试。")
      case .none:
        return nil
      case .automatic, .afterDate:
        break
      }
    }
    guard let retryAt = feed.nextRetryAt ?? feed.lastIssue?.retryAt else { return nil }
    if retryAt <= now {
      return String(localized: "已到重试时间，正在等待后台刷新。")
    }
    let exact = retryAt.formatted(date: .abbreviated, time: .shortened)
    return String(localized: "自动重试：\(exact)")
  }

  private func scopeRow(
    title: String,
    systemImage: String,
    scope: RSSArticleScope,
    count: Int
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label(title, systemImage: systemImage)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Text(count.formatted())
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(count) 篇")
    }
    .tag(scope)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue("\(count) 篇")
  }
}

struct RSSFeedSidebarFeedGroups: Equatable {
  let needsAttention: [RSSFeed]
  let regular: [RSSFeed]

  init(feeds: [RSSFeed], now: Date = Date()) {
    var needsAttention: [RSSFeed] = []
    var regular: [RSSFeed] = []
    for feed in feeds {
      if RSSArticlePresentationSupport.feedNeedsAttention(feed, now: now) {
        needsAttention.append(feed)
      } else {
        regular.append(feed)
      }
    }
    self.needsAttention = needsAttention
    self.regular = regular
  }
}

struct RSSFeedSidebarCounts: Equatable {
  let unreadCount: Int
  let starredCount: Int
  private let unreadCountByFeedID: [UUID: Int]

  init(articles: [RSSArticleHeader]) {
    var unreadCount = 0
    var starredCount = 0
    var unreadCountByFeedID: [UUID: Int] = [:]

    for article in articles {
      if article.isStarred {
        starredCount += 1
      }
      if !article.isRead {
        unreadCount += 1
        unreadCountByFeedID[article.feedID, default: 0] += 1
      }
    }

    self.unreadCount = unreadCount
    self.starredCount = starredCount
    self.unreadCountByFeedID = unreadCountByFeedID
  }

  func unreadCount(for feedID: UUID) -> Int {
    unreadCountByFeedID[feedID, default: 0]
  }
}

struct RSSFeedLookup {
  private let feedsByID: [UUID: RSSFeed]

  init(feeds: [RSSFeed]) {
    feedsByID = Dictionary(
      feeds.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
  }

  subscript(feedID: UUID) -> RSSFeed? {
    feedsByID[feedID]
  }
}

private extension RSSFeedHealthStatus {
  var systemImage: String {
    switch self {
    case .never: return "circle.dashed"
    case .healthy: return "checkmark.circle.fill"
    case .failing: return "exclamationmark.triangle.fill"
    case .backingOff: return "clock.arrow.circlepath"
    }
  }

  var tint: Color {
    switch self {
    case .never: return .secondary
    case .healthy: return WorkbenchTheme.success
    case .failing: return WorkbenchTheme.risk
    case .backingOff: return WorkbenchTheme.warning
    }
  }
}

private struct RSSArticleList: View {
  @ObservedObject var store: RSSReaderStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @ObservedObject var searchDraft: RSSArticleSearchDraft
  @Binding var selectedArticleID: String?
  @FocusState.Binding var isSearchFocused: Bool
  @State private var feedPendingAddressEdit: RSSFeed?

  var body: some View {
    let matchingArticles = presentation.matchingArticles(in: store)
    let visibleArticles = presentation.visibleArticles(in: store)
    let scopedArticles = presentation.scopedArticles(in: store)
    let unreadMatchingArticleIDs = presentation.unreadMatchingArticleIDs(in: store)
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
          Button {
            store.markAllRead(articleIDs: unreadMatchingArticleIDs)
          } label: {
            Label(
              unreadMatchingArticleIDs.isEmpty
                ? String(localized: "已全部阅读")
                : String(localized: "全部已读（\(unreadMatchingArticleIDs.count)）"),
              systemImage: "checkmark.circle"
            )
          }
          .buttonStyle(.borderless)
          .disabled(unreadMatchingArticleIDs.isEmpty)
          .help("将当前列表中的文章标为已读")
          .accessibilityLabel("将当前筛选结果中的 \(unreadMatchingArticleIDs.count) 篇未读文章标为已读")
        }

        TextField("搜索文章标题或正文", text: $searchDraft.text)
          .textFieldStyle(.roundedBorder)
          .focused($isSearchFocused)
          .accessibilityLabel("搜索 RSS 文章标题或正文")

        HStack(spacing: 10) {
          Toggle("只看未读", isOn: $presentation.unreadOnly)
            .toggleStyle(.checkbox)
            .accessibilityLabel("只显示未读 RSS 文章")

          Menu {
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
            Picker("日期", selection: $presentation.dateRange) {
              ForEach(RSSArticleDateRange.allCases) { range in
                Text(range.title).tag(range)
              }
            }
            Divider()
            Button("清除筛选", action: clearFilters)
              .disabled(!hasActiveFilters)
          } label: {
            Label(
              activeFilterCount == 0
                ? String(localized: "筛选")
                : String(localized: "筛选（\(activeFilterCount)）"),
              systemImage: "line.3.horizontal.decrease.circle"
            )
          }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("筛选 RSS 文章，当前启用 \(activeFilterCount) 项")

          Menu {
            Picker("排序", selection: $presentation.sortOrder) {
              ForEach(RSSArticleSortOrder.allCases) { order in
                Text(order.title).tag(order)
              }
            }
            Toggle("按日期分组", isOn: $presentation.groupsByDate)
          } label: {
            Label(presentation.sortOrder.title, systemImage: "arrow.up.arrow.down")
          }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("文章排序：\(presentation.sortOrder.title)")

          if searchDraft.text != presentation.debouncedSearchText {
            ProgressView()
              .controlSize(.mini)
              .help("正在搜索")
              .accessibilityLabel("正在搜索 RSS 文章")
          }
          Spacer(minLength: 0)
        }
      }
      .padding(WorkbenchSpacing.section)

      Divider()

      if let contentPresentation = listContentPresentation(for: currentListState) {
        articleList(
          visibleArticles,
          matchingCount: matchingArticles.count,
          feedLookup: feedLookup,
          showsRefreshBanner: contentPresentation.showsRefreshBanner,
          staleFailure: contentPresentation.staleFailure
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
    .task(id: searchDraft.text) {
      if !searchDraft.text.isEmpty {
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      guard !Task.isCancelled else { return }
      presentation.debouncedSearchText = searchDraft.text
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
  ) -> (
    showsRefreshBanner: Bool,
    staleFailure: (title: String, message: String)?
  )? {
    switch state {
    case .content:
      return (false, nil)
    case .refreshing:
      return (true, nil)
    case let .staleContent(_, feedTitle, message):
      return (false, (feedTitle, message))
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

  private func openOriginal(_ article: RSSArticleHeader) {
    guard let link = article.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      presentation.errorMessage = message
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
    case .starred: "在文章行上点击星标，可以收集到这里。"
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
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  private func articleList(
    _ articles: [RSSArticleHeader],
    matchingCount: Int,
    feedLookup: RSSFeedLookup,
    showsRefreshBanner: Bool,
    staleFailure: (title: String, message: String)?
  ) -> some View {
    VStack(spacing: 0) {
      if showsRefreshBanner {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("正在刷新，先显示 \(articles.count) / \(matchingCount) 篇本机文章。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        Divider()
      }
      if let staleFailure {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(WorkbenchTheme.risk)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("“\(staleFailure.title)”刷新失败，正在显示 \(articles.count) / \(matchingCount) 篇本机文章。")
              .font(.callout.weight(.semibold))
            Text(staleFailure.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Button("重试") { retrySelectedScope() }
            .buttonStyle(.borderless)
            .disabled(scopeIsRefreshing)
          if let selectedFeed {
            Button("修改地址") { feedPendingAddressEdit = selectedFeed }
              .buttonStyle(.borderless)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        Divider()
      }

      if articles.isEmpty {
        filteredEmptyState
      } else {
        List(selection: $selectedArticleID) {
          ForEach(
            RSSArticlePresentationSupport.sections(
              for: articles,
              groupsByDate: presentation.groupsByDate,
              sortOrder: presentation.sortOrder
            )
          ) { section in
            if let title = section.title {
              Section(title) {
                ForEach(section.articles) { article in
                  articleRow(article, feed: feedLookup[article.feedID])
                }
              }
            } else {
              ForEach(section.articles) { article in
                articleRow(article, feed: feedLookup[article.feedID])
              }
            }
          }

          if articles.count < matchingCount {
            Section {
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
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                "继续显示本机文章，当前 \(articles.count) 篇，共 \(matchingCount) 篇"
              )
            }
          }
        }
        .listStyle(.inset)
        .accessibilityLabel("RSS 文章列表")
      }
    }
  }

  private func articleRow(_ article: RSSArticleHeader, feed: RSSFeed?) -> some View {
    RSSArticleRow(
      article: article,
      feed: feed,
      summary: article.readableSummary,
      onToggleRead: { store.markRead(article.id, isRead: !article.isRead) },
      onToggleStarred: { store.toggleStarred(article.id) },
      onOpenOriginal: { openOriginal(article) }
    )
    .tag(article.id)
    .contextMenu {
      Button(article.isRead ? "标为未读" : "标为已读") {
        store.markRead(article.id, isRead: !article.isRead)
      }
      Button(article.isStarred ? "取消收藏" : "收藏") {
        store.toggleStarred(article.id)
      }
      if article.link != nil {
        Divider()
        Button("打开原文") { openOriginal(article) }
      }
    }
  }
}

private struct RSSArticleRow: View {
  let article: RSSArticleHeader
  let feed: RSSFeed?
  let summary: String
  let onToggleRead: () -> Void
  let onToggleStarred: () -> Void
  let onOpenOriginal: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(article.isRead ? Color.clear : Color.accentColor)
        .frame(width: 7, height: 7)
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
          Text((article.publishedAt ?? article.fetchedAt).formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
          if article.isStarred {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .accessibilityHidden(true)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if !summary.isEmpty {
          Text(summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: false)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(article.title)
      .accessibilityValue(accessibilityValue)

      Menu {
        Button(
          article.isStarred ? "取消收藏" : "收藏",
          systemImage: article.isStarred ? "star.slash" : "star",
          action: onToggleStarred
        )
        Button(
          article.isRead ? "标为未读" : "标为已读",
          systemImage: article.isRead ? "circle" : "checkmark.circle",
          action: onToggleRead
        )
        if article.link != nil {
          Divider()
          Button("打开原文", systemImage: "safari", action: onOpenOriginal)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .frame(width: 22, height: 22)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.small)
      .foregroundStyle(.secondary)
      .opacity(isHovering ? 1 : 0.45)
      .help("文章操作")
      .accessibilityLabel("文章操作：\(article.title)")
    }
    .padding(.vertical, 5)
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .contain)
  }

  private var accessibilityValue: String {
    var components = [
      feed?.displayTitle ?? "RSS",
      (article.publishedAt ?? article.fetchedAt).formatted(
        .relative(presentation: .named, unitsStyle: .abbreviated)
      ),
      article.isRead ? String(localized: "已读") : String(localized: "未读"),
    ]
    if let author = article.author?.trimmedForPublishing.nilIfEmpty {
      components.append(String(localized: "作者 \(author)"))
    }
    if article.isStarred { components.append(String(localized: "已收藏")) }
    if !article.tags.isEmpty {
      components.append(String(localized: "标签 \(article.tags.joined(separator: "、"))"))
    }
    return components.joined(separator: "，")
  }

}

private struct RSSArticleReader: View {
  let articleHeader: RSSArticleHeader?
  let article: RSSArticle?
  let isLoading: Bool
  let loadError: String?
  let feedTitle: String?
  let feedIconURL: URL?
  let highlights: [RSSArticleHighlight]
  let mediaAssets: [RSSMediaAsset]
  let mediaCacheDirectoryURL: URL
  let hasReadableText: Bool
  let readingMinutes: Int
  @Binding var allowRemoteImages: Bool
  @Binding var selectedText: String
  let onBack: (() -> Void)?
  let onRetryLoad: () -> Void
  let onPrevious: () -> Void
  let onNext: () -> Void
  let canNavigatePrevious: Bool
  let canNavigateNext: Bool
  let onOpenOriginal: () -> Void
  let onToggleStarred: () -> Void
  let onToggleRead: () -> Void
  let onNavigationError: (String) -> Void
  let onBeginHighlight: () -> Void
  let onBeginNote: () -> Void
  let onEditTags: () -> Void
  let onDeleteHighlight: (UUID) -> Void
  let onSaveToKnowledge: (RSSArticle) -> Void
  let onAddExcerptNote: (RSSArticle) -> Void
  let onInsertReference: (RSSArticle) -> Void
  let onCreateInspirationDraft: (RSSArticle) -> Void
  let workflowIsBusy: Bool

  var body: some View {
    Group {
      if let article {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if let onBack {
              Button("返回文章列表", systemImage: "chevron.left", action: onBack)
                .buttonStyle(.borderless)
                .accessibilityLabel("返回 RSS 文章列表")
            }

            Text(article.title)
              .font(.workbenchPageTitle)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)

            articleMetadata(for: article)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            navigationControls(for: article)

            articleActions(for: article)

            RSSArticleWorkflowActions(
              article: article,
              onSaveToKnowledge: onSaveToKnowledge,
              onAddExcerptNote: onAddExcerptNote,
              onInsertReference: onInsertReference,
              onCreateInspirationDraft: onCreateInspirationDraft,
              isBusy: workflowIsBusy
            )

            Divider()

            if !hasReadableText {
              Text("这篇文章没有可显示的正文，建议打开原文阅读。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
              RSSArticleWebView(
                article: article,
                allowRemoteImages: allowRemoteImages,
                highlights: highlights,
                mediaAssets: mediaAssets,
                mediaCacheDirectoryURL: mediaCacheDirectoryURL,
                onSelectionChanged: { selectedText = $0 },
                onNavigationError: { message in
                  selectedText = ""
                  onNavigationError(message)
                }
              )
              .frame(minHeight: 560)
              .accessibilityLabel("保留标题、列表、引用、代码块和链接的文章正文")
            }

            if !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              selectionPalette
            }

            articleTagSummary(for: article)

            if !highlights.isEmpty {
              highlightList
            }
          }
          .padding(WorkbenchSpacing.spacious)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RSS 文章阅读区域")
      } else if let articleHeader {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if let onBack {
              Button("返回文章列表", systemImage: "chevron.left", action: onBack)
                .buttonStyle(.borderless)
            }
            Text(articleHeader.title)
              .font(.workbenchPageTitle)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              feedIcon
              Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
              if let date = articleHeader.publishedAt {
                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
              }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Divider()
            if isLoading {
              ProgressView("正在读取本机正文…")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text(loadError ?? "暂时无法读取这篇文章的本机正文。")
                .foregroundStyle(WorkbenchTheme.risk)
              HStack(spacing: 8) {
                Button("重试读取", systemImage: "arrow.clockwise", action: onRetryLoad)
                  .buttonStyle(.borderedProminent)
                if articleHeader.link != nil {
                  Button("打开原文", systemImage: "safari", action: onOpenOriginal)
                    .buttonStyle(.bordered)
                }
                Button("上一篇", systemImage: "chevron.left", action: onPrevious)
                  .buttonStyle(.bordered)
                  .disabled(!canNavigatePrevious)
                Button("下一篇", systemImage: "chevron.right", action: onNext)
                  .buttonStyle(.bordered)
                  .disabled(!canNavigateNext)
              }
            }
          }
          .padding(WorkbenchSpacing.spacious)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RSS 文章正文正在读取")
      } else {
        RSSReaderEmptyState(
          title: "选择一篇文章",
          message: "从左侧文章列表选择内容，正文会在这里完整显示。",
          systemImage: "text.book.closed"
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-detail")
  }

  @ViewBuilder
  private var feedIcon: some View {
    if let feedIconURL {
      AsyncImage(url: feedIconURL) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          Image(systemName: "dot.radiowaves.left.and.right")
        }
      }
      .frame(width: 20, height: 20)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .accessibilityLabel("来源图标")
    }
  }

  @ViewBuilder
  private func articleMetadata(for article: RSSArticle) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        feedIcon
        Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
        if let author = article.author?.trimmedForPublishing.nilIfEmpty {
          Label(author, systemImage: "person")
        }
        if let date = article.publishedAt {
          Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
        }
        Label("约 \(readingMinutes) 分钟", systemImage: "clock")
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          feedIcon
          Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
          if let author = article.author?.trimmedForPublishing.nilIfEmpty {
            Label(author, systemImage: "person")
          }
        }
        HStack(spacing: 8) {
          if let date = article.publishedAt {
            Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
          }
          Label("约 \(readingMinutes) 分钟", systemImage: "clock")
        }
      }
    }
  }

  @ViewBuilder
  private func navigationControls(for article: RSSArticle) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Spacer(minLength: 0)
        previousButton
        nextButton
        starredButton(for: article)
        readButton(for: article)
      }
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 8) {
          previousButton
          nextButton
        }
        HStack(spacing: 8) {
          starredButton(for: article)
          readButton(for: article)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var previousButton: some View {
    Button("上一篇", systemImage: "chevron.left", action: onPrevious)
      .buttonStyle(.bordered)
      .disabled(!canNavigatePrevious)
      .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
      .accessibilityLabel("阅读上一篇文章")
  }

  private var nextButton: some View {
    Button("下一篇", systemImage: "chevron.right", action: onNext)
      .buttonStyle(.bordered)
      .disabled(!canNavigateNext)
      .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
      .accessibilityLabel("阅读下一篇文章")
  }

  private func starredButton(for article: RSSArticle) -> some View {
    Button(action: onToggleStarred) {
      Label(
        article.isStarred ? "取消收藏" : "收藏",
        systemImage: article.isStarred ? "star.fill" : "star"
      )
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("s", modifiers: [.command, .control])
    .accessibilityLabel(article.isStarred ? "取消收藏文章" : "收藏文章")
  }

  private func readButton(for article: RSSArticle) -> some View {
    Button(action: onToggleRead) {
      Label(
        article.isRead ? "标为未读" : "标为已读",
        systemImage: article.isRead ? "circle" : "checkmark.circle"
      )
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("u", modifiers: [.command, .control])
    .accessibilityLabel(article.isRead ? "将文章标为未读" : "将文章标为已读")
  }

  @ViewBuilder
  private func articleActions(for article: RSSArticle) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        originalArticleButton(for: article)
        remoteImageToggle
        remoteImageStatus
      }
      VStack(alignment: .leading, spacing: 8) {
        originalArticleButton(for: article)
        remoteImageToggle
        remoteImageStatus
      }
    }
  }

  @ViewBuilder
  private func originalArticleButton(for article: RSSArticle) -> some View {
    if let link = article.link {
      Button("打开原文", systemImage: "safari", action: onOpenOriginal)
        .buttonStyle(.bordered)
        .keyboardShortcut("o", modifiers: [.command, .control])
        .accessibilityLabel("在浏览器中打开原文")
        .help(link.absoluteString)
    }
  }

  private var remoteImageToggle: some View {
    Toggle("加载远程图片", isOn: $allowRemoteImages)
      .toggleStyle(.checkbox)
      .accessibilityLabel("允许加载当前文章的远程图片")
  }

  private var remoteImageStatus: some View {
    Text(allowRemoteImages ? "已允许当前文章加载远程图片" : "远程图片默认关闭")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var selectionPalette: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("已选文本", systemImage: "text.quote")
        .font(.headline)
      Text(selectedText)
        .lineLimit(3)
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("高亮", systemImage: "highlighter", action: onBeginHighlight)
          .workbenchProminentActionStyle()
          .keyboardShortcut("h", modifiers: [.command, .control])
        Button("添加批注", systemImage: "note.text.badge.plus", action: onBeginNote)
          .buttonStyle(.bordered)
          .keyboardShortcut("n", modifiers: [.command, .control])
      }
    }
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchBackgroundStyle.subtle,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("已选择正文文字，可高亮或添加批注")
  }

  private func articleTagSummary(for article: RSSArticle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("文章标签", systemImage: "tag")
          .font(.headline)
        Spacer()
        Button("编辑标签", action: onEditTags)
          .buttonStyle(.bordered)
          .keyboardShortcut("t", modifiers: [.command, .control])
      }
      if article.tags.isEmpty {
        Text("还没有标签")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(article.tags.map { "#\($0)" }.joined(separator: "  "))
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var highlightList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("本篇高亮与批注", systemImage: "highlighter")
        .font(.headline)
      ForEach(highlights) { highlight in
        VStack(alignment: .leading, spacing: 5) {
          Text(highlight.text)
            .font(.callout.weight(.medium))
            .lineLimit(4)
          if !highlight.note.isEmpty {
            Text(highlight.note)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          if !highlight.tags.isEmpty {
            Text(highlight.tags.map { "#\($0)" }.joined(separator: "  "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          HStack {
            Spacer()
            Button("删除高亮") {
              onDeleteHighlight(highlight.id)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(WorkbenchTheme.risk)
            .accessibilityLabel("删除高亮：\(highlight.text)")
          }
        }
        .padding(WorkbenchSpacing.control)
        .background(
          WorkbenchBackgroundStyle.subtle,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
      }
    }
  }
}

private struct RSSArticleWorkflowActions: View {
  let article: RSSArticle
  let onSaveToKnowledge: (RSSArticle) -> Void
  let onAddExcerptNote: (RSSArticle) -> Void
  let onInsertReference: (RSSArticle) -> Void
  let onCreateInspirationDraft: (RSSArticle) -> Void
  let isBusy: Bool

  var body: some View {
    HStack(alignment: .center, spacing: WorkbenchSpacing.card) {
      VStack(alignment: .leading, spacing: 3) {
        Label("资料与写作", systemImage: "books.vertical")
          .font(.workbenchSectionTitle)
        Text("保存时只写入摘要、摘录和来源。")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: WorkbenchSpacing.control)
      if isBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在处理阅读内容")
      }
      Menu {
        actionButton("保存到资料库", systemImage: "books.vertical", action: onSaveToKnowledge)
        actionButton("摘录并添加笔记", systemImage: "note.text.badge.plus", action: onAddExcerptNote)
        Divider()
        actionButton("插入当前文章", systemImage: "arrow.down.doc", action: onInsertReference)
        actionButton("新建灵感草稿", systemImage: "square.and.pencil", action: onCreateInspirationDraft)
      } label: {
        Label("文章用途", systemImage: "ellipsis.circle")
      }
      .menuStyle(.button)
      .disabled(isBusy)
      .accessibilityLabel("将当前文章用于资料与写作")
    }
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchBackgroundStyle.subtle,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    action: @escaping (RSSArticle) -> Void
  ) -> some View {
    Button {
      action(article)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .disabled(isBusy)
    .accessibilityLabel(title)
  }
}

private struct RSSHighlightEditorSheet: View {
  let text: String
  let initialNote: String
  let initialTags: [String]
  let onSave: (String, [String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var note: String
  @State private var tagsText: String

  init(
    text: String,
    initialNote: String = "",
    initialTags: [String] = [],
    onSave: @escaping (String, [String]) -> Void
  ) {
    self.text = text
    self.initialNote = initialNote
    self.initialTags = initialTags
    self.onSave = onSave
    _note = State(initialValue: initialNote)
    _tagsText = State(initialValue: initialTags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("保存高亮与批注", systemImage: "highlighter")
          .font(.headline)
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
      }

      Text("高亮文字")
        .font(.subheadline.weight(.semibold))
      ScrollView {
        Text(text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(minHeight: 70, maxHeight: 150)
      .padding(10)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

      Text("批注（可选）")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $note)
        .font(.body)
        .frame(minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityLabel("高亮批注")

      TextField("标签，用逗号分隔（可选）", text: $tagsText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("高亮标签")

      HStack {
        Text("内容保存在本机；有批注时会同步到资料库。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("保存", action: save)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear {
      // Keep the editor fully keyboard reachable without stealing focus from
      // the selected text or the user's current navigation context.
    }
  }

  private func save() {
    let tags = tagsText
      .split { $0 == "," || $0 == "，" || $0 == "、" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    onSave(note.trimmingCharacters(in: .whitespacesAndNewlines), tags)
  }
}

private struct RSSArticleTagsSheet: View {
  let article: RSSArticle
  let onSave: ([String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var tagsText: String

  init(article: RSSArticle, onSave: @escaping ([String]) -> Void) {
    self.article = article
    self.onSave = onSave
    _tagsText = State(initialValue: article.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("编辑文章标签", systemImage: "tag")
          .font(.headline)
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
      }
      Text(article.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      TextField("标签，用逗号分隔", text: $tagsText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("文章标签")
      HStack {
        Text("标签用于后续检索与资料整理。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("保存") {
          onSave(
            tagsText
              .split { $0 == "," || $0 == "，" || $0 == "、" }
              .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .filter { !$0.isEmpty }
          )
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 430)
  }
}

private struct RSSReaderEmptyState: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let systemImage: String

  var body: some View {
    EmptyStateView(
      title: title,
      message: message,
      systemImage: systemImage,
      density: .fullPage
    )
  }
}

private struct RSSReaderWelcomeView: View {
  let onAdd: () -> Void
  let onImportOPML: () -> Void
  let onDiscover: (String) -> Void
  @State private var homepageURL = ""

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "dot.radiowaves.left.and.right")
        .font(.system(size: 42))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("开始阅读")
        .font(.largeTitle.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text("把阅读、资料和写作连接起来。订阅内容只保存在本机，不会因为阅读而上传到第三方服务。")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)

      HStack(spacing: 10) {
        Button("添加第一个订阅", action: onAdd)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
        Button("导入 OPML", action: onImportOPML)
          .buttonStyle(.bordered)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("也可以粘贴博客首页，自动发现 RSS / Atom")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          TextField("https://example.com", text: $homepageURL)
            .textFieldStyle(.roundedBorder)
            .textContentType(.URL)
            .onSubmit(submitDiscovery)
            .accessibilityLabel("博客首页或 RSS 地址")
          Button("发现并订阅", action: submitDiscovery)
            .buttonStyle(.bordered)
            .disabled(homepageURL.trimmedForPublishing.isEmpty)
        }
      }
      .frame(maxWidth: 560)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-welcome")
  }

  private func submitDiscovery() {
    let value = homepageURL.trimmedForPublishing
    guard !value.isEmpty else { return }
    onDiscover(value)
  }
}

private struct RSSEditFeedURLSheet: View {
  @Environment(\.dismiss) private var dismiss
  let feed: RSSFeed
  let onSave: (URL) throws -> Void
  @State private var value: String
  @State private var errorMessage: String?

  init(feed: RSSFeed, onSave: @escaping (URL) throws -> Void) {
    self.feed = feed
    self.onSave = onSave
    _value = State(initialValue: feed.url.absoluteString)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("修改订阅地址")
        .font(.title2.weight(.semibold))
      Text(feed.displayTitle)
        .font(.headline)
        .lineLimit(2)
      Text("修改后会保留这个订阅的本地文章、已读状态、收藏、标签和高亮，然后使用新地址重新刷新。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextField("https://example.com/feed.xml", text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(.URL)
        .accessibilityLabel("新的 RSS 或 Atom 订阅地址")
        .onSubmit(save)

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.risk)
          .textSelection(.enabled)
          .accessibilityLabel("地址修改失败：\(errorMessage)")
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存并重试", action: save)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(value.trimmedForPublishing.isEmpty)
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 520)
  }

  private func save() {
    let normalized = value.trimmedForPublishing
    guard let url = URL(string: normalized) else {
      errorMessage = RSSReaderError.invalidFeedURL.localizedDescription
      return
    }
    do {
      try onSave(url)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct RSSExcerptNoteSheet: View {
  @Environment(\.dismiss) private var dismiss
  let article: RSSArticle
  let onSave: (String, String) -> Void
  @State private var excerpt: String
  @State private var note = ""

  init(article: RSSArticle, onSave: @escaping (String, String) -> Void) {
    self.article = article
    self.onSave = onSave
    _excerpt = State(initialValue: RSSArticleWorkflow.excerpt(for: article))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("摘录并添加笔记")
        .font(.title2.weight(.semibold))
      Text(article.title)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
      Text("摘录会限制在安全长度内保存；你可以删减后再添加自己的笔记。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("摘录")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $excerpt)
        .font(.body)
        .frame(minHeight: 150)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .accessibilityLabel("要保存的文章摘录")
      Text("笔记")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $note)
        .font(.body)
        .frame(minHeight: 100)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .accessibilityLabel("关于这段摘录的笔记")

      HStack {
        Spacer()
        Button("取消", action: dismiss.callAsFunction)
          .keyboardShortcut(.cancelAction)
        Button("保存摘录和笔记") {
          onSave(excerpt, note)
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(
          excerpt.trimmedForPublishing.isEmpty || note.trimmedForPublishing.isEmpty
        )
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 560, minHeight: 520)
  }
}

private struct RSSAddSubscriptionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var value = ""
  let onAdd: (String) -> Void
  let onImportOPML: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加 RSS 订阅")
        .font(.title2.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text("输入 RSS / Atom 地址，或粘贴博客首页自动发现。文章会缓存到本机，默认不会上传到第三方服务。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextField("https://example.com/feed.xml", text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(.URL)
        .accessibilityLabel("RSS 或 Atom 订阅地址")
        .onSubmit {
          submit()
        }

      HStack {
        Button("导入 OPML") {
          dismiss()
          onImportOPML()
        }
        .buttonStyle(.bordered)
        Spacer()
        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("添加并读取") {
          submit()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(value.trimmedForPublishing.isEmpty)
        .accessibilityLabel("添加订阅并读取最新文章")
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 500)
  }

  private func submit() {
    guard !value.trimmedForPublishing.isEmpty else { return }
    onAdd(value)
  }
}
