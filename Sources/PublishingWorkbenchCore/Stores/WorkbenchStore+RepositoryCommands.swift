import Foundation

extension WorkbenchStore {
  public func applyDetectedRepositoryRemote() {
    repositoryStore.applyDetectedRepositoryRemote(store: self)
  }

  public func setRepositoryProvider(_ provider: RepositoryProvider) {
    repositoryStore.setRepositoryProvider(provider, store: self)
  }

  @discardableResult
  public func saveRepositoryAccessToken(_ token: String) -> Bool {
    repositoryStore.saveRepositoryAccessToken(token, store: self)
  }

  public func refreshRepositoryTokenAvailability() {
    repositoryStore.refreshRepositoryTokenAvailability(store: self)
  }

  public func refreshRepositoryTokenAvailability(updatesMessage: Bool) {
    repositoryStore.refreshRepositoryTokenAvailability(updatesMessage: updatesMessage, store: self)
  }

  public func deleteRepositoryAccessToken() {
    repositoryStore.deleteRepositoryAccessToken(store: self)
  }

  @discardableResult
  public func checkRepositoryTokenAccess() async -> RemoteRepositoryAccessCheck? {
    await repositoryStore.checkRepositoryTokenAccess(store: self)
  }

  public var activeRemoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? {
    repositoryStore.activeRemoteRepositoryAccessCheck(store: self)
  }

  public var hasStaleRemoteRepositoryAccessCheckForActiveProfile: Bool {
    repositoryStore.hasStaleRemoteRepositoryAccessCheckForActiveProfile(store: self)
  }

  @discardableResult
  public func createRemoteRepositoryForActiveProfile(
    privateRepository: Bool = true
  ) async -> RemoteRepositoryCreationResult? {
    await repositoryStore.createRemoteRepositoryForActiveProfile(privateRepository: privateRepository, store: self)
  }

  public func switchActiveProfileRepositoryBranch(to branchName: String) async {
    await repositoryStore.switchActiveProfileRepositoryBranch(to: branchName, store: self)
  }

  public func createAndSwitchActiveProfileRepositoryBranch(
    name branchName: String,
    from sourceBranch: String? = nil
  ) async {
    await repositoryStore.createAndSwitchActiveProfileRepositoryBranch(
      name: branchName,
      from: sourceBranch,
      store: self
    )
  }

  @discardableResult
  public func tickRepositoryAutoSync(now: Date = Date()) async -> Bool {
    await repositoryStore.tickRepositoryAutoSync(store: self, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(now: Date = Date()) async -> Bool {
    await repositoryStore.runRepositoryAutoSync(store: self, now: now)
  }
}
