import Foundation
import PublishingGitCore
import PublishingSyncCore

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
    privateRepository: Bool = true,
    expectedTarget: SiteOperationConfirmationTarget? = nil
  ) async -> RemoteRepositoryCreationResult? {
    await repositoryStore.createRemoteRepositoryForActiveProfile(
      privateRepository: privateRepository, expectedTarget: expectedTarget, store: self)
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

  /// 发布全部: writes every finished article of the active site into the local
  /// repository, then freezes a review of all worktree changes, including
  /// themes, configuration and deletions. Website drafts are not written.
  public func prepareAllChangesRepositoryPublish() async -> RepositoryPublishPreparation {
    let profileID = activeProfileID
    guard activeProfile.localRepositoryRootURL != nil else {
      return .unavailable(message: CoreL10n.text("请先在站点设置中选择本地仓库，并确认已配置 origin。"))
    }
    let written = await publishingStore.writeBatchReadyDraftsToLocalRepository(
      store: self, includesSiteDrafts: false)
    guard !Task.isCancelled, activeProfileID == profileID else {
      return .unavailable(message: CoreL10n.text("站点已切换，请重新发布。"))
    }
    guard written.failedTitles.isEmpty else {
      return .unavailable(
        message: CoreL10n.format(
          "以下文章未能写入本地仓库，已停止发布：%@",
          written.failedTitles.joined(separator: "、")))
    }
    guard
      let confirmation = await repositoryStore.prepareRepositoryWorktreePublish(
        store: self, commitMessage: "Publish all site changes")
    else {
      return .unavailable(
        message: publishActionMessage ?? CoreL10n.text("无法准备发布，请稍后重试。"))
    }
    return .review(confirmation)
  }

  /// 发布这篇: writes the selected article and its images into the local
  /// repository, then freezes a review of only those files. Other worktree
  /// changes are neither reviewed nor committed.
  public func prepareArticleRepositoryPublish(draftID: UUID) async -> RepositoryPublishPreparation {
    let profile = activeProfile
    guard selectedDraftID == draftID, let draft = draft(for: draftID),
      !draft.isGeneralDraft, draft.belongs(toSiteProfileID: profile.id)
    else {
      return .unavailable(message: CoreL10n.text("请选择当前站点的文章后再发布。"))
    }
    guard profile.localRepositoryRootURL != nil else {
      return .unavailable(message: CoreL10n.text("请先在站点设置中选择本地仓库，并确认已配置 origin。"))
    }
    await waitForPendingSiteDraftFileWrites(draftIDs: [draftID])
    guard !Task.isCancelled, selectedDraftID == draftID, activeProfileID == profile.id,
      let package = publishingStore.publishPackageForSelectedDraft(store: self)
    else {
      return .unavailable(message: CoreL10n.text("文章或站点已切换，请重新发布。"))
    }
    let preview = publishingStore.localPublishPreviewService.preview(
      package: package, profile: profile)
    let issues = blockingLocalPublishIssues(
      package: package, preview: preview, includeRepositoryReadiness: false)
    guard issues.isEmpty else { return .blocked(draftID: draftID, issues: issues) }

    if !preview.changedFileDiffs.isEmpty {
      let written = await writeSelectedDraftToLocalRepository()
      if case .failed(let message) = written { return .unavailable(message: message) }
      if case .writtenButRecordSaveFailed(_, let message) = written {
        return .unavailable(message: message)
      }
    }
    guard !Task.isCancelled, selectedDraftID == draftID, activeProfileID == profile.id else {
      return .unavailable(message: CoreL10n.text("文章或站点已切换，请重新发布。"))
    }
    var paths = package.files.map { $0.repositoryPath.normalizedRelativePath() }
      .filter { !$0.isEmpty }
    guard let currentDraft = self.draft(for: draftID) else {
      return .unavailable(message: CoreL10n.text("文章或站点已切换，请重新发布。"))
    }
    func otherArticlePaths() -> Set<String> {
      Set(
        drafts.filter {
          $0.id != draftID && $0.belongs(toSiteProfileID: profile.id)
        }.flatMap { [$0.repositoryPath, profile.markdownPath(for: $0)].compactMap { $0 } })
    }
    let retiredPaths: [String]
    do {
      retiredPaths = try siteDraftFileStore.pendingMovePaths(
        draft: currentDraft, profile: profile, otherArticlePaths: otherArticlePaths())
      paths += retiredPaths
    } catch {
      return .unavailable(message: error.localizedDescription)
    }
    let title = draft.title.split(whereSeparator: \.isNewline).first.map(String.init)?
      .trimmedForPublishing.nilIfEmpty
    guard
      let confirmation = await repositoryStore.prepareRepositoryWorktreePublish(
        store: self,
        commitMessage: title.map { "Publish \($0)" } ?? "Publish article",
        pathScope: paths,
        articleDraftID: draftID)
    else {
      return .unavailable(
        message: publishActionMessage ?? CoreL10n.text("无法准备发布，请稍后重试。"))
    }
    guard !Task.isCancelled, selectedDraftID == draftID, activeProfileID == profile.id,
      self.draft(for: draftID)?.repositoryContentFingerprint
        == currentDraft.repositoryContentFingerprint,
      !draftBodyEditorBuffer(for: draftID).isDirty,
      activeProfile.localRepositoryRootURL == profile.localRepositoryRootURL,
      DraftRepositoryIdentity(profile: activeProfile) == DraftRepositoryIdentity(profile: profile),
      confirmation.snapshot.repositoryRoot
        == profile.localRepositoryRootURL?.standardizedFileURL.path
    else {
      return .unavailable(message: CoreL10n.text("文章或站点已切换，请重新发布。"))
    }
    do {
      guard
        try siteDraftFileStore.pendingMovePaths(
          draft: currentDraft, profile: profile, otherArticlePaths: otherArticlePaths(),
          revision: confirmation.snapshot.headSHA) == retiredPaths
      else {
        throw RepositoryGitExecutionPolicyError.reviewedContentChanged
      }
    } catch {
      return .unavailable(message: error.localizedDescription)
    }
    guard
      retiredPaths.allSatisfy({ path in
        confirmation.snapshot.entries.contains { $0.path == path && $0.kind == .deleted }
      })
    else {
      return .unavailable(
        message: SiteDraftFileStoreError.projectFileChangedExternally(
          retiredPaths.joined(separator: ", ")
        ).localizedDescription)
    }
    var review = confirmation
    review.articlePreflightIssues = preflightIssues(
      for: currentDraft, includeRepositoryReadiness: false
    )
    .filter { $0.severity != .error }
    return .review(review)
  }

  /// Publishes only the previously frozen complete-worktree confirmation.
  public func publishRepositoryWorktree(
    _ confirmation: RepositoryWorktreePublishConfirmation
  ) async -> RepositoryWorktreePublishResult? {
    await repositoryStore.publishRepositoryWorktree(confirmation, store: self)
  }
}
