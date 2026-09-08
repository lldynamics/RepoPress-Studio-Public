import Foundation

extension WorkbenchStore {
  /// Applies a frozen metadata-only plan after re-reading every affected field.
  /// A conflict in any selected article rejects the batch before versions or
  /// writes are created; callers must create a fresh preview.
  @discardableResult
  public func applyMetadataBatchMaintenance(
    _ plan: MetadataBatchMaintenancePlan,
    selectedDraftIDs: Set<UUID>
  ) -> MetadataBatchMaintenanceApplyOutcome {
    let previews = plan.applicablePreviews.filter { selectedDraftIDs.contains($0.documentID) }
    guard !previews.isEmpty else { return .noChanges }

    // Do not mix this batch with a prior unsaved workspace state. In
    // particular, versions are meaningful only after their baseline has been
    // synchronously committed.
    guard flushPendingChanges() else { return .preflightPersistenceFailed }

    let currentByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    let knownProfileIDs = Set(profiles.map(\.id))
    let unavailable = previews.compactMap { preview -> UUID? in
      guard let current = currentByID[preview.documentID],
        current.siteProfileID == preview.siteProfileID,
        current.scope == preview.scope,
        knownProfileIDs.contains(current.siteProfileID)
      else {
        return preview.documentID
      }
      return nil
    }
    guard unavailable.isEmpty else { return .unavailable(unavailable) }

    let service = MetadataBatchMaintenanceService()
    let conflicts = previews.compactMap { preview -> UUID? in
      guard let current = currentByID[preview.documentID] else { return preview.documentID }
      return service.values(for: current, field: plan.field) == preview.originalValues
        ? nil
        : preview.documentID
    }
    guard conflicts.isEmpty else { return .conflicts(conflicts) }

    let updatedByID = Dictionary(
      uniqueKeysWithValues: previews.compactMap { preview -> (UUID, ArticleDraft)? in
        guard var draft = currentByID[preview.documentID] else { return nil }
        switch plan.field {
        case .tags: draft.tags = preview.proposedValues
        case .categories: draft.categories = preview.proposedValues
        }
        draft.markUpdated(replacing: currentByID[preview.documentID]!)
        return (draft.id, draft)
      })
    let changedIDs = Set(updatedByID.keys)

    guard let versionCount = prepareRetainedBatchRecoveryVersions(for: changedIDs) else {
      return .insufficientRecoveryVersions
    }
    guard flushPendingChanges() else { return .recoveryVersionPersistenceFailed }

    publishingStore.drafts = publishingStore.drafts.map { updatedByID[$0.id] ?? $0 }
    for draft in publishingStore.drafts where changedIDs.contains(draft.id) {
      // Metadata mutation deliberately leaves a dirty body buffer untouched.
      scheduleSiteDraftFileAutosave(for: draft)
    }
    invalidateDraftDerivedCaches()
    refreshPreflightForSelection()
    // Direct collection replacement deliberately bypasses PublishingStore's
    // normal autosave hook. Schedule a snapshot before the forced flush.
    save()

    guard flushPendingChanges() else {
      // Do not restore an old draft array here: some site Markdown files may
      // already have been written, and replacing whole drafts could erase a
      // newer repository binding. The synchronously persisted recovery version
      // remains the only safe, explicit recovery path.
      return .persistenceFailed(recoveryVersionCount: versionCount)
    }
    return .applied(changedCount: changedIDs.count, versionCount: versionCount)
  }
}
