import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RSSReaderView: View {
  @ObservedObject var store: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @Environment(\.openSettings) var openSettings
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @State var sceneCommandOwnerID = UUID()
  @State var excerptNoteArticle: RSSArticle?
  @State var highlightDraft: RSSHighlightDraft?
  @State var tagEditorArticle: RSSArticle?
  @State var selectedReaderText = ""
  @State var allowRemoteImages = RSSReaderUserPreferences.defaultRemoteImagesEnabled
  @State var workflowMessage: String?
  @State var workflowIsBusy = false
  @State var isReaderCompact = false
  @State var isStatusDetailsExpanded = false
  @State var selectedArticlePayload: RSSArticle?
  @State var selectedArticleLoadError: String?
  @State var selectedArticleIsLoading = false
  @State var selectedArticleReloadToken = 0
  @State var translationCache:
    [RSSArticleTranslationCacheKey: RSSArticleTranslationResult] = [:]
  @State var translationIsRunning = false
  @State var translationError: String?
  @State var translationRequestID = UUID()
  @State private var readingProgressByArticle = RSSReadingProgressStore.load()
  @State private var readingProgressOrder = RSSReadingProgressStore.loadOrder()
  @State private var readingProgressSaveTask: Task<Void, Never>?
  @AppStorage("rssReaderFontSize") private var readingFontSize = RSSReadingComfortConfiguration
    .defaultFontSize
  @AppStorage("rssReaderLineSpacing") private var readingLineSpacing =
    RSSReadingComfortConfiguration.defaultLineSpacing
  @AppStorage("rssReaderTheme") private var readingThemeRawValue = RSSReadingTheme.system.rawValue
  @AppStorage("rssReaderTranslationTargetCode") var translationTargetCode =
    RSSArticleTranslationTarget.simplifiedChinese.languageCode
  @AppStorage("rssReaderTranslationCustomLanguage") var translationCustomLanguage = ""
  @AppStorage(RSSReaderUserPreferences.automaticTranslationEnabledKey)
  var automaticTranslationEnabled = RSSReaderUserPreferences.defaultAutomaticTranslationEnabled
  @AppStorage(RSSReaderUserPreferences.automaticMarkReadAtEndEnabledKey)
  private var automaticMarkReadAtEndEnabled =
    RSSReaderUserPreferences.defaultAutomaticMarkReadAtEndEnabled
  @AppStorage(RSSReaderUserPreferences.remoteImagesEnabledKey)
  private var defaultRemoteImagesEnabled = RSSReaderUserPreferences.defaultRemoteImagesEnabled
  @AppStorage(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabledKey)
  private var offlineCacheFullTextOnRefreshEnabled =
    RSSReaderUserPreferences.defaultOfflineCacheFullTextOnRefreshEnabled
  @AppStorage(RSSReaderUserPreferences.automaticFullTextExtractionEnabledKey)
  var automaticFullTextExtractionEnabled =
    RSSReaderUserPreferences.defaultAutomaticFullTextExtractionEnabled
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""

  var body: some View {
    let loadRequest = selectedArticleLoadRequest
    ZStack(alignment: .bottomLeading) {
      readerSplitView
      if store.canUndoLastDeletion || store.canUndoLastBatchRead {
        floatingUndoToast
          .padding(16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-workspace")
    .onChange(of: readerCommandActions?.sceneCommandPresentation, initial: true) { _, _ in
      sceneCommandRouter.registerRSSReader(
        readerCommandActions,
        owner: sceneCommandOwnerID
      )
    }
    .onAppear {
      presentation.synchronizeSelection(in: store)
      allowRemoteImages = defaultRemoteImagesEnabled
      store.isOfflineCacheFullTextEnabled = offlineCacheFullTextOnRefreshEnabled
    }
    .onDisappear {
      sceneCommandRouter.unregisterRSSReader(owner: sceneCommandOwnerID)
      persistReadingProgressAfterDisappear()
    }
    .onChange(of: offlineCacheFullTextOnRefreshEnabled) { _, isEnabled in
      store.isOfflineCacheFullTextEnabled = isEnabled
    }
    .onChange(of: automaticFullTextExtractionEnabled) { _, isEnabled in
      guard isEnabled, let article = selectedArticle, presentation.isTruncatedCandidate(article) else { return }
      Task {
        await presentation.fetchFullText(for: article, store: store)
      }
    }
    .onChange(of: presentation.selectedArticleID) { _, newArticleID in
      selectedReaderText = ""
      // The article-level switch is intentionally transient. A new article
      // starts from the application default, while changes made in the
      // reader never write back to that default.
      allowRemoteImages = defaultRemoteImagesEnabled
      // A nil selection is an explicit return to the list. For an article to
      // article switch retain the old payload so its existing WebView can be
      // covered by the reader's loading overlay while the new payload loads.
      if newArticleID == nil {
        selectedArticlePayload = nil
      }
      selectedArticleLoadError = nil
      selectedArticleIsLoading = newArticleID != nil
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
        onAdd: { value in presentation.addSubscription(value, to: store) }
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
      details.append(
        contentsOf: [
          store.statusMessage,
          workflowMessage,
          presentation.statusMessage,
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
      allowRemoteImages = defaultRemoteImagesEnabled
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
    let previousProgress = readingProgressByArticle[articleID]
    guard
      RSSReadingProgressPolicy.shouldRecord(
        previousProgress: previousProgress,
        progress: normalized
      )
    else {
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

    if RSSReaderUserPreferences.shouldAutomaticallyMarkReadAtEnd(
      enabled: automaticMarkReadAtEndEnabled,
      previousProgress: previousProgress,
      progress: normalized
    ) {
      markArticleReadFromProgress(articleID)
    }
  }

  private func scheduleReadingProgressPersistence() {
    readingProgressSaveTask?.cancel()
    let values = readingProgressByArticle
    let order = readingProgressOrder
    let revision = RSSReadingProgressPersistenceRevision.next()
    readingProgressSaveTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      await RSSReadingProgressPersistence.shared.save(
        values,
        orderedArticleIDs: order,
        revision: revision
      )
      if !Task.isCancelled {
        readingProgressSaveTask = nil
      }
    }
  }

  private func persistReadingProgressAfterDisappear() {
    readingProgressSaveTask?.cancel()
    let values = readingProgressByArticle
    let order = readingProgressOrder
    let revision = RSSReadingProgressPersistenceRevision.next()
    readingProgressSaveTask = Task {
      await RSSReadingProgressPersistence.shared.save(
        values,
        orderedArticleIDs: order,
        revision: revision
      )
    }
  }

  @ViewBuilder
  private var floatingUndoToast: some View {
    HStack(alignment: .center, spacing: 12) {
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
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .workbenchGlassSurface(
      material: .regularMaterial,
      in: Capsule()
    )
    .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("RSS 撤销操作")
  }

  @ViewBuilder
  private var readerSplitView: some View {
    if store.feeds.isEmpty {
      RSSReaderWelcomeView(
        onAdd: { presentation.isAddSubscriptionPresented = true },
        onDiscover: { value in presentation.addSubscription(value, to: store) }
      )
    } else {
      GeometryReader { geometry in
        let isWide = !WorkbenchLayoutMode.isCompactRSSReader(width: geometry.size.width)
        let showsArticleList = isWide || selectedArticleHeader == nil

        Group {
          if isWide {
            HSplitView {
              articleColumn
                .frame(
                  minWidth: 300,
                  idealWidth: 380,
                  maxWidth: 420,
                  maxHeight: .infinity
                )
                .layoutPriority(1)

              readerColumn(showsBackButton: false)
                .frame(
                  minWidth: 560,
                  idealWidth: 900,
                  maxWidth: .infinity,
                  maxHeight: .infinity
                )
                .layoutPriority(1)
            }
          } else if showsArticleList {
            articleColumn
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            readerColumn(showsBackButton: true)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      workflowIsBusy: workflowIsBusy,
      readingProgressByArticle: readingProgressByArticle,
      onBatchSaveToKnowledge: saveArticlesToKnowledge
    )
  }

  private func readerColumn(showsBackButton: Bool) -> some View {
    // Keep the last loaded payload in the view tree while a newly selected
    // article is fetched. `selectedArticle` is action-safe and only returns a
    // payload whose identity matches the current selection; the retained
    // payload below is only used as a visually covered loading surface.
    let rawArticle = selectedArticlePayload
    let displayedArticle = rawArticle.map { presentation.effectiveArticle(for: $0) }
    let actionArticle = selectedArticle
    let metrics = displayedArticle.map { presentation.readerMetrics(for: $0) }
    let isTruncated = actionArticle.map { presentation.isTruncatedCandidate($0) } ?? false
    let isShowingFullText = actionArticle.map { presentation.isShowingFullText(for: $0.id) } ?? false
    let isFetchingFullText = actionArticle.map { presentation.isFetchingFullText(for: $0.id) } ?? false
    let fullTextError = actionArticle.flatMap { presentation.fullTextError(for: $0.id) }
    return RSSArticleReader(
      articleHeader: selectedArticleHeader,
      article: displayedArticle,
      isLoading: selectedArticleIsLoading,
      loadError: selectedArticleLoadError,
      feedTitle: selectedFeedTitle,
      feedIconURL: selectedFeed?.iconURL,
      highlights: displayedArticle.map { store.highlights(for: $0.id) } ?? [],
      hasRenderableBody: metrics?.hasRenderableBody ?? false,
      readingMinutes: metrics?.readingMinutes ?? 1,
      allowRemoteImages: $allowRemoteImages,
      selectedText: $selectedReaderText,
      readingFontSize: $readingFontSize,
      readingLineSpacing: $readingLineSpacing,
      readingTheme: selectedReadingThemeBinding,
      readingProgress: selectedReadingProgress,
      onReadingProgress: { progress in
        if let articleID = actionArticle?.id {
          recordReadingProgress(progress, for: articleID)
        }
      },
      onBack: showsBackButton
        ? {
          withAnimation(WorkbenchMotion.standard) {
            presentation.selectedArticleID = nil
          }
        } : nil,
      onRetryLoad: { selectedArticleReloadToken &+= 1 },
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
        guard let actionArticle else { return }
        requestTranslation(for: actionArticle, force: true)
      },
      onClearTranslation: clearSelectedTranslation,
      onOpenAISettings: openAISettings,
      workflowIsBusy: workflowIsBusy,
      isTruncatedCandidate: isTruncated,
      isShowingFullText: isShowingFullText,
      isFetchingFullText: isFetchingFullText,
      fullTextError: fullTextError,
      automaticFullTextExtraction: $automaticFullTextExtractionEnabled,
      onToggleFullText: {
        guard let actionArticle else { return }
        presentation.toggleFullText(for: actionArticle, store: store)
      }
    )
  }

}
