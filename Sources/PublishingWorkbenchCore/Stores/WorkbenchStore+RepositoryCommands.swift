import Foundation

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

  public func prepareRepositoryWorktreePublish(
    commitMessage: String = "Publish all site changes"
  ) async -> RepositoryWorktreePublishConfirmation? {
    guard
      let confirmation = await repositoryStore.prepareRepositoryWorktreePublish(
        store: self,
        commitMessage: commitMessage
      )
    else { return nil }
    return RepositoryWorktreePublishConfirmation(
      snapshot: confirmation.snapshot,
      commitMessage: confirmation.commitMessage,
      safetyReport: confirmation.safetyReport,
      sitePreflightResult: confirmation.sitePreflightResult,
      articleVerificationTarget: repositoryWorktreeArticleVerificationTarget(
        for: confirmation,
        profile: activeProfile
      )
    )
  }

  public func publishRepositoryWorktree(
    _ confirmation: RepositoryWorktreePublishConfirmation
  ) async -> RepositoryWorktreePublishResult? {
    let profile = activeProfile
    guard
      let result = await repositoryStore.publishRepositoryWorktree(
        confirmation,
        store: self
      )
    else { return nil }

    let record = ReleaseRecord.repositoryWorktreePublish(
      profile: profile,
      result: result,
      articleTarget: confirmation.articleVerificationTarget
    )
    publishingStore.prependReleaseRecord(record)
    save()

    var deploymentStatus: DeploymentStatusSnapshot?
    if shouldRefreshDeploymentStatusAfterRemoteOperation(record) {
      setPublishActionMessage(
        CoreL10n.text("Git 推送已确认，正在等待部署与文章页面验证…"),
        status: .inProgress
      )
      deploymentStatus = await boundedRepositoryWorktreeDeploymentVerification(
        record: record,
        articleTarget: confirmation.articleVerificationTarget
      )
    }

    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: confirmation.articleVerificationTarget,
      deploymentStatus: deploymentStatus
    )
    if outcome.articleVerified,
      let draftID = confirmation.articleVerificationTarget?.draftID
    {
      markDraftsAsPublishedIfDirectRemoteCommit(
        mode: .directCommit,
        draftIDs: [draftID]
      )
    }
    if activeProfileID == profile.id {
      setPublishActionMessage(outcome.feedback.message, status: outcome.feedback.status)
    }
    save()
    return result
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

  @discardableResult
  public func createRemoteRepositoryForActiveProfile(
    privateRepository: Bool = true
  ) async -> RemoteRepositoryCreationResult? {
    await repositoryStore.createRemoteRepositoryForActiveProfile(
      privateRepository: privateRepository,
      store: self
    )
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

  private func repositoryWorktreeArticleVerificationTarget(
    for confirmation: RepositoryWorktreePublishConfirmation,
    profile: SiteProfile
  ) -> RepositoryWorktreeArticleVerificationTarget? {
    guard let draft = selectedDraft,
      draft.belongs(toSiteProfileID: profile.id),
      !draft.draft,
      draft.visibility == .public
    else { return nil }
    let markdownPath = profile.markdownPath(for: draft).normalizedRelativePath()
    guard confirmation.snapshot.paths.contains(markdownPath) else { return nil }
    let coverAltText = draft.coverAttachmentID.flatMap { coverID in
      draft.attachments.first(where: { $0.id == coverID })?.altText
        .trimmedForPublishing.nilIfEmpty
    }
    return RepositoryWorktreeArticleVerificationTarget(
      draftID: draft.id,
      title: draft.title,
      summary: draft.summary,
      coverAltText: coverAltText,
      markdownPath: markdownPath
    )
  }

  private func boundedRepositoryWorktreeDeploymentVerification(
    record: ReleaseRecord,
    articleTarget: RepositoryWorktreeArticleVerificationTarget?
  ) async -> DeploymentStatusSnapshot? {
    var latest: DeploymentStatusSnapshot?
    for delay in [0, 2, 3, 5, 8] {
      if delay > 0 {
        try? await Task.sleep(for: .seconds(Double(delay)))
        guard !Task.isCancelled else { break }
      }
      latest = await refreshDeploymentStatus(for: record, updatesMessage: false)
      if RepositoryWorktreePublicationOutcome.verificationIsComplete(
        articleTarget: articleTarget,
        deploymentStatus: latest
      ) {
        break
      }
    }
    return latest
  }
}
