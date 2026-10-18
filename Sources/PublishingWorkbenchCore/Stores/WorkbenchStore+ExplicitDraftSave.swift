import Foundation

extension WorkbenchStore {
  /// Commits one editor buffer and only that draft's already-bound file writes.
  /// Other drafts retain their queued tasks, failures, and unsaved editor text.
  @discardableResult
  public func saveDraftImmediately(draftID: UUID) -> Bool {
    guard !isPreparingSafeTermination,
      !isRetryingProjectFileWrites,
      !persistenceStore.isRecoveryWriteProtected,
      drafts.contains(where: { $0.id == draftID }),
      !siteDraftFileWritesInProgress.contains(draftID)
    else { return false }

    // An explicit retry must create a synchronous persistence attempt even if
    // an earlier background save had already cleared the dirty indicator.
    persistenceStore.markUnsavedChanges()
    flushDraftBodyEditorBuffer(for: draftID)

    let siteFilesSucceeded = flushPendingSiteDraftFileWrites(targetDraftID: draftID)
    let snapshotSucceeded = persistenceStore.flush(
      input: persistenceStore.persistence.snapshotInput(from: self)
    ) && !persistenceStore.isRecoveryWriteProtected
    let journalSucceeded = flushDraftRecoveryJournal(
      pruningResolvedRecords: siteFilesSucceeded && snapshotSucceeded
    )
    return siteFilesSucceeded && snapshotSucceeded && journalSucceeded
  }
}
