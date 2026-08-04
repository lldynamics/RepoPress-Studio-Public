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
    let hasRenderableBody: Bool
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
  @Published var subscriptionDiscovery: RSSSubscriptionDiscovery?
  @Published private(set) var isDiscoveringSubscription = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published private(set) var articleDisplayLimit = 120
  fileprivate let searchDraft = RSSArticleSearchDraft()

  private var subscriptionDiscoveryRequestID = UUID()

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

  func readerMetrics(for article: RSSArticle) -> (hasRenderableBody: Bool, readingMinutes: Int) {
    if let cached = readerMetricsCache[article.id],
       cached.fetchedAt == article.fetchedAt {
      touchReaderMetrics(article.id)
      return (cached.hasRenderableBody, cached.readingMinutes)
    }
    let bodyMetrics = RSSArticleHTMLRenderer.bodyMetrics(article: article)
    let metrics = ReaderMetricsCacheEntry(
      fetchedAt: article.fetchedAt,
      hasRenderableBody: bodyMetrics.hasRenderableBody,
      readingMinutes: max(1, Int(ceil(Double(bodyMetrics.readingUnits) / 220.0)))
    )
    readerMetricsCache[article.id] = metrics
    touchReaderMetrics(article.id)
    if readerMetricsLRU.count > 100 {
      let evictedID = readerMetricsLRU.removeFirst()
      readerMetricsCache.removeValue(forKey: evictedID)
    }
    return (metrics.hasRenderableBody, metrics.readingMinutes)
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
    errorMessage = nil
    isAddSubscriptionPresented = false
    isDiscoveringSubscription = true
    statusMessage = String(localized: "正在发现 RSS / Atom 订阅…")
    let requestID = UUID()
    subscriptionDiscoveryRequestID = requestID
    Task { @MainActor [weak self] in
      guard let self else { return }
      let discovered = (try? await RSSFeedDiscoveryService(
        allowsPrivateNetworkAccess: store.privateNetworkAccessEnabled
      ).discover(from: url)) ?? []
      guard self.subscriptionDiscoveryRequestID == requestID else { return }
      self.isDiscoveringSubscription = false
      if discovered.count > 1 {
        self.subscriptionDiscovery = RSSSubscriptionDiscovery(
          sourceURL: url,
          feedURLs: discovered
        )
        return
      }
      do {
        try await addFeedURLs(discovered.isEmpty ? [url] : discovered, to: store)
      } catch {
        statusMessage = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func addDiscoveredSubscriptions(_ feedURLs: [URL], to store: RSSReaderStore) {
    guard !feedURLs.isEmpty else {
      cancelSubscriptionDiscovery()
      return
    }
    subscriptionDiscovery = nil
    isDiscoveringSubscription = false
    subscriptionDiscoveryRequestID = UUID()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await addFeedURLs(feedURLs, to: store)
      } catch {
        statusMessage = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func cancelSubscriptionDiscovery() {
    subscriptionDiscovery = nil
    isDiscoveringSubscription = false
    subscriptionDiscoveryRequestID = UUID()
    statusMessage = nil
  }

  private func addFeedURLs(_ feedURLs: [URL], to store: RSSReaderStore) async throws {
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

private struct RSSArticleTranslationCacheKey: Hashable {
  let articleID: String
  let fetchedAt: Date
  let targetCode: String
}

private struct RSSReaderFilterChangeToken: Equatable {
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

private struct RSSStatusEvent: Equatable {
  let title: String
  let details: [String]
  let isError: Bool
}

struct RSSReaderView: View {
  @ObservedObject var store: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @Environment(\.openSettings) private var openSettings
  @State private var excerptNoteArticle: RSSArticle?
  @State private var highlightDraft: RSSHighlightDraft?
  @State private var tagEditorArticle: RSSArticle?
  @State private var selectedReaderText = ""
  @State private var allowRemoteImages = false
  @State private var workflowMessage: String?
  @State private var workflowIsBusy = false
  @State private var isReaderCompact = false
  @State private var isStatusDetailsExpanded = false
  @State private var selectedArticlePayload: RSSArticle?
  @State private var selectedArticleLoadError: String?
  @State private var selectedArticleIsLoading = false
  @State private var selectedArticleReloadToken = 0
  @State private var translationCache: [RSSArticleTranslationCacheKey: RSSArticleTranslationResult] = [:]
  @State private var translationIsRunning = false
  @State private var translationError: String?
  @State private var translationRequestID = UUID()
  @State private var readingProgressByArticle = RSSReadingProgressStore.load()
  @State private var readingProgressOrder = RSSReadingProgressStore.loadOrder()
  @State private var readingProgressSaveTask: Task<Void, Never>?
  @AppStorage("rssReaderFontSize") private var readingFontSize = RSSReadingComfortConfiguration.defaultFontSize
  @AppStorage("rssReaderLineSpacing") private var readingLineSpacing = RSSReadingComfortConfiguration.defaultLineSpacing
  @AppStorage("rssReaderTheme") private var readingThemeRawValue = RSSReadingTheme.system.rawValue
  @AppStorage("rssReaderTranslationTargetCode") private var translationTargetCode = RSSArticleTranslationTarget.simplifiedChinese.languageCode
  @AppStorage("rssReaderTranslationCustomLanguage") private var translationCustomLanguage = ""
  @AppStorage("rssReaderAutomaticTranslationEnabled") private var automaticTranslationEnabled = false
  @AppStorage("settingsRequestedTabID") private var requestedSettingsTabID = ""
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    let loadRequest = selectedArticleLoadRequest
    VStack(spacing: 0) {
      readerSplitView
      statusBar
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-workspace")
    .focusedSceneValue(\.rssReaderCommandActions, readerCommandActions)
    .onAppear {
      presentation.synchronizeSelection(in: store)
    }
    .onDisappear {
      persistReadingProgressImmediately()
    }
    .onChange(of: presentation.selectedArticleID) { _, _ in
      selectedReaderText = ""
      allowRemoteImages = false
      selectedArticlePayload = nil
      selectedArticleLoadError = nil
      selectedArticleIsLoading = false
      translationRequestID = UUID()
      translationIsRunning = false
      translationError = nil
    }
    .onChange(of: translationTargetCode) { _, _ in
      translationRequestID = UUID()
      translationIsRunning = false
      translationError = nil
      if automaticTranslationEnabled, let article = selectedArticle {
        requestTranslation(for: article, force: false)
      }
    }
    .onChange(of: automaticTranslationEnabled) { _, isEnabled in
      guard isEnabled, let article = selectedArticle else { return }
      requestTranslation(for: article, force: false)
    }
    .task(id: loadRequest) {
      await loadSelectedArticle(loadRequest)
    }
    .onChange(of: filterChangeToken) { oldValue, newValue in
      let filterChanged = oldValue.filterOnly != newValue.filterOnly
      handleFilterChange(
        preservingArticle: oldValue.scope == newValue.scope,
        resetsDisplayLimit: filterChanged,
        resetsTransientState: filterChanged
      )
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
    .sheet(
      item: $presentation.subscriptionDiscovery,
      onDismiss: { presentation.cancelSubscriptionDiscovery() }
    ) { discovery in
      RSSSubscriptionDiscoveryView(
        discovery: discovery,
        onCancel: { presentation.cancelSubscriptionDiscovery() },
        onAdd: { feedURLs in
          presentation.addDiscoveredSubscriptions(feedURLs, to: store)
        }
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

  private var filterChangeToken: RSSReaderFilterChangeToken {
    RSSReaderFilterChangeToken(
      scope: presentation.selectedScope,
      searchText: presentation.debouncedSearchText,
      unreadOnly: presentation.unreadOnly,
      sourceID: presentation.selectedSourceID,
      author: presentation.selectedAuthor,
      tag: presentation.selectedTag,
      dateRange: presentation.dateRange.rawValue,
      sortOrder: presentation.sortOrder.rawValue,
      mutationRevision: store.mutationRevision
    )
  }

  private var latestStatusEvent: RSSStatusEvent? {
    if let lastError = store.lastError {
      let lines = lastError.split(whereSeparator: \.isNewline).map(String.init)
      var details = Array(lines.dropFirst())
      details.append(contentsOf: [
        store.statusMessage,
        workflowMessage,
        presentation.statusMessage
      ].compactMap { $0 }.filter { $0 != (lines.first ?? "") })
      var uniqueDetails: [String] = []
      for detail in details where !detail.isEmpty && !uniqueDetails.contains(detail) {
        uniqueDetails.append(detail)
      }
      return RSSStatusEvent(
        title: lines.first ?? lastError,
        details: uniqueDetails,
        isError: true
      )
    }
    if let workflowMessage {
      return RSSStatusEvent(
        title: workflowMessage,
        details: [store.statusMessage, presentation.statusMessage]
          .compactMap { $0 }
          .filter { $0 != workflowMessage },
        isError: false
      )
    }
    if let presentationMessage = presentation.statusMessage {
      return RSSStatusEvent(title: presentationMessage, details: [], isError: false)
    }
    if let summary = store.lastRefreshSummary {
      var details: [String] = []
      if let statusMessage = store.statusMessage, statusMessage != summary.statusText {
        details.append(statusMessage)
      }
      return RSSStatusEvent(
        title: refreshSummaryText(summary),
        details: details,
        isError: summary.failureCount > 0
      )
    }
    if let statusMessage = store.statusMessage {
      return RSSStatusEvent(title: statusMessage, details: [], isError: false)
    }
    return nil
  }

  @ViewBuilder
  private func statusEventView(_ event: RSSStatusEvent) -> some View {
    if event.details.isEmpty {
      statusEventLabel(event)
    } else {
      DisclosureGroup(isExpanded: $isStatusDetailsExpanded) {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(event.details.enumerated()), id: \.offset) { detail in
            Text(detail.element)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .padding(.top, 3)
      } label: {
        statusEventLabel(event)
      }
    }
  }

  private func statusEventLabel(_ event: RSSStatusEvent) -> some View {
    HStack(spacing: 7) {
      Image(systemName: event.isError ? "exclamationmark.triangle.fill" : "info.circle")
        .foregroundStyle(event.isError ? WorkbenchTheme.risk : Color.secondary)
        .accessibilityHidden(true)
      Text(event.title)
        .font(.callout.weight(event.isError ? .semibold : .regular))
        .foregroundStyle(event.isError ? WorkbenchTheme.risk : Color.primary)
        .lineLimit(1)
        .textSelection(.enabled)
    }
  }

  private func handleFilterChange(
    preservingArticle: Bool,
    resetsDisplayLimit: Bool,
    resetsTransientState: Bool
  ) {
    if resetsDisplayLimit {
      presentation.resetArticleDisplayLimit()
    }
    if !preservingArticle {
      presentation.selectedArticleID = nil
      presentation.selectedSourceID = nil
    }
    if resetsTransientState {
      selectedReaderText = ""
      allowRemoteImages = false
    }
    presentation.synchronizeSelection(
      in: store,
      preservingExistingArticle: preservingArticle
    )
  }

  private func updateReaderLayout(isCompact: Bool, animated: Bool) {
    guard isReaderCompact != isCompact else { return }
    if animated {
      withAnimation(WorkbenchMotion.standard) {
        isReaderCompact = isCompact
      }
    } else {
      isReaderCompact = isCompact
    }
  }

  private var selectedReadingTheme: RSSReadingTheme {
    RSSReadingTheme(rawValue: readingThemeRawValue) ?? .system
  }

  private var selectedReadingThemeBinding: Binding<RSSReadingTheme> {
    Binding(
      get: { selectedReadingTheme },
      set: { readingThemeRawValue = $0.rawValue }
    )
  }

  private var selectedReadingProgress: Double {
    guard let articleID = presentation.selectedArticleID else { return 0 }
    return readingProgressByArticle[articleID] ?? 0
  }

  private func recordReadingProgress(_ value: Double, for articleID: String) {
    guard value.isFinite else { return }
    let normalized = min(max(value, 0), 1)
    let previous = readingProgressByArticle[articleID] ?? -1
    guard abs(normalized - previous) >= 0.01 || normalized == 0 || normalized == 1 else {
      return
    }
    readingProgressByArticle[articleID] = normalized
    for id in readingProgressByArticle.keys where !readingProgressOrder.contains(id) {
      readingProgressOrder.append(id)
    }
    readingProgressOrder.removeAll { $0 == articleID }
    readingProgressOrder.insert(articleID, at: 0)
    while readingProgressOrder.count > RSSReadingProgressStore.maximumEntryCount {
      let evictedID = readingProgressOrder.removeLast()
      readingProgressByArticle.removeValue(forKey: evictedID)
    }
    scheduleReadingProgressPersistence()
  }

  private func scheduleReadingProgressPersistence() {
    readingProgressSaveTask?.cancel()
    let values = readingProgressByArticle
    let order = readingProgressOrder
    readingProgressSaveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      RSSReadingProgressStore.save(values, orderedArticleIDs: order)
      readingProgressSaveTask = nil
    }
  }

  private func persistReadingProgressImmediately() {
    readingProgressSaveTask?.cancel()
    readingProgressSaveTask = nil
    RSSReadingProgressStore.save(
      readingProgressByArticle,
      orderedArticleIDs: readingProgressOrder
    )
  }

  @ViewBuilder
  private var statusBar: some View {
    if latestStatusEvent != nil || store.canUndoLastDeletion || store.canUndoLastBatchRead {
      Divider()
      HStack(alignment: .top, spacing: 12) {
        if let latestStatusEvent {
          statusEventView(latestStatusEvent)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Spacer(minLength: 0)
        }
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
      .accessibilityLabel(latestStatusEvent?.isError == true ? "RSS 错误" : "RSS 最新事件")
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
        let isWide = !WorkbenchLayoutMode.isCompactRSSReader(width: geometry.size.width)
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
        .onAppear {
          updateReaderLayout(isCompact: !isWide, animated: false)
        }
        .onChange(of: geometry.size.width) { _, width in
          updateReaderLayout(
            isCompact: WorkbenchLayoutMode.isCompactRSSReader(width: width),
            animated: true
          )
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
      isSearchFocused: $isSearchFocused,
      workflowIsBusy: workflowIsBusy,
      readingProgressByArticle: readingProgressByArticle,
      onBatchSaveToKnowledge: saveArticlesToKnowledge
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
      hasRenderableBody: metrics?.hasRenderableBody ?? false,
      readingMinutes: metrics?.readingMinutes ?? 1,
      allowRemoteImages: $allowRemoteImages,
      selectedText: $selectedReaderText,
      readingFontSize: $readingFontSize,
      readingLineSpacing: $readingLineSpacing,
      readingTheme: selectedReadingThemeBinding,
      readingProgress: selectedReadingProgress,
      onReadingProgress: { progress in
        if let articleID = article?.id {
          recordReadingProgress(progress, for: articleID)
        }
      },
      onBack: showsBackButton ? {
        withAnimation(WorkbenchMotion.standard) {
          presentation.selectedArticleID = nil
        }
      } : nil,
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
      translation: selectedTranslation,
      translationTargetCode: $translationTargetCode,
      translationCustomLanguage: $translationCustomLanguage,
      automaticTranslation: $automaticTranslationEnabled,
      translationIsRunning: translationIsRunning,
      translationError: translationError,
      dataSharingConsent: workbenchStore.ai.dataSharingConsent,
      onTranslate: {
        guard let article else { return }
        requestTranslation(for: article, force: true)
      },
      onClearTranslation: clearSelectedTranslation,
      onOpenAISettings: openAISettings,
      workflowIsBusy: workflowIsBusy
    )
  }

  private var selectedArticle: RSSArticle? {
    selectedArticlePayload
  }

  private var selectedTranslationTarget: RSSArticleTranslationTarget {
    if let preset = RSSArticleTranslationTarget.preset(for: translationTargetCode) {
      return preset
    }
    return RSSArticleTranslationTarget.custom(language: translationCustomLanguage)
      ?? .simplifiedChinese
  }

  private var selectedTranslation: RSSArticleTranslationResult? {
    guard let article = selectedArticle else { return nil }
    return translationCache[translationCacheKey(for: article, target: selectedTranslationTarget)]
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
    translationRequestID = UUID()
    translationIsRunning = false
    translationError = nil
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
      if automaticTranslationEnabled {
        requestTranslation(for: article, force: false)
      }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
      selectedArticleLoadError = error.localizedDescription
      selectedArticleIsLoading = false
    }
  }

  private func translationCacheKey(
    for article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) -> RSSArticleTranslationCacheKey {
    RSSArticleTranslationCacheKey(
      articleID: article.id,
      fetchedAt: article.fetchedAt,
      targetCode: target.languageCode
    )
  }

  private func requestTranslation(for article: RSSArticle, force: Bool) {
    let target = selectedTranslationTarget
    let cacheKey = translationCacheKey(for: article, target: target)
    let requestID = UUID()
    translationRequestID = requestID
    translationError = nil

    if !force, translationCache[cacheKey] != nil {
      translationIsRunning = false
      return
    }

    translationIsRunning = true
    Task { @MainActor in
      do {
        let result = try await workbenchStore.ai.translateRSSArticle(article, target: target)
        guard requestID == translationRequestID,
              selectedArticle?.id == article.id
        else { return }
        var updatedCache = translationCache
        updatedCache[cacheKey] = result
        if updatedCache.count > 32, let oldestKey = updatedCache.keys.first {
          updatedCache.removeValue(forKey: oldestKey)
        }
        translationCache = updatedCache
        translationError = nil
      } catch is CancellationError {
        return
      } catch {
        guard requestID == translationRequestID,
              selectedArticle?.id == article.id
        else { return }
        translationError = error.localizedDescription
      }
      guard requestID == translationRequestID else { return }
      translationIsRunning = false
    }
  }

  private func clearSelectedTranslation() {
    guard let article = selectedArticle else { return }
    translationRequestID = UUID()
    translationIsRunning = false
    translationError = nil
    translationCache.removeValue(
      forKey: translationCacheKey(for: article, target: selectedTranslationTarget)
    )
  }

  private func openAISettings() {
    requestedSettingsTabID = SettingsTab.ai.id
    openSettings()
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
        if isReaderCompact, presentation.selectedArticleID != nil {
          withAnimation(WorkbenchMotion.standard) {
            presentation.selectedArticleID = nil
          }
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

  private func saveArticlesToKnowledge(_ articleIDs: [String]) {
    let uniqueIDs = Array(Set(articleIDs)).sorted()
    guard !uniqueIDs.isEmpty, !workflowIsBusy else { return }
    workflowIsBusy = true
    workflowMessage = String(
      format: String(localized: "正在保存 %lld 篇 RSS 文章到资料库…"),
      uniqueIDs.count
    )
    Task { @MainActor in
      var successCount = 0
      var failureCount = 0
      for articleID in uniqueIDs {
        do {
          guard let article = try await store.loadArticle(id: articleID) else {
            throw RSSReaderError.persistence("文章已不存在")
          }
          _ = try await Self.importArticle(article, into: workbenchStore.knowledge)
          successCount += 1
        } catch {
          failureCount += 1
        }
      }
      workflowIsBusy = false
      workflowMessage = String(
        format: String(localized: "RSS 批量保存完成：成功 %lld、失败 %lld"),
        successCount,
        failureCount
      )
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
      success: String(localized: "已新建灵感草稿，并插入安全引用与脚注。")
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
        appendingFootnote: true,
        into: workbenchStore
      ) else {
        throw RSSReaderError.persistence("灵感草稿未能写入引用和脚注")
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
    let destination = RSSArticleWorkflow.preferredImportDestination(
      article: article,
      documents: knowledge.documents,
      folders: knowledge.folders
    )
    let result = try await knowledge.commit(preview, destination: destination)
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
        "将删除“\(feedPendingDeletion?.displayTitle ?? "该订阅")”及本机缓存文章（包括已加入稍后阅读的文章）。删除后可在底部立即撤销。"
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
    let now = Date()
    let failedFeedCount = store.feeds.filter { feed in
      switch feed.healthStatus(now: now) {
      case .failing, .backingOff:
        true
      case .never, .healthy:
        false
      }
    }.count

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
        .accessibilityIdentifier("rss-add-subscription")

        if failedFeedCount > 0 {
          Button {
            Task { await store.refreshFailedFeeds() }
          } label: {
            WorkspaceSidebarHeaderIcon("arrow.triangle.2.circlepath")
          }
          .disabled(store.isRefreshing)
          .help("重试全部失败订阅（\(failedFeedCount)）")
          .accessibilityLabel("重试全部失败订阅（\(failedFeedCount)）")
          .accessibilityIdentifier("rss-retry-failed-feeds")
        }

        Menu {
          Button {
            Task { await store.refreshAll() }
          } label: {
            Label(store.isRefreshing ? "正在刷新…" : "刷新全部", systemImage: "arrow.clockwise")
          }
          .disabled(store.isRefreshing || store.feeds.isEmpty)
          .keyboardShortcut("r", modifiers: [.command])
          Button {
            Task { await store.refreshFailedFeeds() }
          } label: {
            Label("重试失败订阅（\(failedFeedCount)）", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(store.isRefreshing || failedFeedCount == 0)
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
        .accessibilityIdentifier("rss-subscription-management")
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
          .lineLimit(2)
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
      let details = [
        issueMessage,
        retryDescription(for: feed, now: now),
        lastSuccessfulRefreshDescription(for: feed)
      ].compactMap { $0 }
      return (details.joined(separator: " · "), true)
    }
    if let successDescription = lastSuccessfulRefreshDescription(for: feed) {
      return (successDescription, false)
    }
    return ("尚未成功刷新", false)
  }

  private func lastSuccessfulRefreshDescription(for feed: RSSFeed) -> String? {
    guard let lastUpdatedAt = feed.lastUpdatedAt else { return nil }
    return "上次成功刷新 \(lastUpdatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
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
  let workflowIsBusy: Bool
  let readingProgressByArticle: [String: Double]
  let onBatchSaveToKnowledge: ([String]) -> Void
  @State private var feedPendingAddressEdit: RSSFeed?
  @State private var isBatchSelectionMode = false
  @State private var selectedBatchArticleIDs = Set<String>()
  @FocusState private var isArticleListFocused: Bool

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
          .accessibilityIdentifier("rss-mark-all-read")
          if !isBatchSelectionMode {
            Button("批量选择", systemImage: "checklist") {
              isBatchSelectionMode = true
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("批量选择 RSS 文章")
            .accessibilityIdentifier("rss-batch-select")
          }
        }

        TextField("搜索文章标题或正文", text: $searchDraft.text)
          .textFieldStyle(.roundedBorder)
          .focused($isSearchFocused)
          .accessibilityLabel("搜索 RSS 文章标题或正文")
          .accessibilityIdentifier("rss-article-search")

        HStack(spacing: 10) {
          Toggle("只看未读", isOn: $presentation.unreadOnly)
            .toggleStyle(.checkbox)
            .accessibilityLabel("只显示未读 RSS 文章")
            .accessibilityIdentifier("rss-unread-only")

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
          .accessibilityIdentifier("rss-article-filter")

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
          .accessibilityIdentifier("rss-article-sort")

          if searchDraft.text != presentation.debouncedSearchText {
            ProgressView()
              .controlSize(.small)
              .help("正在搜索")
              .accessibilityLabel("正在搜索 RSS 文章")
          }
          Spacer(minLength: 0)
        }

        if isBatchSelectionMode {
          batchSelectionControls(visibleArticles: visibleArticles)
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
    .focusable()
    .focused($isArticleListFocused)
    .accessibilityHint("点击文章后，可使用上下箭头浏览，按 Return 打开文章")
    .onKeyPress(.upArrow) {
      guard !isSearchFocused else { return .ignored }
      moveArticleSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !isSearchFocused else { return .ignored }
      moveArticleSelection(by: 1)
      return .handled
    }
    .onKeyPress(.return) {
      guard !isSearchFocused else { return .ignored }
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

  private func moveArticleSelection(by offset: Int) {
    guard offset != 0 else { return }
    let articles = presentation.matchingArticles(in: store)
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
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(
                RSSArticlePresentationSupport.sections(
                  for: articles,
                  groupsByDate: presentation.groupsByDate,
                  sortOrder: presentation.sortOrder
                )
              ) { section in
                if let title = section.title {
                  Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
                }

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

private struct RSSArticleRow: View {
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
      .accessibilityValue(accessibilityValue)

      Menu {
        Button(
          article.isStarred ? "移出稍后阅读" : "加入稍后阅读",
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
      .opacity(isHovering ? 1 : 0.72)
      .help("文章操作")
      .accessibilityLabel("文章操作：\(article.title)")
      .accessibilityHint(
        String(localized: "打开菜单以标记已读、加入稍后阅读或打开原文")
      )
      .accessibilityIdentifier("rss-article-actions-\(article.id)")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .contain)

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
    .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
    .onHover { isHovering = $0 }
    .accessibilityIdentifier("rss-article-row-content-\(article.id)")
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
  let hasRenderableBody: Bool
  let readingMinutes: Int
  @Binding var allowRemoteImages: Bool
  @Binding var selectedText: String
  @Binding var readingFontSize: Double
  @Binding var readingLineSpacing: Double
  @Binding var readingTheme: RSSReadingTheme
  let readingProgress: Double
  let onReadingProgress: (Double) -> Void
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
  let translation: RSSArticleTranslationResult?
  @Binding var translationTargetCode: String
  @Binding var translationCustomLanguage: String
  @Binding var automaticTranslation: Bool
  let translationIsRunning: Bool
  let translationError: String?
  let dataSharingConsent: AIDataSharingConsentPresentation
  let onTranslate: () -> Void
  let onClearTranslation: () -> Void
  let onOpenAISettings: () -> Void
  let workflowIsBusy: Bool
  @State private var showsTranslatedArticle = false
  @State private var showsAnnotationSummary = false

  var body: some View {
    Group {
      if let article {
        loadedArticleView(article)
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
            readingProgressLabel
            Divider()
            if isLoading {
              ProgressView("正在读取本机正文…")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text(loadError ?? "暂时无法读取这篇文章的本机正文。")
                .foregroundStyle(WorkbenchTheme.risk)
              HStack(spacing: 8) {
                Button("重试读取", systemImage: "arrow.clockwise", action: onRetryLoad)
                  .workbenchProminentActionStyle()
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
    .onAppear {
      showsTranslatedArticle = translation != nil
    }
    .onChange(of: article?.id) { _, _ in
      showsTranslatedArticle = false
      showsAnnotationSummary = false
      selectedText = ""
    }
    .onChange(of: translation?.id) { _, newValue in
      showsTranslatedArticle = newValue != nil
    }
  }

  private func loadedArticleView(_ article: RSSArticle) -> some View {
    let displayedArticle = articleForDisplay(article)
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        if let onBack {
          Button("返回文章列表", systemImage: "chevron.left", action: onBack)
            .buttonStyle(.borderless)
            .accessibilityLabel("返回 RSS 文章列表")
        }

        Text(displayedArticle.title)
          .font(.workbenchPageTitle)
          .lineLimit(3)
          .textSelection(.enabled)
          .help(displayedArticle.title)

        VStack(alignment: .leading, spacing: 4) {
          articleMetadata(for: article)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          readingProgressLabel
        }
        .padding(.top, 2)

        readerToolbar(for: article)
          .padding(.top, 10)
        translationStatusView

        HStack {
          remoteImageStatus
          Spacer(minLength: 0)
        }
      }
      .padding(WorkbenchSpacing.spacious)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)

      Divider()

      if !hasRenderableBody {
        VStack(alignment: .leading) {
          Text("这篇文章没有可显示的正文，建议打开原文阅读。")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(WorkbenchSpacing.spacious)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        RSSArticleWebView(
          article: displayedArticle,
          allowRemoteImages: allowRemoteImages,
          highlights: highlights,
          mediaAssets: mediaAssets,
          mediaCacheDirectoryURL: mediaCacheDirectoryURL,
          fontSize: readingFontSize,
          lineSpacing: readingLineSpacing,
          theme: readingTheme,
          initialReadingProgress: readingProgress,
          renderRevision: showsTranslatedArticle
            ? translation?.id ?? "translated"
            : "source-\(article.fetchedAt.timeIntervalSinceReferenceDate)",
          onSelectionChanged: { selectedText = $0 },
          onReadingProgress: onReadingProgress,
          onNavigationError: { message in
            selectedText = ""
            onNavigationError(message)
          }
        )
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 240, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .layoutPriority(1)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if hasSelectedText {
            selectionPalette
              .frame(maxWidth: 520)
              .padding(WorkbenchSpacing.card)
              .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
          }
        }
        .accessibilityLabel("保留标题、列表、引用、代码块和链接的文章正文")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("RSS 文章阅读区域")
  }

  private func articleForDisplay(_ article: RSSArticle) -> RSSArticle {
    guard showsTranslatedArticle, let translation else { return article }
    return translation.applying(to: article)
  }

  private var readingProgressLabel: some View {
    Text("已读 \(readingProgressPercentage)%")
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .help("阅读进度：已读 \(readingProgressPercentage)%")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("阅读进度")
      .accessibilityValue("已读 \(readingProgressPercentage)%")
  }

  private var normalizedReadingProgress: Double {
    min(max(readingProgress, 0), 1)
  }

  private var readingProgressPercentage: Int {
    Int((normalizedReadingProgress * 100).rounded())
  }

  @ViewBuilder
  private var translationStatusView: some View {
    if translationIsRunning || translationError != nil || translation != nil || automaticTranslation {
      VStack(alignment: .leading, spacing: 5) {
        if automaticTranslation {
          let message = "自动翻译已开启：打开文章时会发送当前文章标题和正文。"
          Label(message, systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(message)
        }
        if translationIsRunning {
          HStack(spacing: 7) {
            ProgressView()
              .controlSize(.small)
            Text("正在翻译标题和正文…")
          }
          .font(.caption)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("正在翻译当前 RSS 文章的标题和正文")
        }
        if let translationError {
          Label(translationError, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.risk)
            .lineLimit(3)
            .help(translationError)
            .textSelection(.enabled)
        }
        if let translation {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(
              "已生成 \(localizedTranslationTargetName(translation.target)) 译文 · \(translation.providerName)",
              systemImage: showsTranslatedArticle ? "character.book.closed" : "doc.plaintext"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if translation.wasInputTruncated {
              Text("（源文过长，已按安全上限截取）")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .lineLimit(2)
        }
        if dataSharingConsent.destinationState == .remote {
          let message = dataSharingConsent.isGranted
            ? "AI 服务：\(dataSharingConsent.providerName)（\(dataSharingConsent.destination)）；发送范围：当前文章标题和正文。"
            : "远程 AI 发送尚未授权；翻译前请在 AI 设置中确认服务商和发送范围。"
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .help(message)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("RSS 翻译状态")
    }
  }

  private func localizedTranslationTargetName(
    _ target: RSSArticleTranslationTarget
  ) -> String {
    switch target.languageCode {
    case RSSArticleTranslationTarget.simplifiedChinese.languageCode:
      return String(localized: "简体中文")
    case RSSArticleTranslationTarget.traditionalChinese.languageCode:
      return String(localized: "繁体中文")
    case RSSArticleTranslationTarget.english.languageCode:
      return String(localized: "English")
    case RSSArticleTranslationTarget.japanese.languageCode:
      return String(localized: "日语")
    case RSSArticleTranslationTarget.korean.languageCode:
      return String(localized: "韩语")
    case RSSArticleTranslationTarget.spanish.languageCode:
      return String(localized: "西班牙语")
    case RSSArticleTranslationTarget.french.languageCode:
      return String(localized: "法语")
    case RSSArticleTranslationTarget.german.languageCode:
      return String(localized: "德语")
    default:
      let prefix = "custom:"
      guard target.languageCode.hasPrefix(prefix) else { return target.languageCode }
      return String(target.languageCode.dropFirst(prefix.count))
    }
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
  private func readerToolbar(for article: RSSArticle) -> some View {
    HStack(alignment: .center, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 8) {
          previousButton
          nextButton
          starredButton(for: article)
          readButton(for: article)
          originalArticleButton(for: article)
          translationControls
          readingComfortControls
          annotationActionsMenu
          remoteImageToggle
          workflowToolbarActions(for: article)
          if workflowIsBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在处理阅读内容")
          }
        }
        HStack(alignment: .center, spacing: 8) {
          previousButton
          nextButton
          starredButton(for: article)
            .labelStyle(.iconOnly)
          readButton(for: article)
            .labelStyle(.iconOnly)
          translationControls
          readerOverflowMenu(for: article)
          if workflowIsBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在处理阅读内容")
          }
        }
      }
      annotationSummaryButton(for: article)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .controlSize(.small)
  }

  private var translationControls: some View {
    RSSArticleTranslationControls(
      translation: translation,
      targetCode: $translationTargetCode,
      customLanguage: $translationCustomLanguage,
      automaticTranslation: $automaticTranslation,
      isTranslating: translationIsRunning,
      isShowingTranslation: showsTranslatedArticle,
      onTranslate: onTranslate,
      onToggleDisplay: { showsTranslatedArticle.toggle() },
      onClear: onClearTranslation,
      dataSharingConsent: dataSharingConsent,
      onOpenAISettings: onOpenAISettings
    )
  }

  private var previousButton: some View {
    Button("上一篇", systemImage: "chevron.left", action: onPrevious)
      .buttonStyle(.bordered)
      .disabled(!canNavigatePrevious)
      .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
      .accessibilityLabel("阅读上一篇文章")
      .accessibilityIdentifier("rss-reader-previous")
  }

  private var nextButton: some View {
    Button("下一篇", systemImage: "chevron.right", action: onNext)
      .buttonStyle(.bordered)
      .disabled(!canNavigateNext)
      .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
      .accessibilityLabel("阅读下一篇文章")
      .accessibilityIdentifier("rss-reader-next")
  }

  private func starredButton(for article: RSSArticle) -> some View {
    Button(action: onToggleStarred) {
      Label(
        article.isStarred ? "移出稍后阅读" : "加入稍后阅读",
        systemImage: article.isStarred ? "star.fill" : "star"
      )
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("s", modifiers: [.command, .control])
    .accessibilityLabel(article.isStarred ? "将文章移出稍后阅读" : "将文章加入稍后阅读")
    .accessibilityIdentifier("rss-reader-star")
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
    .accessibilityIdentifier("rss-reader-read-toggle")
  }

  private var readingComfortControls: some View {
    Menu {
      readingComfortMenuContent
    } label: {
      Label("阅读舒适度", systemImage: "textformat.size")
    }
    .menuStyle(.borderlessButton)
    .help("调整 RSS 正文字号、行距和主题")
    .accessibilityLabel("阅读舒适度设置")
    .accessibilityIdentifier("rss-reader-comfort")
  }

  @ViewBuilder
  private var readingComfortMenuContent: some View {
    Section("正文字号") {
      Slider(
        value: $readingFontSize,
        in: RSSReadingComfortConfiguration.fontSizeRange,
        step: 1
      ) {
        Text("字号")
      } minimumValueLabel: {
        Text("小")
      } maximumValueLabel: {
        Text("大")
      }
      Text("当前 \(Int(readingFontSize)) pt")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("行距") {
      Slider(
        value: $readingLineSpacing,
        in: RSSReadingComfortConfiguration.lineSpacingRange,
        step: 0.05
      ) {
        Text("行距")
      } minimumValueLabel: {
        Text("紧")
      } maximumValueLabel: {
        Text("松")
      }
      Text("当前 \(readingLineSpacing, specifier: "%.2f")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Picker("阅读主题", selection: $readingTheme) {
      ForEach(RSSReadingTheme.allCases) { theme in
        Label(theme.title, systemImage: theme.systemImage)
          .tag(theme)
      }
    }
  }

  private var annotationActionsMenu: some View {
    Menu {
      annotationActionItems
    } label: {
      Label("标注与标签", systemImage: "highlighter")
    }
    .menuStyle(.button)
    .help("文章操作")
    .accessibilityLabel("标注与标签")
    .accessibilityIdentifier("rss-reader-annotation-actions")
  }

  private func annotationSummaryButton(for article: RSSArticle) -> some View {
    Button("查看标注", systemImage: "list.bullet.rectangle") {
      showsAnnotationSummary = true
    }
    .buttonStyle(.bordered)
    .help("查看当前文章的标签、高亮与批注")
    .accessibilityLabel("查看当前文章的标签、高亮与批注")
    .accessibilityIdentifier("rss-reader-annotation-summary")
    .popover(isPresented: $showsAnnotationSummary, arrowEdge: .bottom) {
      annotationSummary(for: article)
    }
  }

  @ViewBuilder
  private var annotationActionItems: some View {
    Button("高亮", systemImage: "highlighter", action: onBeginHighlight)
      .disabled(!hasSelectedText)
    Button("添加批注", systemImage: "note.text.badge.plus", action: onBeginNote)
      .disabled(!hasSelectedText)
    Divider()
    Button("编辑标签", systemImage: "tag", action: onEditTags)
      .keyboardShortcut("t", modifiers: [.command, .control])
  }

  private var hasSelectedText: Bool {
    !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func readerOverflowMenu(for article: RSSArticle) -> some View {
    Menu {
      Button(
        article.isStarred ? "移出稍后阅读" : "加入稍后阅读",
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
        Button("在系统浏览器中打开原文", systemImage: "safari", action: onOpenOriginal)
      }

      Divider()
      Menu {
        readingComfortMenuContent
      } label: {
        Label("阅读舒适度", systemImage: "textformat.size")
      }
      Toggle("加载远程图片", isOn: $allowRemoteImages)

      Divider()
      annotationActionItems

      Divider()
      workflowActionItems(for: article)
    } label: {
      Label("更多阅读操作", systemImage: "ellipsis.circle")
    }
    .menuStyle(.button)
    .accessibilityLabel("更多阅读操作")
    .accessibilityIdentifier("rss-reader-more-actions")
  }

  private func workflowToolbarActions(for article: RSSArticle) -> some View {
    HStack(spacing: 8) {
      Menu {
        workflowSaveActionItems(for: article)
      } label: {
        Label("保存到资料库", systemImage: "books.vertical")
      }
      .menuStyle(.button)
      .disabled(workflowIsBusy)
      .accessibilityLabel("保存当前文章到资料库")
      .accessibilityIdentifier("rss-reader-save-to-library")

      Menu {
        workflowWritingActionItems(for: article)
      } label: {
        Label("用于写作", systemImage: "square.and.pencil")
      }
      .menuStyle(.button)
      .disabled(workflowIsBusy)
      .accessibilityLabel("将当前文章用于写作")
      .accessibilityIdentifier("rss-reader-use-for-writing")
    }
  }

  @ViewBuilder
  private func workflowSaveActionItems(for article: RSSArticle) -> some View {
    workflowActionButton(
      "保存文章摘要",
      systemImage: "doc.text",
      article: article,
      action: onSaveToKnowledge
    )
    workflowActionButton(
      "摘录并添加笔记",
      systemImage: "note.text.badge.plus",
      article: article,
      action: onAddExcerptNote
    )
  }

  @ViewBuilder
  private func workflowWritingActionItems(for article: RSSArticle) -> some View {
    workflowActionButton(
      "插入当前文章",
      systemImage: "arrow.down.doc",
      article: article,
      action: onInsertReference
    )
    workflowActionButton(
      "新建灵感草稿",
      systemImage: "square.and.pencil",
      article: article,
      action: onCreateInspirationDraft
    )
  }

  @ViewBuilder
  private func workflowActionItems(for article: RSSArticle) -> some View {
    workflowSaveActionItems(for: article)
    Divider()
    workflowWritingActionItems(for: article)
  }

  private func workflowActionButton(
    _ title: String,
    systemImage: String,
    article: RSSArticle,
    action: @escaping (RSSArticle) -> Void
  ) -> some View {
    Button {
      action(article)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .disabled(workflowIsBusy)
    .accessibilityLabel(title)
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
      HStack {
        Label("已选文本", systemImage: "text.quote")
          .font(.headline)
        Spacer()
        Button("关闭", systemImage: "xmark") {
          selectedText = ""
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityLabel("关闭已选文本操作")
      }
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

  private func annotationSummary(for article: RSSArticle) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("标签、高亮与批注", systemImage: "highlighter")
            .font(.headline)
          Spacer()
          Button("关闭", systemImage: "xmark") {
            showsAnnotationSummary = false
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .accessibilityLabel("关闭标签与高亮")
        }
        articleTagSummary(for: article)
        Divider()
        if highlights.isEmpty {
          ContentUnavailableView(
            "暂无高亮与批注",
            systemImage: "highlighter",
            description: Text("在正文中选择文字后，可以添加高亮或批注。")
          )
        } else {
          highlightList
        }
      }
      .padding(WorkbenchSpacing.card)
    }
    .frame(
      minWidth: 380,
      idealWidth: 400,
      maxWidth: 440,
      minHeight: 180,
      idealHeight: 340,
      maxHeight: 480
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前文章的标签、高亮与批注")
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
      Text("修改后会保留这个订阅的本地文章、已读状态、稍后阅读状态、标签和高亮，然后使用新地址重新刷新。")
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

      TextField("https://example.com", text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(.URL)
        .accessibilityLabel("RSS / Atom 地址或博客首页")
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
        Button("发现并添加") {
          submit()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(value.trimmedForPublishing.isEmpty)
        .accessibilityLabel("发现 RSS / Atom 并添加")
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
