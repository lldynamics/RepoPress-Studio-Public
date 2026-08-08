import AppKit
import PublishingWorkbenchCore
import SwiftUI



struct RSSReaderView: View {
  @ObservedObject var store: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @Environment(\.openSettings) private var openSettings
  @State private var excerptNoteArticle: RSSArticle?
  @State private var highlightDraft: RSSHighlightDraft?
  @State private var tagEditorArticle: RSSArticle?
  @State private var selectedReaderText = ""
  @State private var allowRemoteImages = true
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
    .focusedSceneValue(\.rssReaderCommandActions, readerCommandActions)
    .onAppear {
      presentation.synchronizeSelection(in: store)
    }
    .onDisappear {
      persistReadingProgressAfterDisappear()
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
    let previousProgress = readingProgressByArticle[articleID]
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

    if RSSReadingCompletionPolicy.didCrossCompletionThreshold(
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

      let feedTitle = selectedFeedTitle
      let readingMinutes = RSSArticleHTMLRenderer.bodyMetrics(article: article).readingUnits
      let allowRemote = allowRemoteImages
      let fontSize = readingFontSize
      let lineSpacing = readingLineSpacing
      let theme = selectedReadingTheme
      let progress = selectedReadingProgress

      Task.detached(priority: .userInitiated) {
        _ = RSSArticleHTMLRenderer.render(
          article: article,
          feedTitle: feedTitle,
          readingMinutes: readingMinutes,
          allowRemoteImages: allowRemote,
          fontSize: fontSize,
          lineSpacing: lineSpacing,
          theme: theme,
          initialReadingProgress: progress
        )
      }

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
    let destination: SettingsDestination =
      workbenchStore.ai.dataSharingConsent.destinationState == .unconfigured
      ? .ai(.connection)
      : .ai(.credentials)
    requestedSettingsTabID = destination.id
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
            presentation.requestSearchFocus()
          }
        } else {
          presentation.requestSearchFocus()
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
    selectedArticlePayload?.readAt = store.articleHeader(id: article.id)?.readAt
  }

  private func markArticleReadFromProgress(_ articleID: String) {
    guard let header = store.articleHeader(id: articleID),
          !header.isRead,
          selectedArticlePayload?.id == articleID
    else {
      return
    }
    store.markRead(articleID)
    selectedArticlePayload?.readAt = store.articleHeader(id: articleID)?.readAt
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
