import Foundation

extension WorkbenchStore {
  public func scanRepositoryAsync() async {
    await repositoryStore.scanRepositoryAsync(store: self)
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
  public func importDraftFromLocalRepository(repositoryPath: String) -> LocalContentImportMergeSummary {
    let summary = publishingStore.importDraftFromLocalRepository(repositoryPath: repositoryPath, store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  public func makeContentMigrationPlan(sourceURL: URL) async throws -> ContentMigrationPlan {
    try await publishingStore.makeContentMigrationPlan(sourceURL: sourceURL, store: self)
  }

  @discardableResult
  public func applyContentMigration(_ plan: ContentMigrationPlan) throws -> LocalContentImportMergeSummary {
    let summary = try publishingStore.applyContentMigration(plan, store: self)
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
  public func importRemoteChangedArticleDraftsFromRepository() -> LocalContentImportMergeSummary {
    let summary = publishingStore.importRemoteChangedArticleDraftsFromRepository(store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importRemoteDraftFromRepository(repositoryPath: String) -> LocalContentImportMergeSummary {
    let summary = publishingStore.importRemoteDraftFromRepository(repositoryPath: repositoryPath, store: self)
    invalidateDraftDerivedCaches()
    return summary
  }
}
