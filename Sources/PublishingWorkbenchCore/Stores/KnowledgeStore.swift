import Combine
import Foundation

@MainActor
public final class KnowledgeStore: ObservableObject {
  private let service: KnowledgeLibraryService
  private let smartCollectionService = KnowledgeSmartCollectionService()
  private var searchTask: Task<Void, Never>?
  private var selectedTextTask: Task<Void, Never>?
  private var selectedCapturedTextTask: Task<Void, Never>?
  private var relatedChaptersTask: Task<Void, Never>?
  private var documentInsightsTask: Task<Void, Never>?
  private var articleBacklinksTask: Task<Void, Never>?
  private var articleBacklinksTargetID: String?
  private var lastImportRetryAction: (@MainActor () async -> Void)?
  private var visibleDocumentsCacheRevision: UInt64?
  private var visibleDocumentsCache: [KnowledgeDocument] = []
  private var visibleSearchResultsCacheRevision: UInt64?
  private var visibleSearchResultsCache: [KnowledgeSearchResult] = []
  #if DEBUG
    private(set) var visibleDocumentsSnapshotBuildCount = 0
    private(set) var visibleSearchResultsSnapshotBuildCount = 0
  #endif

  @Published public private(set) var listPresentationRevision: UInt64 = 0
  @Published public private(set) var documents: [KnowledgeDocument] = [] {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var recycledDocuments: [KnowledgeRecycledDocument] = []
  @Published public private(set) var folders: [KnowledgeFolder] = []
  @Published public private(set) var searchResults: [KnowledgeSearchResult] = [] {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var selectedSearchResult: KnowledgeSearchResult?
  @Published public private(set) var selectedResultQuery = ""
  @Published public var selectedDocumentID: UUID?
  @Published public private(set) var folderScope: KnowledgeFolderScope = .all {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var documentSort = KnowledgeDocumentSort() {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var searchFilter = KnowledgeSearchFilter() {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var selectedDocumentText = ""
  @Published public private(set) var isLoadingSelectedDocumentText = false
  @Published public private(set) var selectedDocumentTextError: String?
  @Published public private(set) var selectedDocumentCapturedText: String?
  @Published public private(set) var isLoadingSelectedDocumentCapturedText = false
  @Published public private(set) var selectedDocumentCapturedTextError: String?
  @Published public private(set) var searchText = "" {
    didSet { invalidateListPresentation() }
  }
  @Published public private(set) var isSearching = false
  @Published public private(set) var isBusy = false
  @Published public private(set) var isImporting = false
  @Published public private(set) var importProgress: Double?
  @Published public private(set) var importOperationTitle: String?
  @Published public private(set) var lastImportFailure: String?
  @Published public private(set) var statusMessage: String?
  @Published public private(set) var lastError: String?
  @Published public private(set) var pinnedDocumentIDs: Set<UUID> = []
  @Published public private(set) var relatedChapters: [KnowledgeRelatedChapter] = []
  @Published public private(set) var isLoadingRelatedChapters = false
  @Published public private(set) var annotations: [KnowledgeAnnotation] = []
  @Published public private(set) var backlinks: [KnowledgeBacklink] = []
  @Published public private(set) var articleBacklinks: [KnowledgeBacklink] = []
  @Published public private(set) var isLoadingArticleBacklinks = false
  @Published public private(set) var revisions: [KnowledgeDocumentRevision] = []
  @Published public private(set) var healthSnapshot: KnowledgeLibraryHealthSnapshot?
  @Published public private(set) var isLoadingHealth = false

  public init(service: KnowledgeLibraryService = KnowledgeLibraryService()) {
    self.service = service
    Task { await reload() }
  }

  public var rootURL: URL {
    service.rootURL
  }

  deinit {
    searchTask?.cancel()
    selectedTextTask?.cancel()
    selectedCapturedTextTask?.cancel()
    relatedChaptersTask?.cancel()
    documentInsightsTask?.cancel()
    articleBacklinksTask?.cancel()
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
    if visibleDocumentsCacheRevision == listPresentationRevision {
      return visibleDocumentsCache
    }
    let candidates: [KnowledgeDocument]
    if searchText.trimmedForPublishing.isEmpty {
      candidates = documents
    } else {
      var seen = Set<UUID>()
      candidates = visibleSearchResults.compactMap { result in
        seen.insert(result.document.id).inserted ? result.document : nil
      }
    }
    let filtered =
      searchText.trimmedForPublishing.isEmpty
      ? candidates.filter(isIncludedInCurrentScope)
      : candidates
    let result = documentSort.sorted(filtered)
    #if DEBUG
      visibleDocumentsSnapshotBuildCount += 1
    #endif
    visibleDocumentsCache = result
    visibleDocumentsCacheRevision = listPresentationRevision
    return result
  }

  public var visibleSearchResults: [KnowledgeSearchResult] {
    if visibleSearchResultsCacheRevision == listPresentationRevision {
      return visibleSearchResultsCache
    }
    let result = searchFilter.filtered(
      searchResults,
      isInCurrentCollection: isIncludedInCurrentScope
    )
    #if DEBUG
      visibleSearchResultsSnapshotBuildCount += 1
    #endif
    visibleSearchResultsCache = result
    visibleSearchResultsCacheRevision = listPresentationRevision
    return result
  }

  private func invalidateListPresentation() {
    listPresentationRevision &+= 1
    visibleDocumentsCacheRevision = nil
    visibleSearchResultsCacheRevision = nil
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
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库读取失败：\(error.localizedDescription)"
    }
  }

  public func retryLastImport() async {
    guard let lastImportRetryAction else {
      statusMessage = "当前没有可重试的资料导入任务。"
      return
    }
    await lastImportRetryAction()
  }

  private func beginImport(
    title: String,
    retry: @escaping @MainActor () async -> Void
  ) {
    isImporting = true
    importProgress = 0
    importOperationTitle = title
    lastImportFailure = nil
    lastImportRetryAction = retry
  }

  private func finishImport(failure: String? = nil) {
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

  private func loadDocument(_ documentID: UUID?) {
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
    guard documentKind == .webpage else {
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
    let documentIDs: Set<UUID>? =
      searchScope == .currentCollection
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
          self?.searchFilter.signal.signal == requiredSignal
        else { return }
        self?.searchResults = results
        self?.isSearching = false
        let semanticCount = results.filter { $0.signals.contains(.semantic) }.count
        let documentCount = Set(results.map { $0.document.id }).count
        self?.statusMessage =
          results.isEmpty
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
      !searchText.trimmedForPublishing.isEmpty
    {
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
        for tag in tags.map({ $0.trimmedForPublishing }).filter({ !$0.isEmpty })
        where
          !documents[index].tags.contains(where: {
            $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
          })
        {
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
    beginImport(title: "保存并建立索引") { [weak self] in
      guard let self else { return }
      _ = try? await self.commit(preview, destination: destination)
    }
    isBusy = true
    statusMessage = "正在保存并建立索引…"
    defer { isBusy = false }
    do {
      importProgress = 0.35
      let result = try await service.commit(preview, destination: destination)
      importProgress = 0.72
      await reload()
      finishImport()
      statusMessage =
        "资料导入完成：新增 \(result.insertedCount)，更新 \(result.updatedCount)，跳过 \(result.skippedCount)。"
      lastError = nil
      return result
    } catch {
      finishImport(failure: error.localizedDescription)
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
    beginImport(title: "保存浏览器页面") { [weak self] in
      guard let self else { return }
      _ = try? await self.importBrowserCapture(
        capture,
        folderID: folderID,
        newFolderName: newFolderName,
        duplicateResolution: duplicateResolution
      )
    }
    isBusy = true
    statusMessage = "正在保存浏览器页面并建立索引…"
    defer { isBusy = false }
    do {
      importProgress = 0.25
      var preview = try await service.makeBrowserImportPreview(capture: capture)
      guard var candidate = preview.candidates.first else {
        throw KnowledgeLibraryError.invalidBrowserCapture("浏览器页面没有可保存的内容。")
      }
      let currentDocuments = try service.documents()
      let currentFolders = try service.folders()
      let existingDocument = candidate.existingDocumentID.flatMap { documentID in
        currentDocuments.first(where: { $0.id == documentID })
      }
      let hasSameURL =
        existingDocument?.sourceURL?.absoluteString == candidate.sourceURL?.absoluteString
      if let existingDocument, hasSameURL, duplicateResolution == nil {
        let existingFolder = existingDocument.folderID.flatMap { existingFolderID in
          currentFolders.first(where: { $0.id == existingFolderID })
        }
        statusMessage = "检测到同网址资料，请选择处理方式。"
        lastError = nil
        finishImport()
        return .requiresDuplicateResolution(
          KnowledgeBrowserDuplicateConflict(
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
      importProgress = 0.62
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
      // 新版本和副本的 AI 权限已由导入候选项带入数据库事务。
      // “仅移动分类”不提交候选项，因此仍只更新分类并保留原 AI 权限。
      await reload(selecting: result.documentIDs.first)
      finishImport()
      statusMessage =
        action == .moved
        ? "已将原资料移到选定分类；正文、元数据和 AI 权限均保持不变。"
        : "浏览器页面已保存到资料库。"
      lastError = nil
      return .saved(result: result, action: action)
    } catch {
      finishImport(failure: error.localizedDescription)
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
        $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive])
          == .orderedSame
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

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentID: UUID) {
    do {
      try service.setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentID: documentID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].allowsLocalSemanticIndex = allowsLocalSemanticIndex
        documents[index].updatedAt = Date()
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.allowsLocalSemanticIndex = allowsLocalSemanticIndex
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsLocalSemanticIndex
        ? "这条资料已建立本地语义索引。"
        : "这条资料已关闭本地语义索引。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料设置保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].allowsLocalSemanticIndex = allowsLocalSemanticIndex
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.allowsLocalSemanticIndex = allowsLocalSemanticIndex
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      statusMessage =
        allowsLocalSemanticIndex
        ? "已为 \(documentIDs.count) 条资料建立本地语义索引。"
        : "已关闭 \(documentIDs.count) 条资料的本地语义索引。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量本地语义索引设置失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentID: UUID) {
    do {
      try service.setAllowsRemoteAIUse(allowsRemoteAIUse, documentID: documentID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].allowsRemoteAIUse = allowsRemoteAIUse
        documents[index].updatedAt = Date()
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.allowsRemoteAIUse = allowsRemoteAIUse
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsRemoteAIUse
        ? "这条资料已允许发送给远程 AI。"
        : "这条资料已禁止发送给远程 AI。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料远程 AI 权限保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setAllowsRemoteAIUse(allowsRemoteAIUse, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].allowsRemoteAIUse = allowsRemoteAIUse
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.allowsRemoteAIUse = allowsRemoteAIUse
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsRemoteAIUse
        ? "已允许发送给远程 AI 的资料：\(documentIDs.count) 条。"
        : "已禁止发送给远程 AI 的资料：\(documentIDs.count) 条。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量远程 AI 权限设置失败：\(error.localizedDescription)"
    }
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) {
    setAllowsRemoteAIUse(allowsAIUse, documentID: documentID)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) {
    setAllowsRemoteAIUse(allowsAIUse, documentIDs: documentIDs)
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
      recycledDocuments.insert(
        contentsOf: movingDocuments.map { document in
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
      documents.append(
        contentsOf: restoring.map { recycled in
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

  /// Permanently deletes every item currently in the recycle bin on a utility
  /// task, then reconciles in-memory presentation state on the main actor.
  public func emptyRecycleBin() async -> KnowledgeRecycleBinCleanupSummary {
    let documentIDs = recycledDocuments.map(\.id)
    guard !documentIDs.isEmpty, !isBusy else {
      return KnowledgeRecycleBinCleanupSummary(
        requestedDocumentCount: documentIDs.count,
        removedDocumentCount: 0,
        failedDocumentCount: 0,
        removedStoredFileCount: 0,
        failedStoredFileCount: 0
      )
    }

    isBusy = true
    defer { isBusy = false }
    let service = self.service
    let result = await Task.detached(priority: .utility) {
      var removedIDs: [UUID] = []
      var failedDocumentCount = 0
      var removedStoredFileCount = 0
      var failedStoredFileCount = 0
      for documentID in documentIDs {
        do {
          let report = try service.deleteDocument(id: documentID)
          removedIDs.append(documentID)
          removedStoredFileCount += report.removedStoredFileCount
          failedStoredFileCount += report.failedStoredFileCount
        } catch {
          failedDocumentCount += 1
        }
      }
      return (
        removedIDs,
        failedDocumentCount,
        removedStoredFileCount,
        failedStoredFileCount
      )
    }.value

    let removedIDSet = Set(result.0)
    documents.removeAll { removedIDSet.contains($0.id) }
    recycledDocuments.removeAll { removedIDSet.contains($0.id) }
    searchResults.removeAll { removedIDSet.contains($0.document.id) }
    pinnedDocumentIDs.subtract(removedIDSet)
    ensureVisibleSelection()

    let summary = KnowledgeRecycleBinCleanupSummary(
      requestedDocumentCount: documentIDs.count,
      removedDocumentCount: removedIDSet.count,
      failedDocumentCount: result.1,
      removedStoredFileCount: result.2,
      failedStoredFileCount: result.3
    )
    if summary.failedDocumentCount == 0, summary.failedStoredFileCount == 0 {
      statusMessage = CoreL10n.format(
        "资料库回收站已清空：永久删除 %d 条资料。",
        summary.removedDocumentCount
      )
      lastError = nil
    } else {
      statusMessage = CoreL10n.format(
        "资料库回收站已清理：删除 %d 条，%d 条未能删除，%d 个本地文件未能移除。",
        summary.removedDocumentCount,
        summary.failedDocumentCount,
        summary.failedStoredFileCount
      )
      lastError = statusMessage
    }
    return summary
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
      if let selectedDocumentID, citations.contains(where: { $0.documentID == selectedDocumentID })
      {
        backlinks = try service.backlinks(documentID: selectedDocumentID)
      }
      if target.kind == .articleDraft,
         articleBacklinksTargetID == target.id {
        loadArticleBacklinks(for: UUID(uuidString: target.id))
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
      statusMessage =
        preview.difference.hasChanges
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
      statusMessage =
        result.updatedCount > 0
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
      statusMessage =
        "语义索引重建完成：扫描 \(report.scannedChunkCount) 个片段，生成 \(report.regeneratedVectorCount) 个向量。"
      lastError = nil
      await refreshLibraryHealth()
    } catch {
      lastError = error.localizedDescription
      statusMessage = "语义索引重建失败：\(error.localizedDescription)"
    }
  }

  public func rebuildAllSemanticIndex() async {
    isBusy = true
    statusMessage = "正在事务性替换全部本地语义向量…"
    defer { isBusy = false }
    do {
      let report = try await service.repairSemanticVectors()
      statusMessage =
        "语义索引重建完成：扫描 \(report.scannedChunkCount) 个片段，生成 \(report.regeneratedVectorCount) 个向量，并清理旧模型。"
      lastError = nil
      await refreshLibraryHealth()
    } catch {
      lastError = error.localizedDescription
      statusMessage = "语义索引重建失败，旧索引已保留：\(error.localizedDescription)"
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
      statusMessage =
        previews.isEmpty
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
      let recoveryMessage =
        result.previousLibraryURL.map {
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
        visibleSearchResults.contains(where: { $0.id == selectedSearchResult.id })
      {
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
      visibleDocuments.contains(where: { $0.id == selectedDocumentID })
    {
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

  /// Retrieves local-only recommendations for the article context card.
  ///
  /// This path intentionally does not require `allowsRemoteAIUse`: showing a
  /// local recommendation is different from transmitting the source to a
  /// remote provider. Documents that opted out of the local semantic index are
  /// excluded by the database and by the final guard below.
  public func contextRecommendations(
    query: String,
    limit: Int = 6
  ) async throws -> [KnowledgeSearchResult] {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty, limit > 0 else { return [] }
    let localDocumentIDs = Set<UUID>(
      documents.compactMap { document in
        guard !document.isArchived, document.allowsLocalSemanticIndex else { return nil }
        return document.id
      }
    )
    guard !localDocumentIDs.isEmpty else { return [] }
    let results = try await service.searchAsync(
      query: trimmedQuery,
      limit: max(limit, 12),
      onlyRemoteAIAllowed: false,
      documentIDs: localDocumentIDs
    )
    return results
      .filter { !$0.document.isArchived && $0.document.allowsLocalSemanticIndex }
      .prefix(limit)
      .map { $0 }
  }

  /// Resolves one user-selected knowledge document for an explicit AI @
  /// reference. This does not change library selection and refuses documents
  /// that are archived or not authorized for AI use.
  public func explicitAIContextText(documentID: UUID) async -> String? {
    guard
      let document = documents.first(where: {
        $0.id == documentID && !$0.isArchived && $0.allowsRemoteAIUse
      })
    else {
      return nil
    }
    do {
      let text = try await service.normalizedTextAsync(documentID: documentID)
      if document.kind == .webpage {
        return KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)
      }
      return text
    } catch {
      lastError = error.localizedDescription
      statusMessage = "读取 @ 资料失败：\(error.localizedDescription)"
      return nil
    }
  }
}
