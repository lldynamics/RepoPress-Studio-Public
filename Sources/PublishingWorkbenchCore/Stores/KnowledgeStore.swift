import Combine
import Foundation

@MainActor
public final class KnowledgeStore: ObservableObject {
  private let service: KnowledgeLibraryService
  private let smartCollectionService = KnowledgeSmartCollectionService()
  private var searchTask: Task<Void, Never>?
  private var selectedTextTask: Task<Void, Never>?
  private var relatedChaptersTask: Task<Void, Never>?
  private var documentInsightsTask: Task<Void, Never>?

  @Published public private(set) var documents: [KnowledgeDocument] = []
  @Published public private(set) var recycledDocuments: [KnowledgeRecycledDocument] = []
  @Published public private(set) var folders: [KnowledgeFolder] = []
  @Published public private(set) var searchResults: [KnowledgeSearchResult] = []
  @Published public private(set) var selectedSearchResult: KnowledgeSearchResult?
  @Published public private(set) var selectedResultQuery = ""
  @Published public var selectedDocumentID: UUID?
  @Published public private(set) var folderScope: KnowledgeFolderScope = .all
  @Published public private(set) var documentSort = KnowledgeDocumentSort()
  @Published public private(set) var searchFilter = KnowledgeSearchFilter()
  @Published public private(set) var selectedDocumentText = ""
  @Published public private(set) var isLoadingSelectedDocumentText = false
  @Published public private(set) var selectedDocumentTextError: String?
  @Published public private(set) var searchText = ""
  @Published public private(set) var isSearching = false
  @Published public private(set) var isBusy = false
  @Published public private(set) var statusMessage: String?
  @Published public private(set) var lastError: String?
  @Published public private(set) var pinnedDocumentIDs: Set<UUID> = []
  @Published public private(set) var relatedChapters: [KnowledgeRelatedChapter] = []
  @Published public private(set) var isLoadingRelatedChapters = false
  @Published public private(set) var annotations: [KnowledgeAnnotation] = []
  @Published public private(set) var backlinks: [KnowledgeBacklink] = []
  @Published public private(set) var revisions: [KnowledgeDocumentRevision] = []
  @Published public private(set) var healthSnapshot: KnowledgeLibraryHealthSnapshot?
  @Published public private(set) var isLoadingHealth = false

  public init(service: KnowledgeLibraryService = KnowledgeLibraryService()) {
    self.service = service
    Task { await reload() }
  }

  deinit {
    searchTask?.cancel()
    selectedTextTask?.cancel()
    relatedChaptersTask?.cancel()
    documentInsightsTask?.cancel()
  }

  public var selectedDocument: KnowledgeDocument? {
    guard let selectedDocumentID else { return nil }
    return documents.first { $0.id == selectedDocumentID }
  }

  public var smartCollections: [KnowledgeSmartCollection] {
    smartCollectionService.collections(for: documents)
  }

  public var backlinkGroups: [KnowledgeBacklinkGroup] {
    Dictionary(grouping: backlinks) { backlink in
      "\(backlink.targetKind.rawValue):\(backlink.targetID)"
    }
    .values
    .compactMap(KnowledgeBacklinkGroup.init(backlinks:))
    .sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id < $1.id
    }
  }

  public func smartCollections(
    kind: KnowledgeSmartCollectionKind
  ) -> [KnowledgeSmartCollection] {
    smartCollections.filter { $0.rule.kind == kind }
  }

  public func smartCollection(
    rule: KnowledgeSmartCollectionRule
  ) -> KnowledgeSmartCollection? {
    smartCollections.first { $0.rule == rule }
  }

  public var visibleDocuments: [KnowledgeDocument] {
    let candidates: [KnowledgeDocument]
    if searchText.trimmedForPublishing.isEmpty {
      candidates = documents
    } else {
      var seen = Set<UUID>()
      candidates = visibleSearchResults.compactMap { result in
        seen.insert(result.document.id).inserted ? result.document : nil
      }
    }
    let filtered = searchText.trimmedForPublishing.isEmpty
      ? candidates.filter(isIncludedInCurrentScope)
      : candidates
    return documentSort.sorted(filtered)
  }

  public var visibleSearchResults: [KnowledgeSearchResult] {
    searchFilter.filtered(searchResults, isInCurrentCollection: isIncludedInCurrentScope)
  }

  public func reload(selecting preferredDocumentID: UUID? = nil) async {
    isBusy = true
    defer { isBusy = false }
    do {
      async let loadedDocuments = service.documentsAsync()
      async let loadedRecycledDocuments = service.recycledDocumentsAsync()
      async let loadedFolders = service.foldersAsync()
      async let loadedPinnedDocumentIDs = service.pinnedDocumentIDsAsync()
      documents = try await loadedDocuments
      recycledDocuments = try await loadedRecycledDocuments
      folders = try await loadedFolders
      pinnedDocumentIDs = try await loadedPinnedDocumentIDs
      if case .folder(let folderID) = folderScope,
         !folders.contains(where: { $0.id == folderID }) {
        folderScope = .all
      }
      if case .smartCollection(let rule) = folderScope,
         !smartCollections.contains(where: { $0.rule == rule }) {
        folderScope = .all
      }
      lastError = nil
      let nextSelection = preferredDocumentID ?? selectedDocumentID
      if let nextSelection, visibleDocuments.contains(where: { $0.id == nextSelection }) {
        selectDocument(nextSelection)
      } else {
        selectDocument(visibleDocuments.first?.id)
      }
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库读取失败：\(error.localizedDescription)"
    }
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
    let location = result.chunk.locator?.nilIfEmpty
      ?? result.chunk.headingPath?.nilIfEmpty
      ?? "正文段落"
    statusMessage = "已定位到“\(result.document.title)”的\(location)。"
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
    let signals: Set<KnowledgeRetrievalSignal> = recommendation.reasons.contains(.semantic)
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
    let location = recommendation.chunk.locator?.nilIfEmpty
      ?? recommendation.chunk.headingPath?.nilIfEmpty
      ?? "相关段落"
    statusMessage = "已打开关联推荐：\(recommendation.document.title) · \(location)。"
  }

  public func searchResult(id: UUID) -> KnowledgeSearchResult? {
    visibleSearchResults.first { $0.id == id }
  }

  private func loadDocument(_ documentID: UUID?) {
    if selectedDocumentID == documentID,
       documentID != nil,
       !selectedDocumentText.isEmpty {
      return
    }
    selectedDocumentID = documentID
    selectedDocumentText = ""
    selectedDocumentTextError = nil
    selectedTextTask?.cancel()
    guard let documentID else {
      isLoadingSelectedDocumentText = false
      return
    }
    isLoadingSelectedDocumentText = true
    let documentKind = documents.first(where: { $0.id == documentID })?.kind
    let service = self.service
    selectedTextTask = Task { [weak self] in
      do {
        let text = try await service.normalizedTextAsync(documentID: documentID)
        guard !Task.isCancelled, self?.selectedDocumentID == documentID else { return }
        self?.selectedDocumentText = documentKind == .webpage
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
  }

  private func loadRelatedChapters(documentID: UUID?, anchorChunkID: UUID?) {
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
        let loaded = try await Task.detached(priority: .utility) {
          (
            try service.annotations(documentID: documentID),
            try service.backlinks(documentID: documentID),
            try service.revisions(documentID: documentID)
          )
        }.value
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

  public func updateSearchText(_ value: String) {
    searchText = value
    selectedSearchResult = nil
    selectedResultQuery = ""
    searchTask?.cancel()
    let query = value.trimmedForPublishing
    guard !query.isEmpty else {
      searchResults = []
      isSearching = false
      statusMessage = "已清除资料搜索，显示 \(visibleDocuments.count) 条资料。"
      return
    }

    searchResults = []
    isSearching = true
    let service = self.service
    let searchScope = searchFilter.scope
    let requiredSignal = searchFilter.signal.signal
    let documentIDs: Set<UUID>? = searchScope == .currentCollection
      ? Set(documents.filter(isIncludedInCurrentScope).map(\.id))
      : nil
    searchTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(180))
        let results = try await service.searchAsync(
          query: query,
          limit: 80,
          documentIDs: documentIDs,
          requiredSignal: requiredSignal
        )
        guard !Task.isCancelled,
              self?.searchText.trimmedForPublishing == query,
              self?.searchFilter.scope == searchScope,
              self?.searchFilter.signal.signal == requiredSignal else { return }
        self?.searchResults = results
        self?.isSearching = false
        let semanticCount = results.filter { $0.signals.contains(.semantic) }.count
        let documentCount = Set(results.map { $0.document.id }).count
        self?.statusMessage = results.isEmpty
          ? "全文与本地语义检索均未找到相关资料。"
          : "混合检索显示 \(documentCount) 条资料、\(results.count) 个片段，其中 \(semanticCount) 个获得语义召回。"
        self?.lastError = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.searchText.trimmedForPublishing == query else { return }
        self?.isSearching = false
        self?.lastError = error.localizedDescription
        self?.statusMessage = "资料库检索失败：\(error.localizedDescription)"
      }
    }
  }

  public func setFolderScope(_ scope: KnowledgeFolderScope) {
    folderScope = scope
    if searchFilter.scope == .currentCollection,
       !searchText.trimmedForPublishing.isEmpty {
      updateSearchText(searchText)
    }
    ensureVisibleSelection()
  }

  public func setSearchScope(_ scope: KnowledgeSearchScope) {
    searchFilter.scope = scope
    if !searchText.trimmedForPublishing.isEmpty {
      updateSearchText(searchText)
    }
    ensureVisibleSelection()
  }

  public func setSearchSignalFilter(_ signal: KnowledgeSearchSignalFilter) {
    searchFilter.signal = signal
    if !searchText.trimmedForPublishing.isEmpty {
      updateSearchText(searchText)
    }
    ensureVisibleSelection()
  }

  public func setSearchResultSort(_ sort: KnowledgeSearchResultSort) {
    searchFilter.sort = sort
    ensureVisibleSelection()
  }

  public func documentCount(for collection: KnowledgeSavedCollection) -> Int {
    documents.count {
      smartCollectionService.matches(
        $0,
        rules: collection.rules,
        matchMode: collection.matchMode
      )
    }
  }

  public func setDocumentSortField(_ field: KnowledgeDocumentSortField) {
    var updated = documentSort
    updated.field = field
    documentSort = updated
  }

  public func setDocumentSortDirection(_ direction: KnowledgeSortDirection) {
    var updated = documentSort
    updated.direction = direction
    documentSort = updated
  }

  public func folder(id: UUID?) -> KnowledgeFolder? {
    guard let id else { return nil }
    return folders.first { $0.id == id }
  }

  public func createFolder(name: String) {
    do {
      let folder = try service.createFolder(name: name)
      folders.append(folder)
      folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      folderScope = .folder(folder.id)
      ensureVisibleSelection()
      statusMessage = "已创建资料文件夹“\(folder.name)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "新建文件夹失败：\(error.localizedDescription)"
    }
  }

  public func renameFolder(id: UUID, name: String) {
    do {
      _ = try service.renameFolder(id: id, name: name)
      folders = try service.folders()
      statusMessage = "资料文件夹已重命名。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "重命名失败：\(error.localizedDescription)"
    }
  }

  public func deleteFolder(id: UUID) {
    do {
      let name = folder(id: id)?.name ?? "文件夹"
      try service.deleteFolder(id: id)
      folders.removeAll { $0.id == id }
      for index in documents.indices where documents[index].folderID == id {
        documents[index].folderID = nil
      }
      searchResults = searchResults.map { result in
        guard result.document.folderID == id else { return result }
        var updated = result
        updated.document.folderID = nil
        return updated
      }
      if folderScope == .folder(id) {
        folderScope = .unfiled
      }
      ensureVisibleSelection()
      statusMessage = "已删除“\(name)”，其中资料已移到未分类。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "删除文件夹失败：\(error.localizedDescription)"
    }
  }

  public func moveDocument(_ documentID: UUID, to folderID: UUID?) {
    do {
      try service.setFolder(folderID, documentID: documentID)
      let now = Date()
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].folderID = folderID
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.folderID = folderID
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      let destination = folder(id: folderID)?.name ?? "未分类"
      statusMessage = "资料已移到“\(destination)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "移动资料失败：\(error.localizedDescription)"
    }
  }

  public func moveDocuments(_ documentIDs: Set<UUID>, to folderID: UUID?) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setFolder(folderID, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].folderID = folderID
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.folderID = folderID
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      let destination = folder(id: folderID)?.name ?? "未分类"
      statusMessage = "已将 \(documentIDs.count) 条资料移到“\(destination)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量移动失败：\(error.localizedDescription)"
    }
  }

  public func addTags(_ tags: [String], to documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.addTags(tags, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        for tag in tags.map({ $0.trimmedForPublishing }).filter({ !$0.isEmpty }) where
          !documents[index].tags.contains(where: {
            $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
          }) {
          documents[index].tags.append(tag)
        }
        documents[index].updatedAt = now
      }
      searchResults = []
      if !searchText.trimmedForPublishing.isEmpty { updateSearchText(searchText) }
      ensureVisibleSelection()
      statusMessage = "已为 \(documentIDs.count) 条资料添加标签。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量添加标签失败：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func updateMetadata(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) -> Bool {
    do {
      let updatedDocument = try service.updateMetadata(
        documentID: documentID,
        metadata: metadata
      )
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index] = updatedDocument
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document = updatedDocument
        return updated
      }
      ensureVisibleSelection()
      statusMessage = "资料元数据已保存，并已更新全文与语义索引。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "元数据保存失败：\(error.localizedDescription)"
      return false
    }
  }

  public func makeImportPreview(
    sourceURL: URL,
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    statusMessage = "正在分析资料…"
    do {
      let preview = try await service.makeImportPreview(sourceURL: sourceURL, options: options)
      statusMessage = "资料预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料分析失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func makeImportPreview(
    sourceURLs: [URL],
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    statusMessage = "正在分析拖入的资料…"
    do {
      let preview = try await service.makeImportPreview(
        sourceURLs: sourceURLs,
        options: options
      )
      statusMessage = "拖放资料预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "拖放资料分析失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func makeWebImportPreview(url: URL) async throws -> KnowledgeImportPreview {
    statusMessage = "正在读取网页…"
    do {
      let preview = try await service.makeWebImportPreview(url: url)
      statusMessage = "网页预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "网页读取失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func commit(
    _ preview: KnowledgeImportPreview,
    destination: KnowledgeImportDestination = .preserveExisting
  ) async throws -> KnowledgeImportResult {
    isBusy = true
    statusMessage = "正在保存并建立索引…"
    defer { isBusy = false }
    do {
      let result = try await service.commit(preview, destination: destination)
      await reload()
      statusMessage = "资料导入完成：新增 \(result.insertedCount)，更新 \(result.updatedCount)，跳过 \(result.skippedCount)。"
      lastError = nil
      return result
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料导入失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func importBrowserCapture(
    _ capture: KnowledgeBrowserCapture,
    folderID: UUID?,
    newFolderName: String?,
    duplicateResolution: KnowledgeBrowserDuplicateResolution? = nil
  ) async throws -> KnowledgeBrowserImportOutcome {
    isBusy = true
    statusMessage = "正在保存浏览器页面并建立索引…"
    defer { isBusy = false }
    do {
      var preview = try await service.makeBrowserImportPreview(capture: capture)
      guard var candidate = preview.candidates.first else {
        throw KnowledgeLibraryError.invalidBrowserCapture("浏览器页面没有可保存的内容。")
      }
      let currentDocuments = try service.documents()
      let currentFolders = try service.folders()
      let existingDocument = candidate.existingDocumentID.flatMap { documentID in
        currentDocuments.first(where: { $0.id == documentID })
      }
      let hasSameURL = existingDocument?.sourceURL?.absoluteString == candidate.sourceURL?.absoluteString
      if let existingDocument, hasSameURL, duplicateResolution == nil {
        let existingFolder = existingDocument.folderID.flatMap { existingFolderID in
          currentFolders.first(where: { $0.id == existingFolderID })
        }
        statusMessage = "检测到同网址资料，请选择处理方式。"
        lastError = nil
        return .requiresDuplicateResolution(KnowledgeBrowserDuplicateConflict(
          document: existingDocument,
          folder: existingFolder,
          incomingHasChanges: candidate.disposition == .update
        ))
      }

      let destination = try browserImportDestination(
        folderID: folderID,
        newFolderName: newFolderName
      )
      let result: KnowledgeImportResult
      let action: KnowledgeBrowserImportAction
      if let existingDocument, hasSameURL, duplicateResolution == .moveOnly {
        try service.setFolder(destination.folderID, documentID: existingDocument.id)
        result = KnowledgeImportResult(
          insertedCount: 0,
          updatedCount: 0,
          skippedCount: 0,
          documentIDs: [existingDocument.id]
        )
        action = .moved
      } else {
        if let existingDocument, hasSameURL, duplicateResolution == .saveNewVersion {
          candidate.existingDocumentID = existingDocument.id
          candidate.disposition = .update
        } else if hasSameURL, duplicateResolution == .keepCopy {
          candidate.existingDocumentID = nil
          candidate.disposition = .new
          candidate.title = "\(candidate.title)（副本）"
        }
        preview.candidates = [candidate]
        result = try await service.commit(preview, destination: destination.importDestination)
        if duplicateResolution == .keepCopy, hasSameURL {
          action = .copied
        } else if result.insertedCount > 0 {
          action = .inserted
        } else if result.updatedCount > 0 {
          action = .updated
        } else {
          action = .existing
        }
      }
      if let allowsAIUse = capture.allowsAIUse {
        for documentID in result.documentIDs {
          try service.setAllowsAIUse(allowsAIUse, documentID: documentID)
        }
      }
      await reload(selecting: result.documentIDs.first)
      statusMessage = action == .moved
        ? "已将原资料移到选定分类，没有创建新版本。"
        : "浏览器页面已保存到资料库。"
      lastError = nil
      return .saved(result: result, action: action)
    } catch {
      lastError = error.localizedDescription
      statusMessage = "浏览器页面保存失败：\(error.localizedDescription)"
      throw error
    }
  }

  private func browserImportDestination(
    folderID: UUID?,
    newFolderName: String?
  ) throws -> (importDestination: KnowledgeImportDestination, folderID: UUID?) {
    if let requestedName = newFolderName?.trimmedForPublishing.nilIfEmpty {
      if let existing = try service.folders().first(where: {
        $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }) {
        return (.folder(existing.id), existing.id)
      }
      let folder = try service.createFolder(name: requestedName)
      return (.folder(folder.id), folder.id)
    }
    if let folderID {
      return (.folder(folderID), folderID)
    }
    return (.unfiled, nil)
  }

  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) {
    do {
      try service.setAllowsAIUse(allowsAIUse, documentID: documentID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].allowsAIUse = allowsAIUse
        documents[index].updatedAt = Date()
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.allowsAIUse = allowsAIUse
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsAIUse ? "这条资料已允许 AI 检索。" : "这条资料已从 AI 检索范围排除。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料设置保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setAllowsAIUse(allowsAIUse, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].allowsAIUse = allowsAIUse
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.allowsAIUse = allowsAIUse
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsAIUse
        ? "已允许 AI 使用 \(documentIDs.count) 条资料。"
        : "已将 \(documentIDs.count) 条资料排除在 AI 检索范围外。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量 AI 权限设置失败：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func moveToRecycleBin(_ documentIDs: Set<UUID>) -> Bool {
    guard !documentIDs.isEmpty else { return false }
    do {
      let now = Date()
      let movingDocuments = documents.filter { documentIDs.contains($0.id) }
      try service.moveToRecycleBin(documentIDs: documentIDs)
      documents.removeAll { documentIDs.contains($0.id) }
      searchResults.removeAll { documentIDs.contains($0.document.id) }
      recycledDocuments.insert(contentsOf: movingDocuments.map { document in
        var archived = document
        archived.isArchived = true
        archived.updatedAt = now
        return KnowledgeRecycledDocument(document: archived, deletedAt: now)
      }, at: 0)
      ensureVisibleSelection()
      statusMessage = "已将 \(documentIDs.count) 条资料移到回收站，可随时恢复。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "移到回收站失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func restoreFromRecycleBin(_ documentIDs: Set<UUID>) -> Bool {
    guard !documentIDs.isEmpty else { return false }
    do {
      let now = Date()
      let restoring = recycledDocuments.filter { documentIDs.contains($0.id) }
      try service.restoreFromRecycleBin(documentIDs: documentIDs)
      recycledDocuments.removeAll { documentIDs.contains($0.id) }
      documents.append(contentsOf: restoring.map { recycled in
        var document = recycled.document
        document.isArchived = false
        document.updatedAt = now
        return document
      })
      statusMessage = "已从回收站恢复 \(documentIDs.count) 条资料。"
      lastError = nil
      if let firstID = documentIDs.first { selectDocument(firstID) }
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "恢复资料失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func deleteDocument(_ documentID: UUID) -> Bool {
    do {
      let report = try service.deleteDocument(id: documentID)
      documents.removeAll { $0.id == documentID }
      recycledDocuments.removeAll { $0.id == documentID }
      searchResults.removeAll { $0.document.id == documentID }
      pinnedDocumentIDs.remove(documentID)
      ensureVisibleSelection()
      if report.failedStoredFileCount == 0 {
        statusMessage = "资料已永久删除，本地副本和检索索引已清理。"
      } else {
        statusMessage = "资料和检索索引已删除；有 \(report.failedStoredFileCount) 个本地副本因文件权限未能清理。"
      }
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "删除失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func saveAnnotation(_ annotation: KnowledgeAnnotation) -> Bool {
    do {
      let saved = try service.saveAnnotation(annotation)
      annotations.removeAll { $0.id == saved.id }
      annotations.insert(saved, at: 0)
      statusMessage = "资料标注已保存。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "标注保存失败：\(error.localizedDescription)"
      return false
    }
  }

  public func deleteAnnotation(_ annotationID: UUID) {
    do {
      try service.deleteAnnotation(id: annotationID)
      annotations.removeAll { $0.id == annotationID }
      statusMessage = "资料标注已删除。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "标注删除失败：\(error.localizedDescription)"
    }
  }

  public func recordBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) {
    do {
      try service.recordBacklinks(citations: citations, target: target)
      if let selectedDocumentID, citations.contains(where: { $0.documentID == selectedDocumentID }) {
        backlinks = try service.backlinks(documentID: selectedDocumentID)
      }
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料引用记录未保存：\(error.localizedDescription)"
    }
  }

  public func makeSourceRefreshPreview(
    documentID: UUID
  ) async throws -> KnowledgeSourceRefreshPreview {
    statusMessage = "正在检查资料来源更新…"
    do {
      let preview = try await service.makeSourceRefreshPreview(documentID: documentID)
      statusMessage = preview.difference.hasChanges
        ? "已发现来源内容变化，可预览后更新。"
        : "来源内容与当前版本一致。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "来源检查失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func revisionDifference(
    documentID: UUID,
    revisionID: UUID
  ) async throws -> KnowledgeRevisionDifference {
    let service = self.service
    return try await Task.detached(priority: .utility) {
      try service.revisionDifference(documentID: documentID, revisionID: revisionID)
    }.value
  }

  @discardableResult
  public func applySourceRefresh(_ preview: KnowledgeSourceRefreshPreview) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      let result = try await service.applySourceRefresh(preview)
      await reload(selecting: preview.documentID)
      statusMessage = result.updatedCount > 0
        ? "来源更新已保存为新版本，可在版本历史中恢复旧内容。"
        : "来源内容未变化，没有创建重复版本。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "来源更新失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func restoreRevision(_ revisionID: UUID, documentID: UUID) -> Bool {
    do {
      let restored = try service.restoreRevision(documentID: documentID, revisionID: revisionID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index] = restored
      }
      selectedDocumentText = ""
      loadDocument(nil)
      loadDocument(documentID)
      loadDocumentInsights(documentID: documentID)
      loadRelatedChapters(documentID: documentID, anchorChunkID: nil)
      statusMessage = "已恢复所选资料版本，全文与语义检索已切换。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "版本恢复失败：\(error.localizedDescription)"
      return false
    }
  }

  public func setPinned(_ pinned: Bool, documentID: UUID) {
    do {
      try service.setPinned(pinned, documentID: documentID)
      if pinned {
        pinnedDocumentIDs.insert(documentID)
      } else {
        pinnedDocumentIDs.remove(documentID)
      }
      statusMessage = pinned ? "资料已固定到 AI 对话。" : "资料已取消固定。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "固定状态保存失败：\(error.localizedDescription)"
    }
  }

  public func isPinned(_ documentID: UUID) -> Bool {
    pinnedDocumentIDs.contains(documentID)
  }

  public func createBackup(at destinationURL: URL) async -> KnowledgeLibraryBackupPreview? {
    isBusy = true
    statusMessage = "正在创建资料库一致性备份…"
    defer { isBusy = false }
    do {
      let preview = try await service.createBackup(at: destinationURL)
      statusMessage = "资料库备份完成：\(preview.documentCount) 条资料，已通过完整性校验。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库备份失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func exportDocuments(
    _ documentIDs: Set<UUID>,
    to destinationDirectory: URL
  ) async -> KnowledgeBatchExportReport? {
    guard !documentIDs.isEmpty else { return nil }
    isBusy = true
    statusMessage = "正在导出 \(documentIDs.count) 条资料…"
    defer { isBusy = false }
    do {
      let report = try await service.exportDocuments(
        documentIDs: documentIDs,
        to: destinationDirectory
      )
      statusMessage = "已将 \(report.exportedDocumentCount) 条资料导出为 Markdown。"
      lastError = nil
      return report
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料导出失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func rebuildSemanticIndex(for documentIDs: Set<UUID>) async {
    guard !documentIDs.isEmpty else { return }
    isBusy = true
    statusMessage = "正在重建所选资料的本地语义向量…"
    defer { isBusy = false }
    do {
      let report = try await service.repairSemanticVectors(documentIDs: documentIDs)
      statusMessage = "语义索引重建完成：扫描 \(report.scannedChunkCount) 个片段，生成 \(report.regeneratedVectorCount) 个向量。"
      lastError = nil
      await refreshLibraryHealth()
    } catch {
      lastError = error.localizedDescription
      statusMessage = "语义索引重建失败：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func refreshLibraryHealth() async -> KnowledgeLibraryHealthSnapshot? {
    isLoadingHealth = true
    defer { isLoadingHealth = false }
    do {
      let snapshot = try await service.libraryHealth()
      healthSnapshot = snapshot
      lastError = nil
      return snapshot
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库健康检查失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func localContentRepairPreviews(
    documentIDs: Set<UUID>? = nil,
    includingCurrentParserVersion: Bool = false
  ) async -> [KnowledgeSourceRefreshPreview]? {
    isBusy = true
    statusMessage = "正在分析本机网页归档和旧解析器版本…"
    defer { isBusy = false }
    do {
      let previews = try await service.makeLocalContentRepairPreviews(
        documentIDs: documentIDs,
        includingCurrentParserVersion: includingCurrentParserVersion
      )
      statusMessage = previews.isEmpty
        ? "没有找到可使用本机原始归档重新净化的网页资料。"
        : "发现 \(previews.count) 条可在本机重新净化的网页资料，请预览后修复。"
      lastError = nil
      return previews
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料质量分析失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func applyLocalContentRepairs(
    _ previews: [KnowledgeSourceRefreshPreview]
  ) async -> Bool {
    guard !previews.isEmpty else { return true }
    isBusy = true
    statusMessage = "正在重新净化网页正文并重建全文与语义索引…"
    defer { isBusy = false }
    do {
      let result = try await service.applyLocalContentRepairs(previews)
      let selectedID = selectedDocumentID
      await reload(selecting: selectedID)
      _ = await refreshLibraryHealth()
      statusMessage = "资料质量修复完成：已为 \(result.updatedCount) 条网页创建新版，并重建检索索引。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料质量修复失败：\(error.localizedDescription)"
      return false
    }
  }

  public func backupPreview(from backupURL: URL) async -> KnowledgeLibraryBackupPreview? {
    isBusy = true
    statusMessage = "正在校验资料库备份…"
    defer { isBusy = false }
    do {
      let preview = try await service.inspectBackup(at: backupURL)
      statusMessage = "备份校验通过，可以预览后恢复。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "备份不可恢复：\(error.localizedDescription)"
      return nil
    }
  }

  public func stageRestore(from backupURL: URL) async -> Bool {
    isBusy = true
    statusMessage = "正在准备资料库恢复…"
    defer { isBusy = false }
    do {
      _ = try await service.stageRestore(from: backupURL)
      statusMessage = "恢复包已安全暂存，应用重新启动后生效。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "恢复准备失败：\(error.localizedDescription)"
      return false
    }
  }

  public func reportStartupRestoreOutcome(_ outcome: KnowledgeLibraryRestoreStartupOutcome) {
    switch outcome {
    case .none:
      break
    case .restored(let result):
      let recoveryMessage = result.previousLibraryURL.map {
        "恢复前资料库已保留在 \($0.path)。"
      } ?? "恢复前没有现有资料库。"
      statusMessage = "资料库已从备份恢复，共 \(result.restoredPreview.documentCount) 条资料。\(recoveryMessage)"
      lastError = nil
    case .failed(let detail):
      lastError = detail
      statusMessage = "资料库自动恢复未完成：\(detail)"
    }
  }

  private func ensureVisibleSelection() {
    if !searchText.trimmedForPublishing.isEmpty {
      if let selectedSearchResult,
         visibleSearchResults.contains(where: { $0.id == selectedSearchResult.id }) {
        return
      }
      if let result = visibleSearchResults.first {
        selectSearchResult(result)
      } else {
        selectDocument(nil)
      }
      return
    }
    if let selectedDocumentID,
       visibleDocuments.contains(where: { $0.id == selectedDocumentID }) {
      return
    }
    selectDocument(visibleDocuments.first?.id)
  }

  private func isIncludedInCurrentScope(_ document: KnowledgeDocument) -> Bool {
    switch folderScope {
    case .all:
      true
    case .unfiled:
      document.folderID == nil
    case .folder(let folderID):
      document.folderID == folderID
    case .smartCollection(let rule):
      smartCollectionService.matches(document, rule: rule)
    case .savedCollection(let collection):
      smartCollectionService.matches(
        document,
        rules: collection.rules,
        matchMode: collection.matchMode
      )
    }
  }

  public func context(
    query: String,
    policy: KnowledgeRetrievalPolicy
  ) async -> KnowledgeContextSnapshot? {
    guard policy != .off else { return nil }
    guard !documents.isEmpty else { return nil }
    let scopedIDs: Set<UUID>?
    switch policy {
    case .off:
      return nil
    case .automatic:
      scopedIDs = nil
    case .pinnedOnly:
      guard !pinnedDocumentIDs.isEmpty else { return nil }
      scopedIDs = pinnedDocumentIDs
    }

    do {
      let snapshot = try await service.contextAsync(query: query, documentIDs: scopedIDs)
      if let snapshot {
        statusMessage = "资料库通过全文与本地语义检索找到 \(snapshot.citations.count) 条相关片段。"
      } else {
        statusMessage = "全文与本地语义检索都没有找到足够相关的内容。"
      }
      return snapshot
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库检索失败：\(error.localizedDescription)"
      return nil
    }
  }
}
