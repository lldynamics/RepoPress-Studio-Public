import AppKit
import PublishingWorkbenchCore
import SwiftUI

// Article loading, reader actions, translation, and knowledge workflows live
// outside the layout root so RSSReaderView remains a composition surface.
extension RSSReaderView {
  var errorAlertBinding: Binding<Bool> {
    Binding(
      get: { presentation.errorMessage != nil },
      set: { isPresented in
        if !isPresented { presentation.errorMessage = nil }
      }
    )
  }

  var selectedArticle: RSSArticle? {
    guard let article = selectedArticlePayload,
      article.id == presentation.selectedArticleID
    else { return nil }
    return article
  }

  var selectedTranslationTarget: RSSArticleTranslationTarget {
    if let preset = RSSArticleTranslationTarget.preset(for: translationTargetCode) {
      return preset
    }
    return RSSArticleTranslationTarget.custom(language: translationCustomLanguage)
      ?? .simplifiedChinese
  }

  var selectedTranslation: RSSArticleTranslationResult? {
    guard let article = selectedArticle else { return nil }
    return translationCache[translationCacheKey(for: article, target: selectedTranslationTarget)]
  }

  var selectedArticleLoadRequest: RSSArticleLoadRequest {
    RSSArticleLoadRequest(
      articleID: presentation.selectedArticleID,
      retryToken: selectedArticleReloadToken,
      articleRevision: selectedArticleHeader?.fetchedAt
    )
  }

  func loadSelectedArticle(_ request: RSSArticleLoadRequest) async {
    guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
    selectedArticleLoadError = nil
    translationRequestID = UUID()
    translationIsRunning = false
    translationError = nil
    guard let articleID = request.articleID else {
      selectedArticlePayload = nil
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

      // Sanitization is CPU-heavy and is also needed by the reader metrics.
      // Compute it once off the main actor and publish the cache before the
      // payload becomes visible to the reader view.
      let bodyMetrics = await Task.detached(priority: .userInitiated) {
        RSSArticleHTMLRenderer.bodyMetrics(article: article)
      }.value
      guard !Task.isCancelled, request == selectedArticleLoadRequest else { return }
      presentation.cacheReaderMetrics(
        for: article,
        hasRenderableBody: bodyMetrics.hasRenderableBody,
        readingUnits: bodyMetrics.readingUnits
      )

      selectedArticlePayload = article
      selectedArticleIsLoading = false
      if automaticFullTextExtractionEnabled && presentation.isTruncatedCandidate(article) {
        Task {
          await presentation.fetchFullText(for: article, store: store)
        }
      }
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

  func translationCacheKey(
    for article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) -> RSSArticleTranslationCacheKey {
    RSSArticleTranslationCacheKey(
      articleID: article.id,
      fetchedAt: article.fetchedAt,
      targetCode: target.languageCode
    )
  }

  func requestTranslation(for article: RSSArticle, force: Bool) {
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

  func clearSelectedTranslation() {
    guard let article = selectedArticle else { return }
    translationRequestID = UUID()
    translationIsRunning = false
    translationError = nil
    translationCache.removeValue(
      forKey: translationCacheKey(for: article, target: selectedTranslationTarget)
    )
  }

  func openAISettings() {
    let destination: SettingsDestination =
      workbenchStore.ai.dataSharingConsent.destinationState == .unconfigured
      ? .ai(.connection)
      : .ai(.credentials)
    requestedSettingsTabID = destination.id
    openSettings()
  }

  var selectedArticleHeader: RSSArticleHeader? {
    presentation.articleHeader(id: presentation.selectedArticleID, in: store)
  }

  var selectedFeedTitle: String? {
    guard let article = selectedArticleHeader else { return nil }
    return store.feeds.first { $0.id == article.feedID }?.displayTitle
  }

  var selectedFeed: RSSFeed? {
    guard let article = selectedArticleHeader else { return nil }
    return store.feeds.first { $0.id == article.feedID }
  }

  var readerCommandActions: RSSReaderCommandActions? {
    RSSReaderCommandActions(
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

  func selectRelativeArticle(_ offset: Int) {
    guard let article = relativeArticle(offset: offset) else { return }
    presentation.revealArticle(article.id, in: store)
    presentation.selectedArticleID = article.id
  }

  func toggleSelectedArticleStarred() {
    guard let article = selectedArticleHeader else { return }
    let nextValue = !article.isStarred
    store.toggleStarred(article.id)
    selectedArticlePayload?.isStarred = nextValue
  }

  func toggleSelectedArticleRead() {
    guard let article = selectedArticleHeader else { return }
    let nextValue = !article.isRead
    store.markRead(article.id, isRead: nextValue)
    selectedArticlePayload?.readAt = store.articleHeader(id: article.id)?.readAt
  }

  func markArticleReadFromProgress(_ articleID: String) {
    guard let header = store.articleHeader(id: articleID),
      !header.isRead,
      selectedArticlePayload?.id == articleID
    else {
      return
    }
    store.markRead(articleID)
    selectedArticlePayload?.readAt = store.articleHeader(id: articleID)?.readAt
  }

  func relativeArticle(offset: Int) -> RSSArticleHeader? {
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

  func openOriginal() {
    guard let link = selectedArticleHeader?.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      workflowMessage = message
    }
  }

  func openOriginal(_ article: RSSArticleHeader) {
    guard let link = article.link else { return }
    _ = ExternalURLOpener.open(link) { message in
      presentation.errorMessage = message
    }
  }

  func beginHighlight(withNote: Bool) {
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

  func saveHighlight(_ draft: RSSHighlightDraft, note: String, tags: [String]) {
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

  func saveToKnowledge(_ article: RSSArticle) {
    runWorkflow(
      for: article,
      success: String(localized: "已保存到资料库；资料仅保存在本机。")
    ) { article, knowledge in
      _ = try await Self.importArticle(article, into: knowledge)
    }
  }

  func saveArticlesToKnowledge(_ articleIDs: [String]) {
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

  func saveExcerptNote(for article: RSSArticle, excerpt: String, note: String) {
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
        highlightedText: String(
          excerpt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)),
        note: note.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      guard knowledge.saveAnnotation(annotation) else {
        throw RSSReaderError.persistence("资料标注保存失败")
      }
    }
  }

  func insertReference(_ article: RSSArticle) {
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
      guard
        KnowledgeArticleInsertionService.insertRSSReference(
          article: article,
          summary: RSSArticleWorkflow.summary(for: article),
          excerpt: excerpt,
          citation: citation,
          into: workbenchStore
        )
      else {
        throw RSSReaderError.persistence("当前文章未能写入引用")
      }
    }
  }

  func createInspirationDraft(_ article: RSSArticle) {
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
      guard
        KnowledgeArticleInsertionService.insertRSSReference(
          article: article,
          summary: RSSArticleWorkflow.summary(for: article),
          excerpt: excerpt,
          citation: citation,
          appendingFootnote: true,
          into: workbenchStore
        )
      else {
        throw RSSReaderError.persistence("灵感草稿未能写入引用和脚注")
      }
    }
  }

  func runWorkflow(
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

  static func importArticle(
    _ article: RSSArticle,
    into knowledge: KnowledgeStore
  ) async throws -> KnowledgeDocument {
    let preview = try await knowledge.makeRSSImportPreview(article: article)
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
