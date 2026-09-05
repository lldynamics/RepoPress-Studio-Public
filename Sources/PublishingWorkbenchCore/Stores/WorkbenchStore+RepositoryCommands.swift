import Foundation
import PublishingGitCore

extension WorkbenchStore {
  public func prepareRepositorySafeSync() async -> RepositorySafeSyncPreparation? {
    await repositoryStore.prepareRepositorySafeSync(store: self)
  }

  public func applyRepositorySafeSync(
    _ confirmation: RepositorySafeSyncConfirmation
  ) async -> RepositorySafeSyncResult? {
    await repositoryStore.applyRepositorySafeSync(confirmation, store: self)
  }

  public func prepareRepositoryRebaseSync() async -> RepositoryRebaseSyncPreparation? {
    await repositoryStore.prepareRepositoryRebaseSync(store: self)
  }

  public func applyRepositoryRebaseSync(
    _ confirmation: RepositoryRebaseSyncConfirmation
  ) async -> RepositoryRebaseSyncResult? {
    await repositoryStore.applyRepositoryRebaseSync(confirmation, store: self)
  }

  @discardableResult
  public func completeRepositoryOperation(
    mergeMessage: String = "Merge remote changes"
  ) async -> Bool {
    await repositoryStore.completeRepositoryOperation(
      mergeMessage: mergeMessage,
      store: self
    )
  }

  @discardableResult
  public func abortRepositoryOperation() async -> Bool {
    await repositoryStore.abortRepositoryOperation(store: self)
  }

  @discardableResult
  public func finishRepositoryStashConflictRecovery() async -> Bool {
    await repositoryStore.finishRepositoryStashConflictRecovery(store: self)
  }

  @discardableResult
  public func discardRepositoryRebaseRecoveryRecord() async -> Bool {
    await repositoryStore.discardRepositoryRebaseRecoveryRecord(store: self)
  }

  @discardableResult
  public func restoreRepositoryRebaseWIP() async -> Bool {
    await repositoryStore.restoreRepositoryRebaseWIP(store: self)
  }

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

  /// Performs a read-only permission check only when the active profile has no
  /// fresh proof, then requires confirmed write access before a remote publish.
  public func ensureRemoteRepositoryWriteAccess(for profile: SiteProfile) async -> Bool {
    await repositoryStore.ensureRemoteRepositoryWriteAccess(for: profile, store: self)
  }

  /// Fetches only remote-tracking metadata, then rebuilds the repository
  /// report used by publish previews. It never pulls, merges, rebases, or
  /// changes the user's working tree.
  @discardableResult
  public func refreshRepositoryStateForPublishing() async -> RepositoryFetchResult? {
    await repositoryStore.refreshRepositoryStateForPublishing(store: self)
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

  @discardableResult
  public func tickRepositoryAutoSync(for profileID: UUID, now: Date = Date()) async -> Bool {
    await repositoryStore.tickRepositoryAutoSync(for: profileID, store: self, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(for profileID: UUID, now: Date = Date()) async -> Bool {
    await repositoryStore.runRepositoryAutoSync(for: profileID, store: self, now: now)
  }

  public func updateRepositoryAutoSyncSettings(
    _ settings: RepositoryAutoSyncSettings,
    for profileID: UUID
  ) {
    repositoryStore.updateRepositoryAutoSyncSettings(settings, for: profileID, store: self)
  }

  /// Prepares a read-only confirmation covering every pending worktree change.
  public func prepareRepositoryWorktreePublish(
    commitMessage: String = "Publish all site changes"
  ) async -> RepositoryWorktreePublishConfirmation? {
    await repositoryStore.prepareRepositoryWorktreePublish(
      store: self,
      commitMessage: commitMessage
    )
  }

  /// Publishes only the previously frozen complete-worktree confirmation.
  public func publishRepositoryWorktree(
    _ confirmation: RepositoryWorktreePublishConfirmation
  ) async -> RepositoryWorktreePublishResult? {
    await repositoryStore.publishRepositoryWorktree(confirmation, store: self)
  }
}
