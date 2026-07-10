import Foundation

extension WorkbenchStore {
  @available(*, deprecated, message: "Use scanRepositoryAsync() or store.repository.scanAsync() so repository scanning stays off the main actor.")
  public func scanRepository() {
    repositoryStore.scanRepository(store: self)
  }

  public func scanRepositoryAsync() async {
    await repositoryStore.scanRepositoryAsync(store: self)
  }

  public func cancelRepositoryScan() {
    repositoryStore.cancelRepositoryScan()
  }

  @available(*, deprecated, message: "Use rememberRepositoryRootAsync(_:) or store.repository.rememberRootAsync(_:) so repository scanning stays off the main actor.")
  public func rememberRepositoryRoot(_ url: URL) {
    repositoryStore.rememberRepositoryRoot(url, store: self)
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
  public func importDraftFromLocalRepository(repositoryPath: String) -> LocalContentImportMergeSummary {
    let summary = publishingStore.importDraftFromLocalRepository(repositoryPath: repositoryPath, store: self)
    invalidateDraftDerivedCaches()
    return summary
  }

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository() -> LocalContentImportMergeSummary {
    let summary = publishingStore.importChangedArticleDraftsFromLocalRepository(store: self)
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
