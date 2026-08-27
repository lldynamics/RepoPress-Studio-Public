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
    let summary = publishingStore.importDraftsFromLocalRepository(store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importDraftsFromLocalRepositoryAsync() async -> LocalContentImportMergeSummary {
    let summary = await publishingStore.importDraftsFromLocalRepositoryAsync(store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importMissingDraftsFromLocalRepository() async -> Int {
    let insertedCount = await publishingStore.importMissingDraftsFromLocalRepository(store: self)
    if insertedCount > 0 {
      invalidateDraftDerivedCaches()
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
    }
    return insertedCount
  }

  @discardableResult
  public func importMissingPrivateDraftsFromLocalRepository() async -> Int {
    let insertedCount = await publishingStore.importMissingPrivateDraftsFromLocalRepository(store: self)
    if insertedCount > 0 {
      invalidateDraftDerivedCaches()
    }
    return insertedCount
  }

  @discardableResult
  public func importDraftFromLocalRepository(repositoryPath: String) -> LocalContentImportMergeSummary {
    let summary = publishingStore.importDraftFromLocalRepository(repositoryPath: repositoryPath, store: self)
    invalidateDraftDerivedCaches()
    return summary
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
    let summary = try publishingStore.applyContentMigration(plan, store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>
  ) throws -> LocalContentImportMergeSummary {
    let summary = try publishingStore.applyContentMigration(
      plan,
      selectedDraftIDs: selectedDraftIDs,
      store: self
    )
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func applyContentMigrationAsync(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>
  ) async throws -> LocalContentImportMergeSummary {
    let summary = try await publishingStore.applyContentMigrationAsync(
      plan,
      selectedDraftIDs: selectedDraftIDs,
      store: self
    )
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository() async -> LocalContentImportMergeSummary {
    let summary = await publishingStore.importChangedArticleDraftsFromLocalRepository(store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importRemoteChangedArticleDraftsFromRepository() async -> LocalContentImportMergeSummary {
    let summary = await publishingStore.importRemoteChangedArticleDraftsFromRepository(store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importRemoteArticleDraftsFromRepository(
    repositoryPaths: [String]
  ) async -> LocalContentImportMergeSummary {
    let summary = await publishingStore.importRemoteArticleDraftsFromRepository(
      repositoryPaths: repositoryPaths,
      store: self
    )
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importRemoteDraftFromRepository(repositoryPath: String) async -> LocalContentImportMergeSummary {
    let summary = await publishingStore.importRemoteDraftFromRepository(
      repositoryPath: repositoryPath,
      store: self
    )
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>
  ) -> RemoteArticleAutoImportSummary {
    let summary = publishingStore.autoImportRemoteArticleDrafts(
      remoteFiles: remoteFiles,
      snapshots: snapshots,
      locallyChangedPaths: locallyChangedPaths,
      store: self
    )
    if summary.importedCount > 0 || summary.unchangedCount > 0 {
      invalidateDraftDerivedCaches()
    }
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
    return summary
  }
}
