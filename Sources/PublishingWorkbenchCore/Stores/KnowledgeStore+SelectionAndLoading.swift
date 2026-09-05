import Combine
import Foundation

@MainActor
extension KnowledgeStore {
  public func reload(selecting preferredDocumentID: UUID? = nil) async {
    if let startupReloadTask {
      await startupReloadTask.value
    }
    await performReload(selecting: preferredDocumentID)
  }

  /// A mutation that has already crossed the persistence boundary must still
  /// publish its authoritative projection when the UI task that initiated it
  /// is cancelled. Detached here is deliberate: ordinary user-triggered
  /// reloads remain cooperatively cancellable, while this repair read neither
  /// inherits cancellation nor re-enters the mutation tail.
  func reloadAfterAcceptedMutation(selecting preferredDocumentID: UUID? = nil) async {
    let reloadTask = Task.detached { [weak self] in
      await self?.performReload(selecting: preferredDocumentID)
    }
    await reloadTask.value
  }

  func performReload(selecting preferredDocumentID: UUID? = nil) async {
    let busyOperationID = beginBusyOperation()
    defer { finishBusyOperation(busyOperationID) }
    while true {
      let snapshotGeneration = currentKnowledgeMutationGeneration()
      await flushKnowledgeMutations()
      guard snapshotGeneration == currentKnowledgeMutationGeneration() else { continue }
      do {
        async let loadedDocuments = service.documentsAsync()
        async let loadedRecycledDocuments = service.recycledDocumentsAsync()
        async let loadedFolders = service.foldersAsync()
        async let loadedPinnedDocumentIDs = service.pinnedDocumentIDsAsync()
        let snapshot = try await (
          loadedDocuments,
          loadedRecycledDocuments,
          loadedFolders,
          loadedPinnedDocumentIDs
        )
        // A write accepted while the SQLite snapshot was being read wins. Do
        // not publish an older result over that future mutation's state.
        guard snapshotGeneration == currentKnowledgeMutationGeneration() else { continue }
        documents = snapshot.0
        recycledDocuments = snapshot.1
        folders = snapshot.2
        pinnedDocumentIDs = snapshot.3
        if case .folder(let folderID) = folderScope,
          !folders.contains(where: { $0.id == folderID })
        {
          folderScope = .all
        }
        if case .smartCollection(let rule) = folderScope,
          !smartCollections.contains(where: { $0.rule == rule })
        {
          folderScope = .all
        }
        lastError = nil
        let nextSelection = preferredDocumentID ?? selectedDocumentID
        if let nextSelection, visibleDocuments.contains(where: { $0.id == nextSelection }) {
          selectDocument(nextSelection)
        } else {
          selectDocument(visibleDocuments.first?.id)
        }
        return
      } catch {
        lastError = error.localizedDescription
        statusMessage = "资料库读取失败：\(error.localizedDescription)"
        return
      }
    }
  }

  public func retryLastImport() async {
    guard let lastImportRetryAction else {
      statusMessage = "当前没有可重试的资料导入任务。"
      return
    }
    await lastImportRetryAction()
  }

  func beginImport(
    title: String,
    retry: @escaping @MainActor () async -> Void
  ) {
    isImporting = true
    importProgress = 0
    importOperationTitle = title
    lastImportFailure = nil
    lastImportRetryAction = retry
  }

  func finishImport(failure: String? = nil) {
    isImporting = false
    importProgress = failure == nil ? 1 : nil
    lastImportFailure = failure
  }

  public func selectDocument(_ documentID: UUID?) {
    selectedSearchResult = nil
    selectedResultQuery = ""
    loadDocument(documentID)
    loadRelatedChapters(documentID: documentID, anchorChunkID: nil)
    loadDocumentInsights(documentID: documentID)
  }

  @discardableResult
  public func revealDocument(_ documentID: UUID) -> Bool {
    guard documents.contains(where: { $0.id == documentID }) else {
      statusMessage = "资料库中找不到要打开的资料。"
      return false
    }
    searchTask?.cancel()
    searchText = ""
    searchResults = []
    isSearching = false
    folderScope = .all
    selectDocument(documentID)
    statusMessage = "已从浏览器打开保存的资料。"
    return true
  }

  public func selectSearchResult(_ result: KnowledgeSearchResult) {
    selectedSearchResult = result
    selectedResultQuery = searchText
    loadDocument(result.document.id)
    loadRelatedChapters(documentID: result.document.id, anchorChunkID: result.chunk.id)
    loadDocumentInsights(documentID: result.document.id)
    let location =
      result.chunk.locator?.nilIfEmpty
      ?? result.chunk.headingPath?.nilIfEmpty
      ?? "正文段落"
    statusMessage = "已定位到“\(result.document.title)”的\(location)。"
  }

  /// Clears the transient search-hit anchor while leaving the document that
  /// was already loaded for reading selected. This mirrors a normal list
  /// deselection: the detail stays available, but no stale result remains
  /// highlighted in the search list or inspector.
  @discardableResult
  public func clearSearchResultSelection() -> Bool {
    guard selectedSearchResult != nil else { return false }
    selectedSearchResult = nil
    selectedResultQuery = ""
    statusMessage = CoreL10n.text("已取消搜索命中的高亮，继续显示已加载的资料。")
    return true
  }

  @discardableResult
  public func selectCitation(_ citation: KnowledgeCitation) -> Bool {
    guard let document = documents.first(where: { $0.id == citation.documentID }) else {
      statusMessage = "资料库中找不到引用来源“\(citation.title)”。"
      return false
    }

    let chunk = KnowledgeChunk(
      id: citation.chunkID,
      documentID: citation.documentID,
      revisionID: UUID(),
      ordinal: 0,
      locator: citation.locator,
      content: citation.excerpt,
      tokenEstimate: max(1, citation.excerpt.count / 3),
      contentHash: KnowledgeChunkingService.contentHash(for: Data(citation.excerpt.utf8))
    )
    selectedSearchResult = KnowledgeSearchResult(
      document: document,
      chunk: chunk,
      score: 1,
      signals: [.fullText]
    )
    selectedResultQuery = citation.excerpt
    loadDocument(document.id)
    loadRelatedChapters(documentID: document.id, anchorChunkID: citation.chunkID)
    loadDocumentInsights(documentID: document.id)
    statusMessage = "已打开引用来源：\(document.title) · \(citation.locator?.nilIfEmpty ?? "正文段落")。"
    return true
  }

  public func selectRelatedChapter(_ recommendation: KnowledgeRelatedChapter) {
    let signals: Set<KnowledgeRetrievalSignal> =
      recommendation.reasons.contains(.semantic)
      ? [.semantic]
      : []
    selectedSearchResult = KnowledgeSearchResult(
      document: recommendation.document,
      chunk: recommendation.chunk,
      score: recommendation.score,
      signals: signals
    )
    selectedResultQuery = ""
    loadDocument(recommendation.document.id)
    loadRelatedChapters(
      documentID: recommendation.document.id,
      anchorChunkID: recommendation.chunk.id
    )
    loadDocumentInsights(documentID: recommendation.document.id)
    let location =
      recommendation.chunk.locator?.nilIfEmpty
      ?? recommendation.chunk.headingPath?.nilIfEmpty
      ?? "相关段落"
    statusMessage = "已打开关联推荐：\(recommendation.document.title) · \(location)。"
  }

  public func searchResult(id: UUID) -> KnowledgeSearchResult? {
    visibleSearchResults.first { $0.id == id }
  }

  /// Returns a citation backed by a real indexed chunk when one can be found.
  /// Callers may still use their own clipped excerpt for presentation, but the
  /// chunk identity keeps backlinks valid instead of inventing an orphan ID.
  public func makeCitationForDocument(
    documentID: UUID,
    excerpt: String
  ) async -> KnowledgeCitation? {
    let trimmedExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedExcerpt.isEmpty,
          let document = documents.first(where: { $0.id == documentID })
    else { return nil }

    let query = String(trimmedExcerpt.prefix(240))
    do {
      let result = try await service.searchAsync(
        query: query,
        limit: 12,
        documentIDs: Set([documentID]),
        requiredSignal: .fullText
      ).first { $0.document.id == documentID }
      guard let result else { return nil }
      return KnowledgeCitation(
        id: "\(document.id.uuidString.prefix(8))-\(result.chunk.id.uuidString.prefix(8))",
        documentID: document.id,
        chunkID: result.chunk.id,
        title: document.title,
        authors: document.authors,
        locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
        excerpt: trimmedExcerpt,
        sourceURL: document.sourceURL
      )
    } catch {
      return nil
    }
  }

  func loadDocument(_ documentID: UUID?) {
    if selectedDocumentID == documentID,
      documentID != nil,
      !selectedDocumentText.isEmpty
    {
      return
    }
    selectedDocumentID = documentID
    selectedDocumentText = ""
    selectedDocumentTextError = nil
    selectedDocumentCapturedText = nil
    selectedDocumentCapturedTextError = nil
    selectedTextTask?.cancel()
    selectedCapturedTextTask?.cancel()
    guard let documentID else {
      isLoadingSelectedDocumentText = false
      isLoadingSelectedDocumentCapturedText = false
      return
    }
    isLoadingSelectedDocumentText = true
    let documentKind = documents.first(where: { $0.id == documentID })?.kind
    let service = self.service
    selectedTextTask = Task { [weak self] in
      do {
        let text = try await service.normalizedTextAsync(documentID: documentID)
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.selectedDocumentText =
          documentKind == .webpage
          ? KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)
          : text
        self?.isLoadingSelectedDocumentText = false
        self?.selectedDocumentTextError = nil
      } catch {
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.isLoadingSelectedDocumentText = false
        self?.selectedDocumentTextError = error.localizedDescription
        self?.lastError = error.localizedDescription
      }
    }
    guard documentKind == .webpage || documentKind == .image else {
      isLoadingSelectedDocumentCapturedText = false
      return
    }
    isLoadingSelectedDocumentCapturedText = true
    selectedCapturedTextTask = Task { [weak self] in
      do {
        let text = try await service.capturedTextAsync(documentID: documentID)
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.selectedDocumentCapturedText = text
        self?.isLoadingSelectedDocumentCapturedText = false
        self?.selectedDocumentCapturedTextError = nil
      } catch {
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.isLoadingSelectedDocumentCapturedText = false
        self?.selectedDocumentCapturedTextError = error.localizedDescription
      }
    }
  }

  func loadRelatedChapters(documentID: UUID?, anchorChunkID: UUID?) {
    relatedChaptersTask?.cancel()
    relatedChapters = []
    guard let documentID else {
      isLoadingRelatedChapters = false
      return
    }
    isLoadingRelatedChapters = true
    let service = self.service
    relatedChaptersTask = Task { [weak self] in
      do {
        let recommendations = try await service.relatedChaptersAsync(
          documentID: documentID,
          anchorChunkID: anchorChunkID,
          limit: 8
        )
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.relatedChapters = recommendations
        self?.isLoadingRelatedChapters = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.relatedChapters = []
        self?.isLoadingRelatedChapters = false
        self?.lastError = error.localizedDescription
      }
    }
  }

  public func loadDocumentInsights(documentID: UUID?) {
    documentInsightsTask?.cancel()
    annotations = []
    backlinks = []
    revisions = []
    guard let documentID else { return }
    let service = self.service
    documentInsightsTask = Task { [weak self] in
      do {
        async let loadedAnnotations = service.annotationsAsync(documentID: documentID)
        async let loadedBacklinks = service.backlinksAsync(documentID: documentID)
        async let loadedRevisions = service.revisionsAsync(documentID: documentID)
        let loaded = try await (loadedAnnotations, loadedBacklinks, loadedRevisions)
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.annotations = loaded.0
        self?.backlinks = loaded.1
        self?.revisions = loaded.2
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.lastError = error.localizedDescription
      }
    }
  }

  /// Loads the knowledge sources cited by one article. This is the reverse
  /// direction of `backlinks(documentID:)`, which is used by the library
  /// inspector to show where a source was cited.
  public func loadArticleBacklinks(for draftID: UUID?) {
    articleBacklinksTask?.cancel()
    articleBacklinks = []
    isLoadingArticleBacklinks = false
    guard let draftID else {
      articleBacklinksTargetID = nil
      return
    }

    let targetID = draftID.uuidString
    articleBacklinksTargetID = targetID
    isLoadingArticleBacklinks = true
    let service = self.service
    articleBacklinksTask = Task { [weak self] in
      do {
        let loaded = try await service.backlinksAsync(
          targetKind: .articleDraft,
          targetID: targetID
        )
        guard !Task.isCancelled, self?.articleBacklinksTargetID == targetID else { return }
        self?.articleBacklinks = loaded
        self?.isLoadingArticleBacklinks = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.articleBacklinksTargetID == targetID else { return }
        self?.articleBacklinks = []
        self?.isLoadingArticleBacklinks = false
        self?.lastError = error.localizedDescription
      }
    }
  }
}
