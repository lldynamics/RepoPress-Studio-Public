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
    authorization: AIPublishAuthorizationSnapshot? = nil
  ) async -> RemoteRepositoryPublishResult? {
    return await publishingStore.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      store: self,
      expectedChangedPaths: expectedChangedPaths,
      authorization: authorization
    )
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
  public func publishSelectedDraftOnlineUsingPreferredStrategy() async
    -> RemoteRepositoryPublishResult?
  {
    refreshSelectedDraftPublishingState()
    return await publishingStore.publishSelectedDraftOnlineUsingPreferredStrategy(store: self)
  }

  /// Pushes the selected article to its isolated `draft/<slug>` preview branch.
  /// This path never promotes the article to the formal published lifecycle.
  @discardableResult
  public func publishSelectedDraftToPreviewBranch() async
    -> RemoteRepositoryPublishResult?
  {
    refreshSelectedDraftPublishingState()
    return await publishingStore.publishSelectedDraftToPreviewBranch(store: self)
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

  /// Returns the isolated preview branch name for one article.
  public func draftPreviewBranchName(for draft: ArticleDraft) -> String {
    publishingPackage(for: draft).draftPreviewBranchName
  }

  /// Builds the same preflight snapshot used by the one-click preview action,
  /// with dedicated-branch semantics (so target-branch conflicts do not block
  /// an isolated preview push).
  public func remoteRepositoryDraftPreview(for draft: ArticleDraft)
    -> RemoteRepositoryPublishPreview
  {
    // This is called while SwiftUI computes the publishing drawer body, so it
    // must remain a pure snapshot read. The actual publish command flushes the
    // editor buffer before it assembles the package.
    let currentDraft = drafts.first(where: { $0.id == draft.id }) ?? draft
    let package = publishingStore.publishingPackage(for: currentDraft, store: self)
    let profile = profile(for: currentDraft)
    let localPreview = publishingStore.localPublishPreview(for: currentDraft, store: self)
    return publishingStore.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: .previewBranch,
      localPreview: localPreview,
      store: self
    )
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
    if publishingStore.markDraftsAsPublishedIfDirectRemoteCommit(
      mode: mode,
      draftIDs: draftIDs
    ) {
      invalidateDraftDerivedCaches()
    }
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
