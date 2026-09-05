import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RSSReaderView: View {
  @ObservedObject var store: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @Environment(\.openSettings) var openSettings
  @Environment(\.settingsWorkspaceCommandAction) var settingsWorkspaceCommandAction
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State var sceneCommandOwnerID = UUID()
  @State var excerptNoteArticle: RSSArticle?
  @State var highlightDraft: RSSHighlightDraft?
  @State var tagEditorArticle: RSSArticle?
  @State var selectedReaderText = ""
  @State var allowRemoteImages = RSSReaderUserPreferences.defaultRemoteImagesEnabled
  @State var workflowMessage: String?
  @State var workflowIsBusy = false
  @State var isReaderCompact = false
  @State var selectedArticlePayload: RSSArticle?
  @State var selectedArticleLoadError: String?
  @State var selectedArticleIsLoading = false
  @State var selectedArticleReloadToken = 0
  @State var translationCache: [RSSArticleTranslationCacheKey: RSSArticleTranslationResult] = [:]
  @State var translationIsRunning = false
  @State var translationError: String?
  @State var translationRequestID = UUID()
  @State var appleTranslationRequest: RSSAppleTranslationSessionRequest?
  @State var translationRouteTask: Task<Void, Never>?
  @State private var readingProgressByArticle = RSSReadingProgressStore.load()
  @State private var readingProgressOrder = RSSReadingProgressStore.loadOrder()
  @State private var readingProgressRecency: [String: UInt64] = [:]
  @State private var readingProgressSequence: UInt64 = 0
  @State private var readingProgressSaveTask: Task<Void, Never>?
  @AppStorage(ReaderTypographyConfiguration.fontSizeKey)
  private var readingFontSize = ReaderTypographyConfiguration.defaultFontSize
  @AppStorage(ReaderTypographyConfiguration.lineSpacingKey)
  private var readingLineSpacing = ReaderTypographyConfiguration.defaultLineSpacing
  @AppStorage(ReaderTypographyConfiguration.paragraphSpacingKey)
  private var readingParagraphSpacing = ReaderTypographyConfiguration.defaultParagraphSpacing
  @AppStorage(ReaderTypographyConfiguration.themeKey)
  private var readingThemeRawValue = RSSReadingTheme.system.rawValue
  @AppStorage(ReaderTypographyConfiguration.fontFamilyKey)
  private var readingFontFamilyRawValue = ReaderTypographyConfiguration.defaultFontFamily.rawValue
  @AppStorage(ReaderTypographyConfiguration.textAlignmentKey)
  private var readingTextAlignmentRawValue = ReaderTypographyConfiguration.defaultTextAlignment
    .rawValue
  @AppStorage(ReaderTypographyConfiguration.codeHighlightThemeKey)
  private var readingCodeHighlightThemeRawValue = ReaderTypographyConfiguration
    .defaultCodeHighlightTheme.rawValue
  @AppStorage("rssReaderTranslationTargetCode") var translationTargetCode =
    RSSArticleTranslationTarget.simplifiedChinese.languageCode
  @AppStorage("rssReaderTranslationCustomLanguage") var translationCustomLanguage = ""
  @AppStorage(RSSReaderUserPreferences.translationBackendKey)
  var translationBackendRawValue = RSSReaderUserPreferences.defaultTranslationBackend.rawValue
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

  var translationBackend: RSSArticleTranslationBackend {
    guard let backend = RSSArticleTranslationBackend(rawValue: translationBackendRawValue) else {
      return RSSReaderUserPreferences.defaultTranslationBackend
    }
    if backend == .apple, !RSSReaderUserPreferences.isAppleTranslationAvailable {
      return .ai
    }
    return backend
  }

  var translationBackendBinding: Binding<RSSArticleTranslationBackend> {
    Binding(
      get: { translationBackend },
      set: { translationBackendRawValue = $0.rawValue }
    )
  }

  var body: some View {
    readerAlerts
  }

  private var readerSurface: some View {
    ZStack(alignment: .bottomLeading) {
      readerSplitView
      RSSUndoToastOverlay(
        canUndoLastDeletion: store.canUndoLastDeletion,
        canUndoLastBatchRead: store.canUndoLastBatchRead,
        undoLastDeletion: store.undoLastDeletion,
        undoLastBatchRead: { _ = store.undoLastBatchRead() }
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-workspace")
    .background {
      RSSAppleTranslationSessionHost(
        request: appleTranslationRequest,
        onCompletion: applyAppleTranslationResult,
        onFailure: handleAppleTranslationFailure
      )
    }
  }

  private var readerLifecycle: some View {
    readerSurface
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
      invalidateTranslationRequest()
    }
    .onChange(of: offlineCacheFullTextOnRefreshEnabled) { _, isEnabled in
      store.isOfflineCacheFullTextEnabled = isEnabled
    }
    .onChange(of: automaticFullTextExtractionEnabled) { _, isEnabled in
      guard isEnabled, let article = selectedArticle, presentation.isTruncatedCandidate(article)
      else { return }
      Task {
        await presentation.fetchFullText(for: article, store: store)
      }
    }
    .onChange(of: store.mutationRevision) { _, _ in
      // RSSReaderStore is shared across windows while presentation caches are
      // window-local. Reconcile an already-open article when another window
      // finishes persisting a newer full-text extraction; the presentation
      // method preserves this window's summary/full-text toggle.
      guard let article = selectedArticle else { return }
      _ = presentation.restoreCachedFullText(for: article, store: store)
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
      invalidateTranslationRequest()
    }
    .onChange(of: translationTargetCode) { _, _ in
      invalidateTranslationRequest()
      if automaticTranslationEnabled, let article = selectedArticle {
        requestTranslation(for: article, backend: translationBackend, force: false)
      }
    }
    .onChange(of: translationBackendRawValue) { _, _ in
      invalidateTranslationRequest()
      if automaticTranslationEnabled, let article = selectedArticle {
        requestTranslation(for: article, backend: translationBackend, force: false)
      }
    }
    .onChange(of: automaticTranslationEnabled) { _, isEnabled in
      guard isEnabled else {
        invalidateTranslationRequest()
        return
      }
      guard let article = selectedArticle else { return }
      requestTranslation(for: article, backend: translationBackend, force: false)
    }
  }

  private var readerLoading: some View {
    let loadRequest = selectedArticleLoadRequest
    return
      readerLifecycle
      .task(id: loadRequest) {
        await loadSelectedArticle(loadRequest)
      }
      .onChange(of: filterChangeToken) { oldValue, newValue in
        handleFilterChangeTokenUpdate(from: oldValue, to: newValue)
      }
  }

  private var readerSheets: some View {
    readerLoading
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
  }

  private var readerAlerts: some View {
    readerSheets
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

  private func handleFilterChangeTokenUpdate(
    from oldValue: RSSReaderFilterChangeToken,
    to newValue: RSSReaderFilterChangeToken
  ) {
    let filterChanged = oldValue.filterOnly != newValue.filterOnly
    handleFilterChange(
      preservingArticle: oldValue.scope == newValue.scope,
      resetsDisplayLimit: filterChanged,
      resetsTransientState: filterChanged
    )
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

  private func updateReaderLayout(isCompact: Bool) {
    guard isReaderCompact != isCompact else { return }
    isReaderCompact = isCompact
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

  private var selectedReadingFontFamilyBinding: Binding<ReaderFontFamily> {
    Binding(
      get: {
        ReaderFontFamily(rawValue: readingFontFamilyRawValue)
          ?? ReaderTypographyConfiguration.defaultFontFamily
      },
      set: { readingFontFamilyRawValue = $0.rawValue }
    )
  }

  private var selectedReadingTextAlignmentBinding: Binding<ReaderTextAlignment> {
    Binding(
      get: {
        ReaderTextAlignment(rawValue: readingTextAlignmentRawValue)
          ?? ReaderTypographyConfiguration.defaultTextAlignment
      },
      set: { readingTextAlignmentRawValue = $0.rawValue }
    )
  }

  private var selectedReadingCodeHighlightThemeBinding: Binding<ReaderCodeHighlightTheme> {
    Binding(
      get: {
        ReaderCodeHighlightTheme(rawValue: readingCodeHighlightThemeRawValue)
          ?? ReaderTypographyConfiguration.defaultCodeHighlightTheme
      },
      set: { readingCodeHighlightThemeRawValue = $0.rawValue }
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
    initializeReadingProgressRecencyIfNeeded()
    readingProgressSequence &+= 1
    readingProgressRecency[articleID] = readingProgressSequence
    while readingProgressByArticle.count > RSSReadingProgressStore.maximumEntryCount,
      let evictedID = readingProgressRecency.min(by: { $0.value < $1.value })?.key
    {
      readingProgressByArticle.removeValue(forKey: evictedID)
      readingProgressRecency.removeValue(forKey: evictedID)
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
    let recency = readingProgressRecency
    let revision = RSSReadingProgressPersistenceRevision.next()
    readingProgressSaveTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      await RSSReadingProgressPersistence.shared.save(
        values,
        recencyByArticleID: recency,
        revision: revision
      )
      if !Task.isCancelled {
        readingProgressSaveTask = nil
      }
    }
  }

  private func persistReadingProgressAfterDisappear() {
    readingProgressSaveTask?.cancel()
    initializeReadingProgressRecencyIfNeeded()
    let values = readingProgressByArticle
    let recency = readingProgressRecency
    let revision = RSSReadingProgressPersistenceRevision.next()
    readingProgressSaveTask = Task {
      await RSSReadingProgressPersistence.shared.save(
        values,
        recencyByArticleID: recency,
        revision: revision
      )
    }
  }

  private func initializeReadingProgressRecencyIfNeeded() {
    guard readingProgressRecency.isEmpty, !readingProgressByArticle.isEmpty else { return }
    let existingOrder = readingProgressOrder.filter { readingProgressByArticle[$0] != nil }
    var sequence = UInt64(existingOrder.count)
    for (offset, articleID) in existingOrder.enumerated() {
      readingProgressRecency[articleID] = sequence - UInt64(offset)
    }
    for articleID in readingProgressByArticle.keys where readingProgressRecency[articleID] == nil {
      sequence &+= 1
      readingProgressRecency[articleID] = sequence
    }
    readingProgressSequence = max(readingProgressSequence, sequence)
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
          updateReaderLayout(isCompact: !isWide)
        }
        .onChange(of: geometry.size.width) { _, width in
          updateReaderLayout(isCompact: WorkbenchLayoutMode.isCompactRSSReader(width: width))
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
    let isShowingFullText =
      actionArticle.map { presentation.isShowingFullText(for: $0.id) } ?? false
    let isFetchingFullText =
      actionArticle.map { presentation.isFetchingFullText(for: $0.id) } ?? false
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
      readingParagraphSpacing: $readingParagraphSpacing,
      readingFontFamily: selectedReadingFontFamilyBinding,
      readingTextAlignment: selectedReadingTextAlignmentBinding,
      readingCodeHighlightTheme: selectedReadingCodeHighlightThemeBinding,
      readingTheme: selectedReadingThemeBinding,
      readingProgress: selectedReadingProgress,
      onReadingProgress: { progress in
        if let articleID = actionArticle?.id {
          recordReadingProgress(progress, for: articleID)
        }
      },
      onBack: showsBackButton
        ? {
          presentation.selectedArticleID = nil
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
      translationBackend: translationBackendBinding,
      translationTargetCode: $translationTargetCode,
      translationCustomLanguage: $translationCustomLanguage,
      automaticTranslation: $automaticTranslationEnabled,
      isAppleTranslationAvailable: RSSReaderUserPreferences.isAppleTranslationAvailable,
      translationIsRunning: translationIsRunning,
      translationError: translationError,
      dataSharingConsent: workbenchStore.ai.dataSharingConsent,
      onTranslate: { backend in
        guard let actionArticle else { return }
        requestTranslation(for: actionArticle, backend: backend, force: true)
      },
      onClearTranslation: clearSelectedTranslation,
      onOpenAISettings: openAISettings,
      workflowIsBusy: workflowIsBusy,
      isTruncatedCandidate: isTruncated,
      isShowingFullText: isShowingFullText,
      isFetchingFullText: isFetchingFullText,
      fullTextError: fullTextError,
      isOutsideFilteredResults: presentation.isSelectedArticleOutsideMatchingResults(in: store),
      onReturnToResults: presentation.returnToArticleResults,
      automaticFullTextExtraction: $automaticFullTextExtractionEnabled,
      onToggleFullText: {
        guard let actionArticle else { return }
        presentation.toggleFullText(for: actionArticle, store: store)
      },
      onRefreshFullText: {
        guard let actionArticle else { return }
        Task {
          await presentation.fetchFullText(
            for: actionArticle,
            store: store,
            forceRefresh: true
          )
        }
      }
    )
  }

}

private struct RSSUndoToastOverlay: View {
  let canUndoLastDeletion: Bool
  let canUndoLastBatchRead: Bool
  let undoLastDeletion: () -> Void
  let undoLastBatchRead: () -> Void
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  private var isPresented: Bool {
    canUndoLastDeletion || canUndoLastBatchRead
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if isPresented {
        HStack(alignment: .center, spacing: 12) {
          if canUndoLastBatchRead {
            Button("撤销全部已读", action: undoLastBatchRead)
              .buttonStyle(.bordered)
              .accessibilityLabel("撤销上一次批量标记已读")
          }
          if canUndoLastDeletion {
            Button("撤销删除", action: undoLastDeletion)
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
        .padding(16)
        .transition(
          WorkbenchMotion.statusTransition(reduceMotion: accessibilityReduceMotion)
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .animation(
      WorkbenchMotion.animation(
        for: .statusChange,
        reduceMotion: accessibilityReduceMotion
      ),
      value: isPresented
    )
  }
}
