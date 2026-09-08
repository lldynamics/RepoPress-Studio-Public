import Foundation

extension WorkbenchStore {
  var currentSiteDraftFileSaveFailures: [SiteDraftFileSaveFailure] {
    siteDraftFileSaveFailures.values.filter {
      guard case .failed = siteDraftFileSaveStates[$0.draftID] else { return false }
      return true
    }
  }

  public var siteDraftFileSaveFailureGroups: [SiteDraftFileSaveFailureGroup] {
    SiteDraftFileSaveFailureGroup.grouped(currentSiteDraftFileSaveFailures)
  }

  public var siteDraftFileSaveFailureSummary: String? {
    let groups = siteDraftFileSaveFailureGroups
    guard !groups.isEmpty else { return nil }
    if groups.count == 1 { return groups[0].summary }
    return CoreL10n.format(
      "%d 篇草稿等待写入项目，涉及 %d 个站点。",
      groups.reduce(0) { $0 + $1.failures.count }, Set(groups.map(\.profileID)).count
    )
  }

  /// Re-read the current profile for each failed write. Waiting for outstanding
  /// writes keeps their detached file transactions serialized before the retry.
  /// The result covers project files, the primary snapshot and recovery journal;
  /// termination must still use its separate operation-ledger barrier.
  @discardableResult
  public func retryPendingProjectFileWrites(profileID: UUID? = nil) async -> Bool {
    guard !isRetryingProjectFileWrites, !isPreparingSafeTermination, !persistenceStore.isRecoveryWriteProtected else {
      return false
    }
    isRetryingProjectFileWrites = true
    defer { isRetryingProjectFileWrites = false }
    flushDraftBodyEditorBuffers()
    await waitForPendingSiteDraftFileWrites()

    let retryIDs = siteDraftFileSaveStates.compactMap { draftID, state -> UUID? in
      guard let draft = drafts.first(where: { $0.id == draftID }), !draft.isGeneralDraft,
        profileID == nil || profile(for: draft).id == profileID
      else { return nil }
      switch state {
      case .pending, .failed: return draftID
      case .saved: return nil
      }
    }.sorted { $0.uuidString < $1.uuidString }

    for draftID in retryIDs {
      _ = await writeSiteDraftToProject(draftID: draftID)
    }
    await waitForPendingSiteDraftFileWrites()
    // A callback may have queued a new write for an edit made during the retry.
    var writesSucceeded = retryIDs.allSatisfy { draftID in
      guard drafts.contains(where: { $0.id == draftID }) else { return true }
      guard case .saved = siteDraftFileSaveStates[draftID] else { return false }
      return true
    }
    if currentSiteDraftFileSaveFailures.contains(where: {
      profileID == nil || $0.profileID == profileID
    }) {
      writesSucceeded = false
    }
    let input = persistenceStore.persistence.snapshotInput(from: self)
    let snapshotSucceeded = persistenceStore.flush(input: input)
    let journalSucceeded = flushDraftRecoveryJournal(
      pruningResolvedRecords: writesSucceeded && snapshotSucceeded
        && currentSiteDraftFileSaveFailures.isEmpty
    )
    return writesSucceeded && snapshotSucceeded && journalSucceeded
  }

  /// Validate before replacing the selected site's root. Only that profile's
  /// local path changes; repository identity, file baselines and active-site
  /// selection are preserved. The caller then retries the failed project writes.
  public func changeRepositoryRootForSaveRecovery(profileID: UUID, to url: URL) throws {
    guard !persistenceStore.isRecoveryWriteProtected else {
      throw ProjectFileSaveRecoveryError.recoveryProtected
    }
    guard let index = publishingStore.profiles.firstIndex(where: { $0.id == profileID }) else {
      throw ProjectFileSaveRecoveryError.profileMissing
    }
    var profile = publishingStore.profiles[index]
    try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: url)
    _ = profile.rememberLocalRepositoryRoot(url)
    publishingStore.profiles[index] = profile
    invalidateDraftDerivedCaches()
    scheduleAutosave()
  }
}

private enum ProjectFileSaveRecoveryError: LocalizedError {
  case profileMissing, recoveryProtected

  var errorDescription: String? {
    switch self {
    case .profileMissing: return CoreL10n.text("报错所属的站点已不存在，请重新检查。")
    case .recoveryProtected: return CoreL10n.text("工作台处于恢复保护状态，请先处理恢复问题。")
    }
  }
}
