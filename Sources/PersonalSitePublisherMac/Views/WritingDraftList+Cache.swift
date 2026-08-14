import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
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
    guard !filteredDrafts.contains(where: { $0.id == selectedDraftID }) else {
      return
    }

    draftFilterDebounceTask?.cancel()
    searchText = ""
    filter = .all
    applyDraftFilterDebounce()
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
