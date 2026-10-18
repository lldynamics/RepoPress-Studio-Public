import Foundation

extension WorkbenchStore {
  @discardableResult
  public func writeSelectedDraftToLocalRepository() async -> LocalRepositoryWriteResult {
    refreshSelectedDraftPublishingState()
    return await publishingStore.writeSelectedDraftToLocalRepository(store: self)
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository() async -> BatchLocalWriteResult {
    return await publishingStore.writeBatchReadyDraftsToLocalRepository(store: self)
  }

  @discardableResult
  public func publishBatchReadyDraftsOnlineUsingPreferredStrategy(
    expectedChangedPaths: Set<String>? = nil,
    expectedTarget: RemoteRepositoryPublishTargetSnapshot? = nil,
    expectedReview: BatchPublishReviewExpectation? = nil,
    authorization: AIPublishAuthorizationSnapshot? = nil,
    modeOverride: RemoteRepositoryPublishMode? = nil
  ) async -> RemoteRepositoryPublishResult? {
    return await publishingStore.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      store: self,
      expectedChangedPaths: expectedChangedPaths,
      expectedTarget: expectedTarget,
      expectedReview: expectedReview,
      authorization: authorization,
      modeOverride: modeOverride
    )
  }

  @discardableResult
  public func resolveRemoteRepositoryConflict(
    repositoryPath: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    mergedDocument: String? = nil
  ) async -> RemoteRepositoryConflictResolutionOutcome {
    await publishingStore.resolveRemoteRepositoryConflict(
      repositoryPath: repositoryPath,
      choice: choice,
      mergedDocument: mergedDocument,
      store: self
    )
  }

  @discardableResult
  public func resolveRemoteRepositoryConflicts(
    plan: RemoteRepositoryConflictResolutionPlan
  ) async -> RemoteRepositoryConflictResolutionOutcome {
    await publishingStore.resolveRemoteRepositoryConflicts(
      plan: plan,
      store: self
    )
  }

  @discardableResult
  public func publishSelectedDraftOnlineUsingPreferredStrategy(
    expectedReview: SinglePublishReviewExpectation? = nil
  ) async
    -> RemoteRepositoryPublishResult?
  {
    refreshSelectedDraftPublishingState()
    return await publishingStore.publishSelectedDraftOnlineUsingPreferredStrategy(
      store: self, expectedReview: expectedReview
    )
  }

  /// Refreshes local remote-tracking metadata and performs an authoritative,
  /// read-only provider preflight before the single-article confirmation UI.
  @discardableResult
  public func prepareSelectedDraftOnlinePublish(draftID: UUID) async -> Bool {
    await publishingStore.prepareSelectedDraftOnlinePublish(
      draftID: draftID,
      store: self
    )
  }

  /// Batch equivalent of `prepareSelectedDraftOnlinePublish(draftID:)`.
  @discardableResult
  public func prepareBatchOnlinePublish() async -> Bool {
    await publishingStore.prepareBatchOnlinePublish(store: self)
  }

  @discardableResult
  public func resumeRemoteReview(_ record: ReleaseRecord) async -> RemoteRepositoryPublishResult? {
    await publishingStore.resumeRemoteReview(record, store: self)
  }

  @discardableResult
  public func rollbackRemoteRelease(_ record: ReleaseRecord) async
    -> RemoteRepositoryRollbackResult?
  {
    await publishingStore.rollbackRemoteRelease(record, store: self)
  }

  @discardableResult
  public func withdrawRemoteReview(_ record: ReleaseRecord) async
    -> RemoteRepositoryReviewWithdrawalResult?
  {
    await publishingStore.withdrawRemoteReview(record, store: self)
  }

  public func preferredRemoteRepositoryPublishMode(for profile: SiteProfile)
    -> RemoteRepositoryPublishMode
  {
    publishingStore.preferredRemoteRepositoryPublishMode(for: profile)
  }

  public func remoteRepositoryPublishPreview(for draft: ArticleDraft)
    -> RemoteRepositoryPublishPreview
  {
    flushDraftBodyEditorBuffer(for: draft.id)
    return publishingStore.remoteRepositoryPublishPreview(for: draft, store: self)
  }

  public func remoteRepositoryPublishPreview(for plan: BatchPublishPlan)
    -> RemoteRepositoryPublishPreview?
  {
    flushDraftBodyEditorBuffers()
    return publishingStore.remoteRepositoryPublishPreview(for: plan, store: self)
  }

  private func refreshSelectedDraftPublishingState() {
    flushDraftBodyEditorBuffers()
    refreshPublishPreview(for: selectedDraft)
  }

  public func blockingLocalPublishIssues(
    package: PublishPackage,
    preview: LocalPublishPreview,
    includeRepositoryReadiness: Bool
  ) -> [PreflightIssue] {
    publishingStore.blockingLocalPublishIssues(
      package: package,
      preview: preview,
      includeRepositoryReadiness: includeRepositoryReadiness,
      store: self
    )
  }

  public func makeLocalPublishReadiness(
    package: PublishPackage,
    profile: SiteProfile,
    preview: LocalPublishPreview
  ) -> LocalPublishReadiness {
    publishingStore.makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: preview,
      store: self
    )
  }

  public func blockedLocalPublishMessage(action: String, issues: [PreflightIssue]) -> String {
    publishingStore.blockedLocalPublishMessage(action: action, issues: issues)
  }

  public func remotePublishPackage(for plan: BatchPublishPlan) -> PublishPackage? {
    publishingStore.remotePublishPackage(for: plan)
  }

  public func remoteRepositoryPublishPreview(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    extraWarningIssues: [PreflightIssue] = [],
    localPreview: LocalPublishPreview? = nil
  ) -> RemoteRepositoryPublishPreview {
    publishingStore.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: extraWarningIssues,
      localPreview: localPreview,
      store: self
    )
  }

  public func batchRemoteRepositoryPublishWarningIssues(for plan: BatchPublishPlan)
    -> [PreflightIssue]
  {
    publishingStore.batchRemoteRepositoryPublishWarningIssues(for: plan)
  }

  public func markDraftsAsPublishedIfDirectRemoteCommit(
    mode: RemoteRepositoryPublishMode,
    draftIDs: [UUID]
  ) {
    guard mode == .directCommit else { return }
    let previousDrafts = drafts
    for record in releaseRecords where record.kind == .remoteDirectCommit {
      guard let profile = profiles.first(where: { $0.id == record.siteProfileID }),
        let snapshot = deploymentStatusSnapshot(for: record)
      else { continue }
      markVerifiedArticlesAsPublished(
        record: record, snapshot: snapshot, profile: profile,
        allowedDraftIDs: Set(draftIDs))
    }
    if drafts != previousDrafts { save() }
  }

  public func recordRemoteRepositoryPublishInAutoSync(
    _ result: RemoteRepositoryPublishResult,
    profileID: UUID
  ) {
    repositoryDeploymentCoordinator.recordRemotePublish(result, profileID: profileID)
  }

  public func shouldRefreshDeploymentStatusAfterRemoteOperation(_ record: ReleaseRecord) -> Bool {
    repositoryDeploymentCoordinator.shouldRefreshDeployment(after: record, store: self)
  }

  public func partialRemoteRepositoryPublishFailure(from error: Error)
    -> RemoteRepositoryPublishResult?
  {
    publishingStore.partialRemoteRepositoryPublishFailure(from: error)
  }
}
