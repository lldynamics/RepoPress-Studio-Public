import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  func makeFolderProjection(for drafts: [ArticleDraft]) -> DraftFolderProjection {
    let maskedDraftIDs = Set(
      drafts.compactMap { draft in
        store.privateContentDisplay(for: draft).isMasked ? draft.id : nil
      }
    )
    let projectionOrder = DraftListSortOrder(rawValue: sortOrder.rawValue) ?? .updatedNewest
    return DraftFolderProjection(
      profile: store.activeProfile,
      drafts: drafts,
      sortOrder: projectionOrder,
      maskedDraftIDs: maskedDraftIDs
    )
  }

  func synchronizeFolderExpansionState() {
    guard store.draftListContentScope == .currentSite else {
      folderExpansionState.clearTransientReveal()
      return
    }

    let universeProjection = makeFolderProjection(for: store.visibleDrafts)
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
  }

  func updateFolderSearchReveal() {
    guard store.draftListContentScope == .currentSite,
      !debouncedSearchText.isEmpty
    else {
      folderExpansionState.clearTransientReveal()
      return
    }

    let filteredProjection = makeFolderProjection(for: filteredDrafts)
    let matchingAncestorIDs = filteredDrafts.flatMap {
      filteredProjection.ancestorFolderIDs(for: $0.id)
    }
    folderExpansionState.clearTransientReveal()
    folderExpansionState.revealSearchResultAncestors(matchingAncestorIDs)
  }

  func loadMoreDrafts() {
    let nextLimit = draftListLimit + draftPageStep
    let totalCount = filteredDrafts.count
    guard nextLimit <= totalCount else {
      draftListLimit = totalCount
      refreshVisibleRowPresentations()
      return
    }
    withAnimation(WorkbenchMotion.standard) {
      draftListLimit = nextLimit
    }
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
    resetDraftPagination()
    refreshDraftCounts()
  }

  func revealSelectedDraftIfNeeded() {
    guard let selectedDraftID = draftListState.selectedDraftID,
      store.writingDrafts.contains(where: { $0.id == selectedDraftID })
    else {
      return
    }
    refreshFilteredDraftsCache()
    if !filteredDrafts.contains(where: { $0.id == selectedDraftID }) {
      draftFilterDebounceTask?.cancel()
      searchText = ""
      filter = .all
      applyDraftFilterDebounce()
    }

    guard store.draftListContentScope == .currentSite,
      let selectedIndex = filteredDrafts.firstIndex(where: { $0.id == selectedDraftID })
    else {
      return
    }

    let projection = makeFolderProjection(for: filteredDrafts)
    folderExpansionState.revealAncestorsForSelection(
      projection.ancestorFolderIDs(for: selectedDraftID)
    )
    let requiredLimit = selectedIndex + 1
    if requiredLimit > draftListLimit {
      draftListLimit = min(filteredDrafts.count, requiredLimit)
      refreshVisibleRowPresentations()
    }
  }

  func refreshDraftCounts() {
    refreshFilteredDraftsCache()
    let nextFilteredCount = filteredDrafts.count
    let nextVisibleCount = visibleDraftSnapshot.count
    let delta = nextVisibleCount - visibleDraftCount

    visibleDraftCount = nextVisibleCount
    filteredDraftCount = nextFilteredCount

    if delta != 0 {
      applyDraftCountDelta(delta)
    } else if draftCountDelta == nil {
      isDraftCountPunching = false
    }
  }

  private func applyDraftCountDelta(_ delta: Int) {
    draftCountDelta = delta
    isDraftCountPunching = true
    draftCountBadgeTask?.cancel()

    draftCountBadgeTask = Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled {
        return
      }
      await MainActor.run {
        withAnimation(WorkbenchMotion.deliberate) {
          isDraftCountPunching = false
          draftCountDelta = nil
        }
      }
    }
  }

  var draftPageStep: Int {
    36
  }

  func resetDraftPagination() {
    refreshFilteredDraftsCache()
    guard !filteredDrafts.isEmpty else {
      draftListLimit = 0
      draftListCache.resetPaginationTrigger()
      return
    }
    draftListLimit = min(filteredDrafts.count, draftPageStep)
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

    guard visibleDraftSnapshot.isEmpty else {
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
    draftListCache.filteredDrafts
  }

  var visibleDraftSnapshot: [ArticleDraft] {
    draftListCache.sourceDrafts
  }

  var sortOrder: WritingDraftSortOrder {
    WritingDraftSortOrder(rawValue: sortOrderRawValue) ?? .updatedNewest
  }

  func refreshFilteredDraftsCache() {
    let presentationRevision = draftListState.presentationRevision
    let didRefreshPresentation = draftListCache.presentationRevision != presentationRevision
    if didRefreshPresentation {
      let sourceDrafts = store.writingDrafts
      draftListCache.presentationRevision = presentationRevision
      draftListCache.sourceDrafts = sourceDrafts
    }
    let visibleDrafts = draftListCache.sourceDrafts
    let query = debouncedSearchText
    let draftTaskQueueStateVersion = draftListState.taskQueueStateVersion

    guard
      didRefreshPresentation || query != draftListCache.searchText
        || draftListCache.filter != debouncedFilter || draftListCache.sortOrder != sortOrder
        || draftListCache.draftTaskQueueStateVersion != draftTaskQueueStateVersion
    else {
      synchronizeFolderExpansionState()
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
    draftListCache.filteredDrafts = sortOrder.sorted(matchedDrafts)
    refreshVisibleRowPresentations()
    synchronizeFolderExpansionState()
  }

  func refreshVisibleRowPresentations() {
    let visibleLimit = min(draftListLimit, draftListCache.filteredDrafts.count)
    draftListCache.updateRowPresentations(
      sourceDrafts: draftListCache.sourceDrafts,
      visibleDrafts: draftListCache.filteredDrafts.prefix(visibleLimit),
      profileFor: { store.profile(for: $0) },
      displayFor: { store.privateContentDisplay(for: $0) }
    )
  }
}
