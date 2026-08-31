import Foundation

extension WorkbenchStore {
  public func scanRepositoryAsync() async {
    await repositoryStore.scanRepositoryAsync(store: self)
    _ = await importMissingDraftsFromLocalRepository()
  }

  public func requestRepositoryScan() {
    Task { [weak self] in
      guard let self else { return }
      await self.scanRepositoryAsync()
    }
  }

  public func cancelRepositoryScan() {
    repositoryStore.cancelRepositoryScan()
  }

  public func rememberRepositoryRootAsync(_ url: URL) async {
    await repositoryStore.rememberRepositoryRootAsync(url, store: self)
    _ = await importMissingDraftsFromLocalRepository()
  }

  public var repositorySyncCommandPlan: RepositorySyncCommandPlan? {
    repositoryStore.repositorySyncCommandPlan(store: self)
  }

  public var repositoryAutoSyncReviewMarkdown: String {
    repositoryStore.repositoryAutoSyncReviewMarkdown
  }

  public func updateRepositoryAutoSyncSettings(_ settings: RepositoryAutoSyncSettings) {
    repositoryStore.updateRepositoryAutoSyncSettings(settings, store: self)
  }

  @discardableResult
  public func importDraftsFromLocalRepository() -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult = publishingStore.importDraftsFromLocalRepositoryOperation(store: self)
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID)
    return operationResult.summary
  }

  @discardableResult
  public func importDraftsFromLocalRepositoryAsync() async -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult = await publishingStore.importDraftsFromLocalRepositoryAsyncOperation(
      store: self
    )
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID)
    return operationResult.summary
  }

  @discardableResult
  public func importMissingDraftsFromLocalRepository() async -> Int {
    let insertedCount = await publishingStore.importMissingDraftsFromLocalRepository(store: self)
    if insertedCount > 0 {
      invalidateDraftDerivedCaches()
      recordContentImport(
        LocalContentImportOperationResult(
          summary: LocalContentImportMergeSummary(
            insertedCount: insertedCount,
            updatedCount: 0,
            skippedCount: 0
          ),
          outcome: .succeeded
        ),
        profileID: activeProfileID,
        actor: .background
      )
    }
    return insertedCount
  }

  /// Imports only external Markdown paths reported by the repository content
  /// monitor. Known draft paths are filtered in the publishing store before
  /// parsing, preserving the full-scan method for explicit/manual discovery.
  @discardableResult
  public func importMissingDraftsFromLocalRepository(repositoryPaths: [String]) async -> Int {
    let insertedCount = await publishingStore.importMissingDraftsFromLocalRepository(
      repositoryPaths: repositoryPaths,
      store: self
    )
    if insertedCount > 0 {
      invalidateDraftDerivedCaches()
      recordContentImport(
        LocalContentImportOperationResult(
          summary: LocalContentImportMergeSummary(
            insertedCount: insertedCount,
            updatedCount: 0,
            skippedCount: 0
          ),
          outcome: .succeeded
        ),
        profileID: activeProfileID,
        actor: .background
      )
    }
    return insertedCount
  }

  @discardableResult
  public func importMissingPrivateDraftsFromLocalRepository() async -> Int {
    let insertedCount = await publishingStore.importMissingPrivateDraftsFromLocalRepository(store: self)
    if insertedCount > 0 {
      invalidateDraftDerivedCaches()
      recordContentImport(
        LocalContentImportOperationResult(
          summary: LocalContentImportMergeSummary(
            insertedCount: insertedCount,
            updatedCount: 0,
            skippedCount: 0
          ),
          outcome: .succeeded
        ),
        profileID: activeProfileID,
        actor: .background
      )
    }
    return insertedCount
  }

  @discardableResult
  public func importDraftFromLocalRepository(repositoryPath: String) -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult = publishingStore.importDraftFromLocalRepositoryOperation(
      repositoryPath: repositoryPath,
      store: self
    )
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID)
    return operationResult.summary
  }

  public func makeContentMigrationPlan(sourceURL: URL) async throws -> ContentMigrationPlan {
    try await publishingStore.makeContentMigrationPlan(sourceURL: sourceURL, store: self)
  }

  public func refreshContentMigrationPlanReview(_ plan: ContentMigrationPlan) -> ContentMigrationPlan {
    publishingStore.refreshContentMigrationPlanReview(plan, store: self)
  }

  public func refreshContentMigrationPlanReviewAsync(
    _ plan: ContentMigrationPlan
  ) async throws -> ContentMigrationPlan {
    try await publishingStore.refreshContentMigrationPlanReviewAsync(plan, store: self)
  }

  @discardableResult
  public func applyContentMigration(_ plan: ContentMigrationPlan) throws -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    do {
      let summary = try publishingStore.applyContentMigration(plan, store: self)
      invalidateDraftDerivedCaches()
      recordContentImport(
        completedContentImportResult(summary),
        profileID: profileID,
        kind: .contentMigration
      )
      return summary
    } catch {
      recordContentImportFailure(error, profileID: profileID, kind: .contentMigration)
      throw error
    }
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>
  ) throws -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    do {
      let summary = try publishingStore.applyContentMigration(
        plan,
        selectedDraftIDs: selectedDraftIDs,
        store: self
      )
      invalidateDraftDerivedCaches()
      recordContentImport(
        completedContentImportResult(summary),
        profileID: profileID,
        kind: .contentMigration
      )
      return summary
    } catch {
      recordContentImportFailure(error, profileID: profileID, kind: .contentMigration)
      throw error
    }
  }

  @discardableResult
  public func applyContentMigrationAsync(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>
  ) async throws -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    do {
      let summary = try await publishingStore.applyContentMigrationAsync(
        plan,
        selectedDraftIDs: selectedDraftIDs,
        store: self
      )
      invalidateDraftDerivedCaches()
      recordContentImport(
        completedContentImportResult(summary),
        profileID: profileID,
        kind: .contentMigration
      )
      return summary
    } catch {
      recordContentImportFailure(error, profileID: profileID, kind: .contentMigration)
      throw error
    }
  }

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository() async -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult =
      await publishingStore.importChangedArticleDraftsFromLocalRepositoryOperation(store: self)
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID)
    return operationResult.summary
  }

  @discardableResult
  public func importRemoteChangedArticleDraftsFromRepository() async -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult =
      await publishingStore.importRemoteChangedArticleDraftsFromRepositoryOperation(store: self)
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID, kind: .remoteContentImport)
    return operationResult.summary
  }

  @discardableResult
  public func importRemoteArticleDraftsFromRepository(
    repositoryPaths: [String]
  ) async -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult = await publishingStore.importRemoteArticleDraftsFromRepositoryOperation(
      repositoryPaths: repositoryPaths,
      store: self
    )
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID, kind: .remoteContentImport)
    return operationResult.summary
  }

  @discardableResult
  public func importRemoteDraftFromRepository(repositoryPath: String) async -> LocalContentImportMergeSummary {
    let profileID = activeProfileID
    let operationResult = await publishingStore.importRemoteDraftFromRepositoryOperation(
      repositoryPath: repositoryPath,
      store: self
    )
    invalidateDraftDerivedCaches()
    recordContentImport(operationResult, profileID: profileID, kind: .remoteContentImport)
    return operationResult.summary
  }

  @discardableResult
  func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>
  ) -> RemoteArticleAutoImportSummary {
    let profileID = activeProfileID
    let summary = publishingStore.autoImportRemoteArticleDrafts(
      remoteFiles: remoteFiles,
      snapshots: snapshots,
      locallyChangedPaths: locallyChangedPaths,
      store: self
    )
    if summary.importedCount > 0 || summary.unchangedCount > 0 {
      invalidateDraftDerivedCaches()
    }
    recordRemoteAutoImport(summary, profileID: profileID)
    return summary
  }

  @discardableResult
  func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    profileID: UUID
  ) -> RemoteArticleAutoImportSummary {
    let summary = publishingStore.autoImportRemoteArticleDrafts(
      remoteFiles: remoteFiles,
      snapshots: snapshots,
      locallyChangedPaths: locallyChangedPaths,
      profileID: profileID,
      store: self
    )
    if summary.importedCount > 0 || summary.unchangedCount > 0 {
      invalidateDraftDerivedCaches()
    }
    recordRemoteAutoImport(summary, profileID: profileID)
    return summary
  }

  private func recordContentImport(
    _ result: LocalContentImportOperationResult,
    profileID: UUID,
    actor: WorkbenchOperationLogActor = .user,
    kind: WorkbenchOperationEventKind = .localContentImport
  ) {
    _ = recordOperationEvent(
      WorkbenchOperationEventRecord(
        kind: kind,
        outcome: result.outcome,
        actor: actor,
        profileID: profileID,
        createdItemCount: result.summary.insertedCount,
        updatedItemCount: result.summary.updatedCount,
        skippedItemCount: result.summary.skippedCount
      )
    )
  }

  private func completedContentImportResult(
    _ summary: LocalContentImportMergeSummary
  ) -> LocalContentImportOperationResult {
    LocalContentImportOperationResult(
      summary: summary,
      outcome: summary.changedCount > 0 ? .succeeded : .recorded
    )
  }

  private func recordContentImportFailure(
    _ error: Error,
    profileID: UUID,
    kind: WorkbenchOperationEventKind
  ) {
    _ = recordOperationEvent(
      WorkbenchOperationEventRecord(
        kind: kind,
        outcome: error is CancellationError ? .cancelled : .failed,
        profileID: profileID
      )
    )
  }

  private func recordRemoteAutoImport(
    _ summary: RemoteArticleAutoImportSummary,
    profileID: UUID
  ) {
    let skippedCount = summary.unchangedCount + summary.pendingReviewCount
    guard summary.importedCount > 0 || skippedCount > 0 || !summary.failedPaths.isEmpty else {
      return
    }
    let outcome: WorkbenchOperationLogOutcome
    if summary.importedCount > 0, summary.pendingReviewCount > 0 {
      outcome = .partial
    } else if summary.importedCount > 0 {
      outcome = .succeeded
    } else if !summary.failedPaths.isEmpty {
      outcome = .failed
    } else {
      outcome = .recorded
    }
    _ = recordOperationEvent(
      WorkbenchOperationEventRecord(
        kind: .remoteContentImport,
        outcome: outcome,
        actor: .background,
        profileID: profileID,
        createdItemCount: summary.insertedCount,
        updatedItemCount: summary.updatedCount,
        skippedItemCount: skippedCount
      )
    )
  }
}
