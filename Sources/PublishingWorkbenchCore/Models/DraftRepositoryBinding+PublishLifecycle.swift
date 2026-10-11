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

  public func repositorySyncState(for profile: SiteProfile) -> DraftRepositorySyncState {
    guard let binding = repositoryBinding else { return .localOnly }
    guard binding.identity == nil || binding.identity == DraftRepositoryIdentity(profile: profile)
    else { return .diverged }
    switch binding.syncState {
    case .diverged, .failed:
      return binding.syncState
    case .awaitingReview:
      guard let pendingDigest = binding.pendingReviewContentDigest else {
        return .awaitingReview
      }
      return pendingDigest == renderedRepositoryContentDigest(profile: profile)
        ? .awaitingReview
        : .localChanged
    case .localOnly:
      return .localOnly
    case .projectSaved:
      return .projectSaved
    case .localChanged:
      // This state is set by a successful local project write while a remote
      // revision is retained. It is authoritative until a verified remote
      // operation establishes a new baseline.
      return .localChanged
    case .synced:
      guard binding.remoteRevision != nil else { return .projectSaved }
      guard let baseline = binding.renderedContentDigest else { return .localChanged }
      return baseline == renderedRepositoryContentDigest(profile: profile) ? .synced : .localChanged
    }
  }

  public func renderedRepositoryContentDigest(profile: SiteProfile) -> String {
    let document = FrontMatterRenderer().renderDocument(draft: self, profile: profile)
    return Self.repositoryDocumentDigest(document)
  }

}
