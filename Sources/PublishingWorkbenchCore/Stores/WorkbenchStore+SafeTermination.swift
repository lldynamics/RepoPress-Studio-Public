import Foundation
import PublishingKnowledgeCore

enum ProjectSaveRecoveryError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self { case .message(let message): return message }
  }
}

struct WorkbenchSafeTerminationProof {
  let snapshot: WorkbenchSnapshot
  let recoveryRecords: Set<DraftRecoveryRecord>
  let ledger: WorkbenchOperationLedgerDocument
  let requiresPrimarySnapshot: Bool
}

extension WorkbenchStore {
  /// Exit has a different contract from publishing: every editor change must
  /// be recoverable locally, while a conflicted checkout is left untouched.
  public func prepareForSafeTermination() async -> WorkbenchTerminationSaveResult {
    guard !isPreparingSafeTermination, !isRetryingProjectFileWrites else {
      return .failed(CoreL10n.text("正在处理项目文件，请稍候再退出。"))
    }
    isPreparingSafeTermination = true
    safeTerminationProof = nil
    defer { isPreparingSafeTermination = false }
    suspendScheduledSiteDraftFileWrites()
    flushDraftBodyEditorBuffers()
    await waitForPendingSiteDraftFileWrites()
    _ = flushPendingSiteDraftFileWrites(retryKnownFailures: false)
    do {
      try persistLocalRecoverySnapshot()
      guard let ledger = await flushOperationLogPersistence(), ledger == operationHistory.document else {
        return .failed(operationLogStatusMessage ?? CoreL10n.text("活动记录尚未安全保存。"))
      }
      // An edit can arrive while the ledger is draining. Capture it too before
      // the caller presents its synchronous final exit choice.
      flushDraftBodyEditorBuffers()
      await waitForPendingDraftWordCountRefreshes()
      _ = flushPendingSiteDraftFileWrites(retryKnownFailures: false)
      try persistLocalRecoverySnapshot()
      safeTerminationProof = WorkbenchSafeTerminationProof(
        snapshot: persistenceStore.persistence.snapshot(from: self),
        recoveryRecords: Set(draftRecoveryRecords.values), ledger: ledger, requiresPrimarySnapshot: true)
      let count = currentSiteDraftFileSaveFailures.count
      return count == 0 ? .saved : .savedLocally(pendingProjectFileCount: count)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Force a complete snapshot even if only the pending-project list changed.
  /// Read the primary file directly: falling back to yesterday's good snapshot
  /// cannot establish that the current editor contents were saved.
  func persistLocalRecoverySnapshot() throws {
    guard !persistenceStore.isRecoveryWriteProtected else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("工作台处于恢复保护状态，请另存恢复包。"))
    }
    let snapshot = persistenceStore.persistence.snapshot(from: self)
    persistenceStore.markUnsavedChanges()
    guard persistenceStore.flush(snapshot: snapshot) else {
      throw ProjectSaveRecoveryError.message(
        persistenceStore.lastSaveError ?? CoreL10n.text("本地草稿保存失败，请另存恢复包。"))
    }
    guard try savedSnapshotMatches(snapshot) else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("本地草稿保存后的校验失败，应用将保持打开。"))
    }
    guard flushDraftRecoveryJournal(pruningResolvedRecords: false) else {
      throw ProjectSaveRecoveryError.message(
        draftRecoveryJournalErrorMessage ?? CoreL10n.text("草稿恢复记录未能保存。"))
    }
  }

  /// UUID-keyed dictionaries encode as alternating key/value arrays; rebuilding
  /// a snapshot can change that order without changing any saved state. Compare
  /// decoded values, using the same date precision as the persistence codec.
  private func savedSnapshotMatches(_ snapshot: WorkbenchSnapshot) throws -> Bool {
    let expectedData = try JSONEncoder.workbench.encode(snapshot)
    let expected = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: expectedData)
    let actual = try persistenceStore.persistence.loadPrimarySnapshot()
    return actual == expected
  }

  /// Emergency export bypasses the broken primary location and never retries
  /// checkout writes. It uses the existing integrity-checked portable format.
  public func exportSafeTerminationRecovery(at destinationURL: URL) async throws -> URL {
    guard !isPreparingSafeTermination, !isRetryingProjectFileWrites else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("正在处理项目文件，请稍候再退出。"))
    }
    isPreparingSafeTermination = true
    safeTerminationProof = nil
    defer { isPreparingSafeTermination = false }
    suspendScheduledSiteDraftFileWrites()
    flushDraftBodyEditorBuffers()
    await waitForPendingSiteDraftFileWrites()
    // Drain the ledger queue even when its original location cannot be written.
    // The recovery package itself becomes the durability barrier for these records.
    _ = await flushOperationLogPersistence()
    let ledger = operationHistory.document
    flushDraftBodyEditorBuffers()
    await waitForPendingDraftWordCountRefreshes()
    let frozen = persistenceStore.persistence.snapshot(from: self)
    let records = Array(draftRecoveryRecords.values)
    var snapshot = frozen
    for record in records where !snapshot.drafts.contains(where: {
      $0.id == record.draftID && $0.bodyMarkdown == record.recoveredBodyMarkdown
    }) {
      var recovered = record.makeDraft()
      recovered.assignToGeneralDraft(editingProfileID: snapshot.activeProfileID)
      recovered.title += CoreL10n.text("（恢复副本）")
      snapshot.drafts.append(recovered)
    }
    let exportSnapshot = snapshot
    let knowledgeRootURL = knowledge.rootURL
    let rssURL = rssReaderFileURL
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    let preview = try await Task.detached(priority: .userInitiated) {
      try WorkspaceBackupService().createBackup(
        at: destinationURL, snapshot: exportSnapshot, operationHistoryDocument: ledger,
        knowledgeRootURL: knowledgeRootURL, rssDatabaseURL: rssURL,
        rssMediaDirectoryURL: rssURL.map { RSSReaderStore.mediaCacheDirectoryURL(for: $0) },
        applicationVersion: version
      )
    }.value
    guard preview.unresolvedAttachmentCount == 0 else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("恢复包中仍有无法打包的附件。恢复包已保留，请修复附件后重新导出。"))
    }
    flushDraftBodyEditorBuffers()
    guard persistenceStore.persistence.snapshot(from: self) == frozen,
      Set(draftRecoveryRecords.values) == Set(records), operationHistory.document == ledger
    else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("导出期间草稿发生变化，恢复包已保留；请重新导出后退出。"))
    }
    safeTerminationProof = WorkbenchSafeTerminationProof(
      snapshot: frozen, recoveryRecords: Set(records), ledger: ledger, requiresPrimarySnapshot: false)
    return preview.backupURL
  }

  /// AppKit modal dialogs run a nested event loop. Verify the saved state again
  /// synchronously after the final choice, immediately before replying to quit.
  public func validatePreparedSafeTermination() -> Bool {
    flushDraftBodyEditorBuffers()
    guard let proof = safeTerminationProof,
      !isPreparingSafeTermination, !isRetryingProjectFileWrites,
      siteDraftFileWritesInProgress.isEmpty, siteDraftFileAutosaveTasks.isEmpty,
      persistenceStore.persistence.snapshot(from: self) == proof.snapshot,
      Set(draftRecoveryRecords.values) == proof.recoveryRecords,
      operationHistory.document == proof.ledger
    else { return false }
    if proof.requiresPrimarySnapshot {
      guard !persistenceStore.isRecoveryWriteProtected,
        (try? savedSnapshotMatches(proof.snapshot)) == true else { return false }
    }
    return true
  }
}
