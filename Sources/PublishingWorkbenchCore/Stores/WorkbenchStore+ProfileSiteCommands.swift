import Foundation

extension WorkbenchStore {
  public func stopLocalSitePreview() {
    publishingStore.stopLocalSitePreview()
  }

  public func startLocalSitePreview() {
    publishingStore.startLocalSitePreview()
  }

  public func updateActiveProfile(_ update: (inout SiteProfile) -> Void) {
    publishingStore.updateActiveProfile(update, store: self)
    invalidateDraftDerivedCaches()
  }

  public func applySiteKindDefaults(_ siteKind: SiteKind) {
    publishingStore.applySiteKindDefaults(siteKind, store: self)
    invalidateDraftDerivedCaches()
  }

  @discardableResult
  public func createSiteFromStarter(_ request: SiteStarterRequest) -> SiteStarterResult? {
    publishingStore.createSiteFromStarter(request, store: self)
  }

  @discardableResult
  public func importExistingSiteFromStarter(_ request: SiteStarterImportRequest) -> SiteStarterImportResult? {
    publishingStore.importExistingSiteFromStarter(request, store: self)
  }

  @discardableResult
  public func commitAndPushStarterSite() -> SiteStarterPushResult? {
    publishingStore.commitAndPushStarterSite(store: self)
  }

  @discardableResult
  public func createGitHubRepositoryForActiveProfile(
    privateRepository: Bool = false
  ) async -> RemoteRepositoryCreationResult? {
    await publishingStore.createGitHubRepositoryForActiveProfile(privateRepository: privateRepository, store: self)
  }

  public func selectProfile(_ id: UUID) {
    publishingStore.selectProfile(id, store: self)
    repositoryDeploymentCoordinator.refreshTokenAvailability(store: self)
    invalidateDraftDerivedCaches()
  }

  public func selectSection(_ section: WorkspaceSection) {
    publishingStore.selectSection(section)
  }

  public func createProfile(named name: String? = nil) -> SiteProfile {
    publishingStore.createProfile(named: name, store: self)
  }

  public func duplicateActiveProfile() -> SiteProfile {
    publishingStore.duplicateActiveProfile(store: self)
  }

  public var activeProfileDraftCount: Int {
    publishingStore.activeProfileDraftCount()
  }

  public var recentlyDeletedProfile: RecentlyDeletedProfile? {
    publishingStore.recentlyDeletedProfile
  }

  @discardableResult
  public func deleteActiveProfile() -> RecentlyDeletedProfile? {
    publishingStore.deleteActiveProfile(store: self)
  }

  @discardableResult
  public func restoreRecentlyDeletedProfile() -> Bool {
    publishingStore.restoreRecentlyDeletedProfile(store: self)
  }
}
