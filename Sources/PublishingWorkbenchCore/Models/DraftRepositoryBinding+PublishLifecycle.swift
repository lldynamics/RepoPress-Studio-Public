import Foundation

extension ArticleDraft {
  func projectFileBinding(
    profile: SiteProfile,
    repositoryPath: String,
    renderedContentDigest: String,
    projectFileContentDigest: String? = nil
  ) -> DraftRepositoryBinding {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let identity = DraftRepositoryIdentity(profile: profile)
    let canRetainRemoteRevision =
      repositoryBinding?.identity == identity
      && self.repositoryPath?.normalizedRelativePath() == normalizedPath
    let retainedRevision = canRetainRemoteRevision ? repositorySHA : nil
    let retainedVerification =
      canRetainRemoteRevision
      ? (repositoryBinding?.verification ?? .legacyUnverified)
      : .legacyUnverified
    let recordedDigest =
      retainedRevision == nil
      ? renderedContentDigest
      : repositoryBinding?.renderedContentDigest
    let retainedPendingReviewDigest =
      canRetainRemoteRevision
      ? repositoryBinding?.pendingReviewContentDigest
      : nil
    let recordedSyncState: DraftRepositorySyncState
    if let retainedPendingReviewDigest {
      recordedSyncState =
        retainedPendingReviewDigest == renderedContentDigest
        ? .awaitingReview : .localChanged
    } else if retainedRevision == nil {
      recordedSyncState = .projectSaved
    } else if recordedDigest == renderedContentDigest {
      // Startup reconciliation and explicit writes of identical bytes do not
      // create a local change relative to the confirmed remote baseline.
      recordedSyncState = .synced
    } else {
      recordedSyncState = .localChanged
    }
    return DraftRepositoryBinding(
      identity: identity,
      repositoryPath: normalizedPath,
      remoteRevision: retainedRevision,
      renderedContentDigest: recordedDigest,
      projectFileContentDigest: projectFileContentDigest ?? renderedContentDigest,
      projectFileRenderedContentDigest: renderedContentDigest,
      pendingReviewContentDigest: retainedPendingReviewDigest,
      verification: retainedVerification,
      syncState: recordedSyncState,
      verifiedAt: canRetainRemoteRevision ? repositoryBinding?.verifiedAt : nil
    )
  }

  func confirmedRepositoryBinding(
    profile: SiteProfile,
    repositoryPath: String,
    remoteRevision: String,
    renderedContentDigest: String,
    projectFileContentDigest: String? = nil,
    verifiedAt: Date = Date()
  ) -> DraftRepositoryBinding {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let normalizedRevision = remoteRevision.trimmedForPublishing
    let identity = DraftRepositoryIdentity(profile: profile)
    let previousBinding = repositoryBinding.flatMap { binding in
      binding.identity == identity && binding.repositoryPath == normalizedPath ? binding : nil
    }
    let isSynced = renderedRepositoryContentDigest(profile: profile) == renderedContentDigest
    return DraftRepositoryBinding(
      identity: identity,
      repositoryPath: normalizedPath,
      remoteRevision: normalizedRevision,
      renderedContentDigest: renderedContentDigest,
      projectFileContentDigest: projectFileContentDigest
        ?? previousBinding?.projectFileContentDigest ?? renderedContentDigest,
      projectFileRenderedContentDigest: projectFileContentDigest != nil
        ? renderedContentDigest
        : previousBinding?.projectFileRenderedContentDigest ?? renderedContentDigest,
      verification: .verified,
      syncState: isSynced ? .synced : .localChanged,
      verifiedAt: verifiedAt
    )
  }

}
