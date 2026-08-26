import Foundation

extension PublishingStore {
  /// Returns the last complete preview for a draft, regardless of which
  /// draft is currently selected in the workbench.
  func draftPublishPreviewSnapshot(for draftID: UUID) -> DraftPublishPreviewSnapshot? {
    draftPublishPreviewSnapshots[draftID]
  }

  /// A refresh is scoped to the draft key. In particular, a background task
  /// for another draft must not make the selected-draft toolbar look busy.
  func isPublishPreviewRefreshing(for draftID: UUID) -> Bool {
    draftPublishPreviewRefreshTasks[draftID] != nil
  }

  /// Installs a complete result and updates the legacy single-value view only
  /// when this draft is selected. The context ID is checked before mutation so
  /// a caller cannot accidentally put a result under a different draft key.
  @discardableResult
  func installDraftPublishPreviewSnapshot(
    _ snapshot: DraftPublishPreviewSnapshot,
    for draftID: UUID? = nil
  ) -> Bool {
    let resolvedDraftID = draftID ?? snapshot.context.draftID
    guard snapshot.context.draftID == resolvedDraftID else { return false }

    draftPublishPreviewSnapshots[resolvedDraftID] = snapshot
    if selectedDraftID == resolvedDraftID {
      projectSelectedDraftPublishPreview()
    }
    return true
  }

  /// Removes one draft's cached result and any work bookkeeping belonging to
  /// it. Callers on the body-typing hot path can retain the last selected
  /// projection for display; the removed baseline still prevents that stale
  /// value from being reused by a publish operation.
  @discardableResult
  func removeDraftPublishPreviewSnapshot(
    for draftID: UUID,
    preservingSelectedProjection: Bool = false
  )
    -> DraftPublishPreviewSnapshot?
  {
    let refreshTask = draftPublishPreviewRefreshTasks.removeValue(forKey: draftID)
    refreshTask?.cancel()
    let generation = draftPublishPreviewRefreshGenerations.removeValue(forKey: draftID)
    draftPublishPreviewInputBaselines.removeValue(forKey: draftID)
    let removed = draftPublishPreviewSnapshots.removeValue(forKey: draftID)
    if selectedDraftID == draftID,
      refreshTask != nil || generation != nil || removed != nil
    {
      if preservingSelectedProjection {
        publishPreviewRefreshTask = nil
        publishPreviewRefreshGeneration = 0
        isPublishPreviewRefreshing = false
      } else {
        projectSelectedDraftPublishPreview()
      }
    }
    return removed
  }

  /// Removes all draft-scoped preview values and cancels their outstanding
  /// work. Compatibility fields are then projected from the now-empty cache.
  func removeAllDraftPublishPreviewSnapshots() {
    guard !draftPublishPreviewRefreshTasks.isEmpty
      || !draftPublishPreviewRefreshGenerations.isEmpty
      || !draftPublishPreviewInputBaselines.isEmpty
      || !draftPublishPreviewSnapshots.isEmpty
      || publishPackage != nil
      || localPublishPreview != nil
      || localPublishReadiness != nil
      || remotePublishPreviewSnapshot != nil
      || remoteReviewDraft != nil
    else {
      return
    }
    draftPublishPreviewRefreshTasks.values.forEach { $0.cancel() }
    draftPublishPreviewRefreshTasks.removeAll(keepingCapacity: true)
    draftPublishPreviewRefreshGenerations.removeAll(keepingCapacity: true)
    draftPublishPreviewInputBaselines.removeAll(keepingCapacity: true)
    draftPublishPreviewSnapshots.removeAll(keepingCapacity: true)
    projectSelectedDraftPublishPreview()
  }

  /// Invalidates preview work and cached results for one site while retaining
  /// independent drafts that belong to other profiles.
  func removeDraftPublishPreviewSnapshots(forProfileID profileID: UUID) {
    let draftIDs = Set(
      drafts
        .filter { $0.belongs(toSiteProfileID: profileID) }
        .map(\.id)
        + draftPublishPreviewSnapshots.values
          .filter { $0.context.profileID == profileID }
          .map { $0.context.draftID }
        + draftPublishPreviewInputBaselines
          .filter { $0.value.context.profileID == profileID }
          .map(\.key)
    )
    for draftID in draftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  // MARK: Compatibility aliases for cache lifecycle call sites

  @discardableResult
  func removeDraftPublishPreviewCache(for draftID: UUID) -> DraftPublishPreviewSnapshot? {
    removeDraftPublishPreviewSnapshot(for: draftID)
  }

  func removeAllDraftPublishPreviewCaches() {
    removeAllDraftPublishPreviewSnapshots()
  }

  /// Stores the task handle used by the draft-scoped scheduler and updates
  /// the old `isPublishPreviewRefreshing`/task projection only for the
  /// currently selected draft.
  func setDraftPublishPreviewRefreshTask(
    _ task: Task<Void, Never>?,
    for draftID: UUID
  ) {
    if let task {
      draftPublishPreviewRefreshTasks[draftID] = task
    } else {
      draftPublishPreviewRefreshTasks.removeValue(forKey: draftID)
    }
    if selectedDraftID == draftID {
      projectSelectedDraftPublishPreview()
    }
  }

  /// Advances and returns the generation for one draft without touching the
  /// legacy single-value generation unless that draft is selected.
  @discardableResult
  func advanceDraftPublishPreviewRefreshGeneration(for draftID: UUID) -> UInt64 {
    let generation = (draftPublishPreviewRefreshGenerations[draftID] ?? 0) &+ 1
    draftPublishPreviewRefreshGenerations[draftID] = generation
    if selectedDraftID == draftID {
      projectSelectedDraftPublishPreview()
    }
    return generation
  }

  /// Rehydrates the old five preview values and refresh bookkeeping from the
  /// selected draft's cache entry. A cache for another profile is never shown
  /// as the selected profile's preview. Task state is independently projected
  /// by selected draft ID so a newly started refresh can show progress before
  /// its first complete snapshot is installed.
  func projectSelectedDraftPublishPreview() {
    guard let selectedDraftID else {
      clearProjectedDraftPublishPreview()
      return
    }

    if let snapshot = draftPublishPreviewSnapshots[selectedDraftID],
      snapshot.context.draftID == selectedDraftID,
      snapshot.context.profileID == activeProfileID
    {
      publishPackage = snapshot.publishPackage
      localPublishPreview = snapshot.localPublishPreview
      localPublishReadiness = snapshot.localPublishReadiness
      remotePublishPreviewSnapshot = snapshot.remotePublishPreview
      remoteReviewDraft = snapshot.remoteReviewDraft
    } else {
      publishPackage = nil
      localPublishPreview = nil
      localPublishReadiness = nil
      remotePublishPreviewSnapshot = nil
      remoteReviewDraft = nil
    }

    publishPreviewRefreshTask = draftPublishPreviewRefreshTasks[selectedDraftID]
    publishPreviewRefreshGeneration =
      draftPublishPreviewRefreshGenerations[selectedDraftID] ?? 0
    isPublishPreviewRefreshing = isPublishPreviewRefreshing(for: selectedDraftID)
  }

  private func clearProjectedDraftPublishPreview() {
    publishPackage = nil
    localPublishPreview = nil
    localPublishReadiness = nil
    remotePublishPreviewSnapshot = nil
    remoteReviewDraft = nil
    publishPreviewRefreshTask = nil
    publishPreviewRefreshGeneration = 0
    isPublishPreviewRefreshing = false
  }
}
