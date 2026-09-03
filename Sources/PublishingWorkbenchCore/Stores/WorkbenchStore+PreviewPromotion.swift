import Foundation

extension WorkbenchStore {
  public func preparePreviewPromotion(for record: ReleaseRecord) async throws
    -> PreviewPromotionPlan
  {
    let profile = try previewPromotionProfile(for: record)
    let plan = try await publishingStore.remoteRepositoryPublishService.preparePreviewPromotion(
      record: record,
      profile: profile, token: publishingStore.repositoryAccessToken(for: profile))
    try validatePreviewPromotionContext(record: record, profile: profile)
    return plan
  }

  public func createReviewForPreview(_ plan: PreviewPromotionPlan) async throws -> ReleaseRecord {
    try validatePreviewPromotionContext(record: plan.record, profile: plan.profile)
    // A retry after a completed conversion should continue the existing record.
    if let existing = releaseRecords.first(where: {
      $0.previewSourceRecordID == plan.record.id && $0.kind == .remoteReviewRequest
    }) {
      guard saveCurrentStateSynchronously() else { throw PreviewPromotionError.persistence }
      return existing
    }
    guard
      let operation = publishingStore.beginRemoteRepositoryMutation(
        profile: plan.profile, store: self)
    else {
      throw PreviewPromotionError.busy
    }
    defer { publishingStore.finishRemoteRepositoryMutation(operation, store: self) }
    setPublishActionMessage(CoreL10n.text("正在为已审阅的预览版本准备正式发布请求…"), status: .inProgress)
    do {
      let record = try await publishingStore.remoteRepositoryPublishService.createReviewForPreview(
        plan: plan,
        token: publishingStore.repositoryAccessToken(for: plan.profile),
        beforeMutation: { [weak self] in
          try await MainActor.run {
            guard let self else { throw CancellationError() }
            try self.validatePreviewPromotionContext(record: plan.record, profile: plan.profile)
            guard self.publishingStore.remoteRepositoryMutationIsCurrent(operation, store: self)
            else { throw PreviewPromotionError.changed }
            guard self.saveCurrentStateSynchronously() else {
              throw PreviewPromotionError.persistence
            }
          }
        })
      // Persist receipts even if the window changed after the remote response.
      // The originating site identity is carried by the returned record.
      publishingStore.prependReleaseRecord(record)
      guard saveCurrentStateSynchronously() else { throw PreviewPromotionError.persistence }
      setPublishActionMessage(CoreL10n.text("正式发布请求已准备，等待审阅合并；尚未上线。"), status: .information)
      return record
    } catch {
      setPublishActionMessage(
        CoreL10n.text("发布进度已保留，请重新检查后继续：") + error.localizedDescription, status: .warning)
      throw error
    }
  }

  public func prepareReviewMerge(for record: ReleaseRecord) async throws -> ReviewMergePlan {
    let current = releaseRecords.first(where: { $0.id == record.id }) ?? record
    let profile = try previewPromotionProfile(for: current)
    let plan = try await publishingStore.remoteRepositoryPublishService.prepareReviewMerge(
      record: current,
      profile: profile, token: publishingStore.repositoryAccessToken(for: profile))
    try validatePreviewPromotionContext(record: current, profile: profile)
    // A timeout may have hidden a successful merge. Observe it before offering
    // any retry, and retain the exact merge commit for deployment attribution.
    if plan.mergedCommitSHA != nil {
      installPreviewPromotionReview(plan.record)
      guard saveCurrentStateSynchronously() else { throw PreviewPromotionError.persistence }
    }
    return plan
  }

  public func mergeReviewedPublication(_ plan: ReviewMergePlan) async throws -> ReleaseRecord {
    try validatePreviewPromotionContext(record: plan.record, profile: plan.profile)
    guard
      let operation = publishingStore.beginRemoteRepositoryMutation(
        profile: plan.profile, store: self)
    else {
      throw PreviewPromotionError.busy
    }
    defer { publishingStore.finishRemoteRepositoryMutation(operation, store: self) }
    setPublishActionMessage(CoreL10n.text("正在重新核对已审阅版本并请求合并…"), status: .inProgress)
    do {
      let record = try await publishingStore.remoteRepositoryPublishService
        .mergeReviewedPublication(
          plan: plan,
          token: publishingStore.repositoryAccessToken(for: plan.profile),
          beforeMutation: { [weak self] in
            try await MainActor.run {
              guard let self else { throw CancellationError() }
              try self.validatePreviewPromotionContext(record: plan.record, profile: plan.profile)
              guard self.publishingStore.remoteRepositoryMutationIsCurrent(operation, store: self)
              else { throw PreviewPromotionError.changed }
              guard self.saveCurrentStateSynchronously() else {
                throw PreviewPromotionError.persistence
              }
            }
          })
      installPreviewPromotionReview(record)
      guard saveCurrentStateSynchronously() else { throw PreviewPromotionError.persistence }
      setPublishActionMessage(CoreL10n.text("文章已合入目标分支，生产部署仍待验证。"), status: .information)
      // A network error here must not cause a second merge. The merged receipt
      // is already durable and the existing deployment action can be retried.
      if canUseProtectedWorkbench && activeProfileID == plan.profile.id && !Task.isCancelled {
        _ = await refreshDeploymentStatus(for: record)
      }
      return record
    } catch {
      setPublishActionMessage(
        CoreL10n.text("发布进度已保留，请重新检查后继续：") + error.localizedDescription, status: .warning)
      throw error
    }
  }

  private func previewPromotionProfile(for record: ReleaseRecord) throws -> SiteProfile {
    guard let profile = profiles.first(where: { $0.id == record.siteProfileID }) else {
      throw PreviewPromotionError.changed
    }
    try validatePreviewPromotionContext(record: record, profile: profile)
    guard !isRemoteRepositoryPublishing else { throw PreviewPromotionError.busy }
    return profile
  }

  private func validatePreviewPromotionContext(record: ReleaseRecord, profile: SiteProfile) throws {
    try Task.checkCancellation()
    guard canUseProtectedWorkbench, activeProfileID == profile.id,
      profiles.first(where: { $0.id == profile.id }) == profile,
      let current = releaseRecords.first(where: { $0.id == record.id }),
      current.kind == record.kind, current.siteProfileID == record.siteProfileID,
      current.repositoryProvider == record.repositoryProvider,
      current.repositoryBaseURL == record.repositoryBaseURL,
      current.repoOwner == record.repoOwner, current.repoName == record.repoName,
      current.branchName == record.branchName, current.targetBranch == record.targetBranch,
      current.commitSHA == record.commitSHA,
      current.acceptedReviewHeadCommitSHA == record.acceptedReviewHeadCommitSHA,
      current.changedPaths == record.changedPaths, current.markdownPath == record.markdownPath,
      current.reviewURL == record.reviewURL, current.reviewNumber == record.reviewNumber
    else { throw PreviewPromotionError.changed }
    if let draftID = record.draftID, let draft = draft(for: draftID),
      draft.isPrivate || draft.isGeneralDraft || draft.draft
    {
      throw PreviewPromotionError.unavailable(CoreL10n.text("文章现已转为私密、网站草稿或资料库草稿，已停止正式发布。"))
    }
  }

  private func installPreviewPromotionReview(_ record: ReleaseRecord) {
    if let index = publishingStore.releaseRecords.firstIndex(where: { $0.id == record.id }) {
      publishingStore.releaseRecords[index] = record
    } else {
      publishingStore.prependReleaseRecord(record)
    }
  }
}
