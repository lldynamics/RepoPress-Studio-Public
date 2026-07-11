import Foundation

extension WorkbenchStore {
  public func writeSelectedDraftToLocalRepository() {
    refreshSelectedDraftPublishingState()
    publishingStore.writeSelectedDraftToLocalRepository(store: self)
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository() -> BatchLocalWriteResult {
    refreshBatchPublishPlan()
    return publishingStore.writeBatchReadyDraftsToLocalRepository(store: self)
  }

  @discardableResult
  public func publishBatchReadyDraftsOnlineUsingPreferredStrategy() async -> RemoteRepositoryPublishResult? {
    refreshBatchPublishPlan()
    return await publishingStore.publishBatchReadyDraftsOnlineUsingPreferredStrategy(store: self)
  }

  public func commitSelectedDraftDirectly() async {
    refreshSelectedDraftPublishingState()
    await publishingStore.commitSelectedDraftDirectly(store: self)
  }

  public func commitSelectedDraftToReviewBranch() async {
    refreshSelectedDraftPublishingState()
    await publishingStore.commitSelectedDraftToReviewBranch(store: self)
  }

  public func commitSelectedDraftUsingPreferredStrategy() async {
    refreshSelectedDraftPublishingState()
    await publishingStore.commitSelectedDraftUsingPreferredStrategy(store: self)
  }

  @discardableResult
  public func publishSelectedDraftOnlineUsingPreferredStrategy() async -> RemoteRepositoryPublishResult? {
    refreshSelectedDraftPublishingState()
    return await publishingStore.publishSelectedDraftOnlineUsingPreferredStrategy(store: self)
  }

  @discardableResult
  public func rollbackRemoteRelease(_ record: ReleaseRecord) async -> RemoteRepositoryRollbackResult? {
    await publishingStore.rollbackRemoteRelease(record, store: self)
  }

  @discardableResult
  public func withdrawRemoteReview(_ record: ReleaseRecord) async -> RemoteRepositoryReviewWithdrawalResult? {
    await publishingStore.withdrawRemoteReview(record, store: self)
  }

  public func localCommitCommandForSelectedDraft() -> String? {
    refreshSelectedDraftPublishingState()
    return publishingStore.localCommitCommandForSelectedDraft(store: self)
  }

  public func reviewBranchCommandsForSelectedDraft() -> [String] {
    refreshSelectedDraftPublishingState()
    return publishingStore.reviewBranchCommandsForSelectedDraft(store: self)
  }

  public func batchLocalCommitCommandForWritableDrafts() -> String? {
    refreshBatchPublishPlan()
    return publishingStore.batchLocalCommitCommandForWritableDrafts(store: self)
  }

  public func batchReviewBranchCommandsForWritableDrafts() -> [String] {
    refreshBatchPublishPlan()
    return publishingStore.batchReviewBranchCommandsForWritableDrafts(store: self)
  }

  public func preferredLocalGitPublishMode(for profile: SiteProfile) -> LocalGitPublishMode {
    publishingStore.preferredLocalGitPublishMode(for: profile)
  }

  public func preferredRemoteRepositoryPublishMode(for profile: SiteProfile) -> RemoteRepositoryPublishMode {
    publishingStore.preferredRemoteRepositoryPublishMode(for: profile)
  }

  public func remoteRepositoryPublishPreview(for draft: ArticleDraft) -> RemoteRepositoryPublishPreview {
    flushDraftBodyEditorBuffer(for: draft.id)
    return publishingStore.remoteRepositoryPublishPreview(for: draft, store: self)
  }

  public func remoteRepositoryPublishPreview(for plan: BatchPublishPlan) -> RemoteRepositoryPublishPreview? {
    flushDraftBodyEditorBuffers()
    return publishingStore.remoteRepositoryPublishPreview(for: plan, store: self)
  }

  private func refreshSelectedDraftPublishingState() {
    let targetDraftID = publishingStore.publishPackage?.draftID ?? selectedDraft?.id
    flushDraftBodyEditorBuffers()
    if let targetDraftID,
       let draft = drafts.first(where: { $0.id == targetDraftID }) {
      refreshPublishPreview(for: draft)
    }
  }

  public func blockingLocalPublishIssues(
    package: PublishPackage,
    profile: SiteProfile,
    preview: LocalPublishPreview,
    includeRepositoryReadiness: Bool
  ) -> [PreflightIssue] {
    publishingStore.blockingLocalPublishIssues(
      package: package,
      profile: profile,
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

  public func remotePublishPackage(for plan: BatchPublishPlan, profile: SiteProfile) -> PublishPackage? {
    publishingStore.remotePublishPackage(for: plan, profile: profile)
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

  public func batchRemoteRepositoryPublishWarningIssues(for plan: BatchPublishPlan) -> [PreflightIssue] {
    publishingStore.batchRemoteRepositoryPublishWarningIssues(for: plan)
  }

  public func markDraftsAsPublishedIfDirectRemoteCommit(
    mode: RemoteRepositoryPublishMode,
    draftIDs: [UUID]
  ) {
    publishingStore.markDraftsAsPublishedIfDirectRemoteCommit(mode: mode, draftIDs: draftIDs)
  }

  public func recordRemoteRepositoryPublishInAutoSync(_ result: RemoteRepositoryPublishResult) {
    repositoryDeploymentCoordinator.recordRemotePublish(result)
  }

  public func shouldRefreshDeploymentStatusAfterRemoteOperation(_ record: ReleaseRecord) -> Bool {
    repositoryDeploymentCoordinator.shouldRefreshDeployment(after: record, store: self)
  }

  public func partialRemoteRepositoryPublishFailure(from error: Error) -> RemoteRepositoryPublishResult? {
    publishingStore.partialRemoteRepositoryPublishFailure(from: error)
  }
}
