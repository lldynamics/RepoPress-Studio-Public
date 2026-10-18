import Foundation

extension DeploymentStore {
  func releaseCanHaveDeployment(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteDirectCommit, .remoteRollback:
      return true
    case .remoteReviewRequest:
      return record.reviewStatus?.state == .merged
        && record.deploymentCommitSHA != nil
    case .remotePublishFailure:
      guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil else { return false }
      let branch = record.branchName?.trimmedForPublishing.nilIfEmpty
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
      return targetBranch == nil || branch == nil || branch == targetBranch
    case .localWrite,
      .batchLocalWrite,
      .directCommit,
      .reviewBranch,
      .remotePreviewBranch,
      .remoteReviewWithdrawal:
      return false
    }
  }

  func deploymentProfile(for record: ReleaseRecord, store: WorkbenchStore) -> SiteProfile? {
    let profile: SiteProfile?
    if let profileID = record.siteProfileID {
      profile = store.profiles.first { $0.id == profileID }
    } else {
      profile = store.activeProfile
    }
    guard let profile else { return nil }
    if let request = record.articlePublishTrackingRequest,
      request.target != ArticlePublishTrackingRequest.Target(profile: profile)
    {
      return nil
    }
    return profile
  }

  func completeArticlePublishTracking(
    record: ReleaseRecord, snapshot: DeploymentStatusSnapshot, store: WorkbenchStore
  ) {
    guard let request = record.articlePublishTrackingRequest, request.completedSnapshot == nil,
      deploymentProfile(for: record, store: store) != nil,
      snapshot.checkedAt >= request.startedAt, snapshot.checkedAt <= request.deadline,
      snapshot.matchesReleaseIdentity(record),
      snapshot.verifiesAllArticles(in: record)
        || (snapshot.platformLevel == .failed && snapshot.attributionVerified == true),
      let index = store.publishingStore.releaseRecords.firstIndex(where: { $0 == record })
    else { return }
    store.publishingStore.releaseRecords[index].articlePublishTrackingRequest?.completedSnapshot =
      snapshot
  }

  public func articlePublishProgress(
    for record: ReleaseRecord, store: WorkbenchStore, now: Date = Date()
  ) -> ArticlePublishProgress? {
    guard record.articlePublishTrackingRequest != nil else { return nil }
    // Never use profile(for:) here: deleted profiles must not inherit the
    // selected site's endpoint or credentials.
    let profile = store.profiles.first { $0.id == record.siteProfileID }
    let reason: String?
    if let profile {
      let readiness = deploymentStatusReadiness(
        for: profile, tokenAvailability: resolvedDeploymentTokenAvailability(for: profile))
      reason = readiness.canCheckAnyStatus ? nil : readiness.nextStep
    } else {
      reason = nil
    }
    return ArticlePublishProgress.make(
      record: record, snapshot: deploymentStatusSnapshots[record.id], profile: profile,
      unavailableReason: reason, now: now)
  }

  @discardableResult
  func tickArticlePublishTracking(store: WorkbenchStore, now: Date) async -> Bool {
    guard !store.isSafeMode else { return false }
    articleTrackingClock = now
    let recordIDs = Set(store.releaseRecords.map(\.id))
    articleTrackingLastAttemptAt = articleTrackingLastAttemptAt.filter {
      recordIDs.contains($0.key)
    }
    var didRun = false
    for record in store.releaseRecords {
      guard !Task.isCancelled,
        let request = record.articlePublishTrackingRequest,
        articlePublishProgress(for: record, store: store, now: now)?.isPending == true,
        !activeArticleTrackingRecordIDs.contains(record.id),
        !isCheckingDeploymentRecord(record.id)
      else { continue }
      let lastCheck = [
        deploymentStatusSnapshots[record.id]?.checkedAt,
        articleTrackingLastAttemptAt[record.id],
      ].compactMap { $0 }.filter { $0 >= request.startedAt }.max()
      guard
        lastCheck.map({ now.timeIntervalSince($0) >= ArticlePublishTrackingRequest.checkInterval })
          ?? true
      else { continue }
      activeArticleTrackingRecordIDs.insert(record.id)
      articleTrackingLastAttemptAt[record.id] = now
      _ = await refreshDeploymentStatus(for: record, store: store, updatesMessage: false)
      activeArticleTrackingRecordIDs.remove(record.id)
      didRun = true
    }
    return didRun
  }
}

extension WorkbenchStore {
  public func profile(for record: ReleaseRecord) -> SiteProfile {
    publishingStore.profile(for: record)
  }

  public func articlePublishProgress(
    for record: ReleaseRecord, now: Date = Date()
  ) -> ArticlePublishProgress? {
    deploymentStore.articlePublishProgress(for: record, store: self, now: now)
  }

  var hasPendingArticlePublishTracking: Bool {
    releaseRecords.contains { articlePublishProgress(for: $0)?.isPending == true }
  }

  func resumeArticlePublishTracking() {
    guard !isSafeMode, hasPendingArticlePublishTracking else { return }
    ensureOperationalPolling()
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await deploymentStore.tickArticlePublishTracking(store: self, now: Date())
    }
  }

  /// Explicitly checking starts a fresh bounded follow-up for the same
  /// recorded content, never another commit or push.
  public func canRecheckArticlePublication(_ record: ReleaseRecord) -> Bool {
    guard !isSafeMode,
      let current = releaseRecords.first(where: { $0.id == record.id }),
      let profile = profiles.first(where: { $0.id == current.siteProfileID }),
      let request = current.articlePublishTrackingRequest,
      request.target.repository == DraftRepositoryIdentity(profile: profile)
    else { return false }
    return deploymentStore.deploymentStatusReadiness(
      for: profile,
      tokenAvailability: deploymentStore.resolvedDeploymentTokenAvailability(for: profile)
    ).canCheckAnyStatus
  }

  public func recheckArticlePublication(_ record: ReleaseRecord) async {
    guard canRecheckArticlePublication(record),
      let index = publishingStore.releaseRecords.firstIndex(where: { $0.id == record.id }),
      let profile = profiles.first(where: {
        $0.id == publishingStore.releaseRecords[index].siteProfileID
      }),
      !deploymentStore.isCheckingDeploymentRecord(record.id),
      let oldRequest = publishingStore.releaseRecords[index].articlePublishTrackingRequest,
      oldRequest.target.repository == DraftRepositoryIdentity(profile: profile)
    else { return }
    publishingStore.releaseRecords[index].articlePublishTrackingRequest =
      ArticlePublishTrackingRequest(profile: profile)
    save()
    ensureOperationalPolling()
    _ = await deploymentStore.tickArticlePublishTracking(store: self, now: Date())
  }
}
