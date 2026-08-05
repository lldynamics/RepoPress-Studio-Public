import Combine
import Foundation

@MainActor
extension KnowledgeStore {
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
}
