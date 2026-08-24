import Foundation

extension WorkbenchStore {
  func recordDraftRecovery(for draft: ArticleDraft, bodyMarkdown: String) {
    if let existingRecord = draftRecoveryRecords[draft.id],
       existingRecord.recoveredBodyMarkdown != bodyMarkdown,
       pendingDraftRecoveries.contains(where: { $0.draftID == existingRecord.draftID }),
       !materializePendingRecoveryBeforeEditing(existingRecord) {
      return
    }

    guard bodyMarkdown != draft.bodyMarkdown else {
      removeDraftRecovery(draftID: draft.id, persistImmediately: false)
      return
    }

    draftRecoveryRecords[draft.id] = DraftRecoveryRecord(
      draft: draft,
      recoveredBodyMarkdown: bodyMarkdown
    )
    scheduleDraftRecoveryJournalWrite()
  }

  @discardableResult
  public func restoreDraftRecovery(_ record: DraftRecoveryRecord) -> Bool {
    guard let currentRecord = draftRecoveryRecords[record.draftID] else { return false }

    if let currentIndex = drafts.firstIndex(where: { $0.id == currentRecord.draftID }) {
      let currentDraft = drafts[currentIndex]
      if currentDraft.bodyMarkdown == currentRecord.recoveredBodyMarkdown {
        guard persistRestoredDraftBeforeRemovingRecovery() else { return false }
        removeDraftRecovery(draftID: currentRecord.draftID, persistImmediately: true)
        return true
      }

      if currentDraft.bodyMarkdown == currentRecord.baselineBodyMarkdown {
        var restored = currentDraft
        restored.bodyMarkdown = currentRecord.recoveredBodyMarkdown
        publishingStore.updateDraft(restored, store: self)
        guard persistRestoredDraftBeforeRemovingRecovery() else { return false }
        removeDraftRecovery(draftID: currentRecord.draftID, persistImmediately: true)
        return true
      }

      let previousSelectedDraftID = selectedDraftID
      let recoveredCopy = makeRecoveredDraft(
        from: currentRecord,
        titleSuffix: CoreL10n.text("（恢复副本）")
      )
      publishingStore.drafts.insert(recoveredCopy, at: 0)
      _ = publishingStore.focusDraft(recoveredCopy.id, section: .writing, store: self)
      guard persistRestoredDraftBeforeRemovingRecovery() else {
        publishingStore.drafts.removeAll { $0.id == recoveredCopy.id }
        if let previousSelectedDraftID {
          _ = publishingStore.focusDraft(previousSelectedDraftID, section: .writing, store: self)
        }
        return false
      }
      removeDraftRecovery(draftID: currentRecord.draftID, persistImmediately: true)
      return true
    }

    let previousSelectedDraftID = selectedDraftID
    let recoveredDraft = makeRecoveredDraft(
      from: currentRecord,
      titleSuffix: CoreL10n.text("（恢复草稿）")
    )
    publishingStore.drafts.insert(recoveredDraft, at: 0)
    _ = publishingStore.focusDraft(recoveredDraft.id, section: .writing, store: self)
    guard persistRestoredDraftBeforeRemovingRecovery() else {
      publishingStore.drafts.removeAll { $0.id == recoveredDraft.id }
      if let previousSelectedDraftID {
        _ = publishingStore.focusDraft(previousSelectedDraftID, section: .writing, store: self)
      }
      return false
    }
    removeDraftRecovery(draftID: currentRecord.draftID, persistImmediately: true)
    return true
  }

  public func discardDraftRecovery(_ record: DraftRecoveryRecord) {
    removeDraftRecovery(draftID: record.draftID, persistImmediately: true)
  }

  private func removeDraftRecovery(draftID: UUID, persistImmediately: Bool) {
    guard draftRecoveryRecords.removeValue(forKey: draftID) != nil else { return }
    refreshPendingDraftRecoveries()
    if persistImmediately {
      flushDraftRecoveryJournal()
    } else {
      scheduleDraftRecoveryJournalWrite()
    }
  }

  private func persistRestoredDraftBeforeRemovingRecovery() -> Bool {
    persistenceStore.markUnsavedChanges()
    let didPersist = persistenceStore.flush(
      snapshot: persistenceStore.persistence.snapshot(from: self)
    )
    return didPersist && !persistenceStore.isRecoveryWriteProtected
  }

  private func materializePendingRecoveryBeforeEditing(
    _ record: DraftRecoveryRecord
  ) -> Bool {
    let recoveredCopy = makeRecoveredDraft(
      from: record,
      titleSuffix: CoreL10n.text("（恢复副本）")
    )
    publishingStore.drafts.insert(recoveredCopy, at: 0)
    persistenceStore.markUnsavedChanges()
    let didPersist = persistenceStore.flush(
      snapshot: persistenceStore.persistence.snapshot(from: self)
    )
    guard didPersist, !persistenceStore.isRecoveryWriteProtected else {
      publishingStore.drafts.removeAll { $0.id == recoveredCopy.id }
      return false
    }

    draftRecoveryRecords.removeValue(forKey: record.draftID)
    refreshPendingDraftRecoveries()
    scheduleDraftRecoveryJournalWrite()
    return true
  }

  private func makeRecoveredDraft(
    from record: DraftRecoveryRecord,
    titleSuffix: String
  ) -> ArticleDraft {
    var recoveredDraft = record.makeDraft()
    let referencedProfileExists: Bool
    switch recoveredDraft.scope {
    case .site(let profileID):
      referencedProfileExists = profiles.contains { $0.id == profileID }
    case .general:
      referencedProfileExists = profiles.contains { $0.id == recoveredDraft.siteProfileID }
    }
    if !referencedProfileExists {
      // Keep the original recovery record intact while Profile deletion can
      // still be undone. If the user restores first, use the active Profile
      // only as an editing context and remove every repository binding.
      recoveredDraft.assignToGeneralDraft(editingProfileID: activeProfileID)
    }
    recoveredDraft.title = "\(record.title)\(titleSuffix)"
    recoveredDraft.detachFromRepository()
    return recoveredDraft
  }

  func refreshPendingDraftRecoveries() {
    let next = draftRecoveryRecords.values
      .filter { record in
        drafts.first(where: { $0.id == record.draftID })?.bodyMarkdown
          != record.recoveredBodyMarkdown
      }
      .sorted { $0.capturedAt > $1.capturedAt }
    guard Set(next.map(\.id)) != Set(pendingDraftRecoveries.map(\.id)) else { return }
    pendingDraftRecoveries = next
  }
}
