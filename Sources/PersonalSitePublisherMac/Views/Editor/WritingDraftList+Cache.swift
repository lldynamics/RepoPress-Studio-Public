import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  /// Folder and row projections intentionally keep IDs instead of full
  /// `ArticleDraft` values. Resolve the current value immediately before an
  /// action so a body autosave cannot leave an export or destructive command
  /// holding stale text.
  func liveDraft(for renderedDraft: ArticleDraft) -> ArticleDraft? {
    store.draft(for: renderedDraft.id)
  }

  func synchronizeFolderExpansionState() {
    guard store.draftListContentScope == .currentSite else {
      folderExpansionState.clearTransientReveal()
      draftListCache.clearFolderProjectionCache()
      return
    }

    updateFolderProjectionCache()
    guard let universeProjection = draftListCache.universeFolderProjection else {
      return
    }
    let validFolderIDs = Set(universeProjection.root.allFolderIDs)
    if folderExpansionSiteID != store.activeProfile.id {
      folderExpansionState = WritingDraftFolderExpansionState(
        defaultExpandedTopLevelNodes: universeProjection.topLevelNodes
      )
      folderExpansionSiteID = store.activeProfile.id
    } else {
      folderExpansionState.reconcile(validFolderIDs: validFolderIDs)
    }

    updateFolderSearchReveal()
    updateFolderEntriesCache()
  }

  func updateFolderProjectionCache() {
    guard store.draftListContentScope == .currentSite else {
      draftListCache.clearFolderProjectionCache()
      return
    }

    let universeDrafts = visibleDraftSnapshot
    let currentFilteredDrafts = filteredDrafts
    let maskedDraftIDs = Set(
      universeDrafts.compactMap { draft in
        store.privateContentDisplay(for: draft).isMasked ? draft.id : nil
      }
    )
    let projectionOrder = DraftListSortOrder(rawValue: sortOrder.rawValue) ?? .updatedNewest
    draftListCache.updateFolderProjectionCache(
      profile: store.activeProfile,
      universeDrafts: universeDrafts,
      filteredDrafts: currentFilteredDrafts,
      sortOrder: projectionOrder,
      maskedDraftIDs: maskedDraftIDs,
      universeSourceRevision: draftListCache.sourceMetadataRevision
    )
  }

  func updateFolderEntriesCache() {
    guard store.draftListContentScope == .currentSite else {
      draftListCache.clearFolderProjectionCache()
      return
    }

    let loadedDraftIDs = Set(
      draftListCache.filteredDraftIDs.prefix(draftListLimit)
    )
    draftListCache.updateFolderEntriesCache(
      expandedFolderIDs: folderExpansionState.expandedFolderIDs,
      loadedDraftIDs: loadedDraftIDs
    )
  }

  func updateFolderSearchReveal() {
    guard store.draftListContentScope == .currentSite,
      !debouncedSearchText.isEmpty
    else {
      folderExpansionState.clearTransientReveal()
      return
    }

    guard let filteredProjection = draftListCache.filteredFolderProjection else {
      folderExpansionState.clearTransientReveal()
      return
    }
    let matchingAncestorIDs = draftListCache.filteredDraftIDs.flatMap {
      filteredProjection.ancestorFolderIDs(for: $0)
    }
    folderExpansionState.clearTransientReveal()
    folderExpansionState.revealSearchResultAncestors(matchingAncestorIDs)
  }

  func loadMoreDrafts() {
    let nextLimit = draftListLimit + draftPageStep
    let totalCount = cachedFilteredDraftCount
    guard nextLimit <= totalCount else {
      draftListLimit = totalCount
      refreshVisibleRowPresentations()
      return
    }
    draftListLimit = nextLimit
    refreshVisibleRowPresentations()
  }

  func scheduleDraftFilterDebounce() {
    draftFilterDebounceTask?.cancel()

    let nextSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextFilter = filter

    draftFilterDebounceTask = Task {
      do {
        try await Task.sleep(nanoseconds: 180_000_000)
      } catch {
        return
      }

      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        let changedSearchText = nextSearchText
        let searchDidChange = changedSearchText != debouncedSearchText
        let filterDidChange = nextFilter != debouncedFilter
        if searchDidChange || filterDidChange {
          debouncedSearchText = changedSearchText
          debouncedFilter = nextFilter
        }
      }
    }
  }

  func applyDraftFilterDebounce() {
    debouncedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    debouncedFilter = filter
    refreshFilteredDraftsCache()
    resetDraftPagination(refreshFilter: false)
    refreshDraftCounts(refreshFilter: false)
  }

  func refreshDraftCountsWithoutFiltering() {
    refreshDraftCounts(refreshFilter: false)
  }

  func handleDraftListSortChange() {
    resetDraftPagination()
    refreshDraftCountsWithoutFiltering()
  }

  func handleDraftListFilterChange() {
    refreshFilteredDraftsCache()
    resetDraftPagination(refreshFilter: false)
    refreshDraftCountsWithoutFiltering()
  }

  func handleDraftListStoreUpdate() {
    refreshFilteredDraftsCache()
    refreshDraftCountsWithoutFiltering()
  }

  func handleDraftListPresentationRevisionChange() {
    refreshFilteredDraftsCache()
    revealSelectedDraftIfNeeded(refreshFilter: false)
    synchronizeDraftSelection(withDraftIDs: draftListCache.sourceDraftIDs)
    if isDraftListLoading && !draftListCache.sourceDraftIDs.isEmpty {
      isDraftListLoading = false
      draftListLoadingTask?.cancel()
    }
    resetDraftPagination(refreshFilter: false)
    refreshDraftCountsWithoutFiltering()
    refreshDraftListLoadingState()
  }

  func handleFilteredDraftCountChange(_ newCount: Int) {
    if newCount == 0 {
      draftListLimit = 0
    } else if newCount < draftListLimit {
      draftListLimit = newCount
    }
    updateFolderEntriesCache()
    refreshDraftCountsWithoutFiltering()
  }

  func revealSelectedDraftIfNeeded(refreshFilter: Bool = true) {
    guard let selectedDraftID,
      store.writingDrafts.contains(where: { $0.id == selectedDraftID })
    else {
      return
    }
    if refreshFilter {
      refreshFilteredDraftsCache()
    }
    if !draftListCache.filteredDraftIDs.contains(selectedDraftID) {
      draftFilterDebounceTask?.cancel()
      searchText = ""
      filter = .all
      applyDraftFilterDebounce()
    }

    guard store.draftListContentScope == .currentSite,
      let selectedIndex = draftListCache.filteredDraftIDs.firstIndex(of: selectedDraftID)
    else {
      return
    }

    guard let projection = draftListCache.filteredFolderProjection else {
      return
    }
    folderExpansionState.revealAncestorsForSelection(
      projection.ancestorFolderIDs(for: selectedDraftID)
    )
    let requiredLimit = selectedIndex + 1
    if requiredLimit > draftListLimit {
      draftListLimit = min(cachedFilteredDraftCount, requiredLimit)
      refreshVisibleRowPresentations()
    }
    updateFolderEntriesCache()
  }

  func refreshDraftCounts(refreshFilter: Bool = true) {
    if refreshFilter {
      refreshFilteredDraftsCache()
    }
    let nextFilteredCount = cachedFilteredDraftCount
    let nextVisibleCount = draftListCache.sourceDraftIDs.count
    let delta = nextVisibleCount - visibleDraftCount

    visibleDraftCount = nextVisibleCount
    filteredDraftCount = nextFilteredCount

    if delta != 0 {
      applyDraftCountDelta(delta)
    }
  }

  private func applyDraftCountDelta(_ delta: Int) {
    draftCountDelta = delta
    draftCountBadgeTask?.cancel()

    draftCountBadgeTask = Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled {
        return
      }
      await MainActor.run {
        draftCountDelta = nil
      }
    }
  }

  var draftPageStep: Int {
    36
  }

  func resetDraftPagination(refreshFilter: Bool = true) {
    if refreshFilter {
      refreshFilteredDraftsCache()
    }
    guard cachedFilteredDraftCount > 0 else {
      draftListLimit = 0
      draftListCache.resetPaginationTrigger()
      updateFolderEntriesCache()
      return
    }
    draftListLimit = min(cachedFilteredDraftCount, draftPageStep)
    refreshVisibleRowPresentations()
    draftListCache.resetPaginationTrigger()
  }

  var listRowInsets: EdgeInsets {
    WorkspaceSidebarMetrics.rowInsets
  }

  func refreshDraftListLoadingState() {
    draftListLoadingTask?.cancel()
    draftListLoadingNonce += 1
    let nonce = draftListLoadingNonce

    guard draftListCache.sourceDraftIDs.isEmpty else {
      isDraftListLoading = false
      return
    }

    isDraftListLoading = true
    draftListLoadingTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      guard isDraftListLoading && nonce == draftListLoadingNonce else {
        return
      }
      isDraftListLoading = false
    }
  }

  var filteredDrafts: [ArticleDraft] {
    draftListCache.renderedDrafts(for: draftListCache.filteredDraftIDs)
  }

  var cachedFilteredDraftCount: Int {
    draftListCache.filteredDraftIDs.count
  }

  var paginatedDraftSnapshot: [ArticleDraft] {
    draftListCache.renderedDrafts(
      for: draftListCache.filteredDraftIDs.prefix(draftListLimit)
    )
  }

  var visibleDraftSnapshot: [ArticleDraft] {
    draftListCache.renderedDrafts(for: draftListCache.sourceDraftIDs)
  }

  var sortOrder: WritingDraftSortOrder {
    WritingDraftSortOrder(rawValue: sortOrderRawValue) ?? .updatedNewest
  }

  func refreshFilteredDraftsCache() {
    let presentationRevision = draftListState.presentationRevision
    let didRefreshPresentation =
      draftListCache.sourceMetadataRevision != presentationRevision
      || draftListCache.sourceProfileID != store.activeProfileID
      || draftListCache.sourceContentScope != store.draftListContentScope
    if didRefreshPresentation {
      let sourceDrafts = store.writingDrafts
      draftListCache.sourceMetadataRevision = presentationRevision
      draftListCache.sourceProfileID = store.activeProfileID
      draftListCache.sourceContentScope = store.draftListContentScope
      draftListCache.replaceRenderedSourceDrafts(sourceDrafts)
    }
    let visibleDrafts = visibleDraftSnapshot
    let query = debouncedSearchText
    let draftTaskQueueStateVersion = draftListState.taskQueueStateVersion

    guard
      didRefreshPresentation || query != draftListCache.searchText
        || draftListCache.filter != debouncedFilter || draftListCache.sortOrder != sortOrder
        || draftListCache.draftTaskQueueStateVersion != draftTaskQueueStateVersion
    else {
      return
    }

    let taskQueueStates: [UUID: DraftTaskQueueState] =
      debouncedFilter.requiresTaskQueueState
      ? store.draftTaskQueueStates(for: visibleDrafts)
      : [:]
    draftListCache.searchText = query
    draftListCache.filter = debouncedFilter
    draftListCache.sortOrder = sortOrder
    draftListCache.draftTaskQueueStateVersion = draftTaskQueueStateVersion
    let searchableDrafts = visibleDrafts.filter { draft in
      debouncedFilter.matches(
        draft, taskState: debouncedFilter.requiresTaskQueueState ? taskQueueStates[draft.id] : nil)
    }
    let matchedDrafts =
      query.isEmpty
      ? searchableDrafts
      : searchableDrafts.filter { draft in
        draft.title.localizedCaseInsensitiveContains(query)
          || store.matchesPrivacyProtectedDraftSearch(
            draft,
            query: query,
            profile: store.activeProfile
          )
      }
    draftListCache.filteredDraftIDs = sortOrder.sorted(matchedDrafts).map(\.id)
    synchronizeFolderExpansionState()
    refreshVisibleRowPresentations()
  }

  func refreshVisibleRowPresentations() {
    let visibleDrafts = paginatedDraftSnapshot
    draftListCache.updateRowPresentations(
      sourceDraftIDs: Set(draftListCache.sourceDraftIDs),
      visibleDrafts: visibleDrafts[...],
      profileFor: { store.profile(for: $0) },
      displayFor: { store.privateContentDisplay(for: $0) }
    )
    updateFolderEntriesCache()
  }
}
