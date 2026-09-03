import Foundation

actor RemoteArticlePublicationMutationGate {
  private var hasCheckedInitialRemoteBaseline = false

  func claimInitialRemoteBaselineCheck() -> Bool {
    guard !hasCheckedInitialRemoteBaseline else { return false }
    hasCheckedInitialRemoteBaseline = true
    return true
  }
}

extension PublishingStore {
  @discardableResult
  public func reviewRemoteArticlePublication(
    for draft: ArticleDraft,
    store: WorkbenchStore
  ) async -> RemoteArticlePublicationReview? {
    guard !draft.isGeneralDraft, store.canUseProtectedWorkbench else { return nil }
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = drafts.first(where: { $0.id == draft.id }) else {
      setPublishActionMessage(CoreL10n.text("当前文章已变化，请重新打开发布流程。"), status: .warning)
      return nil
    }
    let package = publishingPackage(for: currentDraft, store: store)
    let profile = store.profile(for: currentDraft)
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    guard await store.ensureRemoteRepositoryWriteAccess(for: profile) else { return nil }
    do {
      let token = try repositoryAccessToken(for: profile)
      let review = try await remoteRepositoryPublishService.reviewRemoteArticlePublication(
        package: package,
        profile: profile,
        mode: mode,
        token: token
      )
      _ = try currentReviewedRemoteArticlePublicationSnapshot(review, store: store)
      return review
    } catch let error as RemoteArticlePublicationReviewError {
      setPublishActionMessage(error.localizedDescription, status: .warning)
      return nil
    } catch {
      setPublishActionMessage(
        CoreL10n.format("远端审阅失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func publishReviewedRemoteArticlePublication(
    _ review: RemoteArticlePublicationReview,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard var current = reviewedRemoteArticlePublicationSnapshotForPublish(review, store: store)
    else { return nil }
    guard await store.ensureRemoteRepositoryWriteAccess(for: current.profile) else { return nil }
    guard let afterAccess = reviewedRemoteArticlePublicationSnapshotForPublish(review, store: store)
    else { return nil }
    current = afterAccess

    do {
      let token = try repositoryAccessToken(for: current.profile)
      let latestReview = try await remoteRepositoryPublishService.reviewRemoteArticlePublication(
        package: current.package,
        profile: current.profile,
        mode: current.mode,
        token: token
      )
      guard remoteArticleReviewMatches(review, latestReview) else {
        setPublishActionMessage(
          RemoteArticlePublicationReviewError.remoteChanged.localizedDescription, status: .warning)
        return nil
      }
      guard
        let afterRemoteRead = reviewedRemoteArticlePublicationSnapshotForPublish(
          review, store: store)
      else { return nil }
      current = afterRemoteRead
      if latestReview.isFullySynchronized {
        let versions = Dictionary(
          uniqueKeysWithValues: latestReview.files.compactMap { file in
            file.remoteVersion.map { (file.path, $0) }
          }
        )
        confirmDirectRemotePublishLifecycle(
          packages: [current.package],
          result: RemoteRepositoryPublishResult(
            provider: current.profile.repositoryProvider,
            mode: current.mode,
            branchName: latestReview.target.targetBranch,
            targetBranch: latestReview.target.targetBranch,
            changedPaths: [],
            commitSHA: nil,
            remoteVersionsByPath: versions
          )
        )
        setPublishActionMessage(
          CoreL10n.text("远端已同步，未重复写入。可在同步中心检查部署或查看发布记录。"),
          status: .success
        )
        store.save()
        return nil
      }
    } catch let error as RemoteArticlePublicationReviewError {
      setPublishActionMessage(error.localizedDescription, status: .warning)
      return nil
    } catch {
      setPublishActionMessage(
        CoreL10n.format("远端审阅失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }

    return await publishSelectedDraftOnline(
      package: current.package,
      profile: current.profile,
      mode: current.mode,
      expectedRemoteArticleReview: review,
      store: store
    )
  }

  private func currentReviewedRemoteArticlePublicationSnapshot(
    _ review: RemoteArticlePublicationReview,
    store: WorkbenchStore
  ) throws -> (package: PublishPackage, profile: SiteProfile, mode: RemoteRepositoryPublishMode) {
    try Task.checkCancellation()
    guard !blockPublishingIfGeneralDraftSelected(store: store),
      store.canUseProtectedWorkbench,
      let selectedDraft = store.selectedDraft,
      selectedDraft.id == review.package.draftID,
      !selectedDraft.isPrivate,
      let draft = drafts.first(where: { $0.id == review.package.draftID }),
      !draft.isGeneralDraft,
      !draft.isPrivate
    else {
      throw RemoteArticlePublicationReviewError.confirmationExpired
    }
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = drafts.first(where: { $0.id == review.package.draftID }) else {
      throw RemoteArticlePublicationReviewError.confirmationExpired
    }
    let package = publishingPackage(for: currentDraft, store: store)
    let profile = store.profile(for: currentDraft)
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      store: store
    )
    guard remoteArticlePackageMatches(review.package, package),
      try remoteArticlePackageContentMatches(review, package: package),
      RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview) == review.target
    else {
      throw RemoteArticlePublicationReviewError.confirmationExpired
    }
    return (package, profile, mode)
  }

  private func reviewedRemoteArticlePublicationSnapshotForPublish(
    _ review: RemoteArticlePublicationReview,
    store: WorkbenchStore
  ) -> (package: PublishPackage, profile: SiteProfile, mode: RemoteRepositoryPublishMode)? {
    do {
      return try currentReviewedRemoteArticlePublicationSnapshot(review, store: store)
    } catch let error as RemoteArticlePublicationReviewError {
      setPublishActionMessage(error.localizedDescription, status: .warning)
      return nil
    } catch {
      setPublishActionMessage(
        CoreL10n.format("发布确认校验失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  func remoteArticlePackageMatches(_ lhs: PublishPackage, _ rhs: PublishPackage) -> Bool {
    lhs.draftID == rhs.draftID
      && lhs.markdownPath.normalizedRelativePath() == rhs.markdownPath.normalizedRelativePath()
      && lhs.files == rhs.files
  }

  func remoteArticleReviewMatches(
    _ expected: RemoteArticlePublicationReview,
    _ actual: RemoteArticlePublicationReview
  ) -> Bool {
    guard expected.target == actual.target,
      expected.targetBranchVersion == actual.targetBranchVersion,
      remoteArticlePackageMatches(expected.package, actual.package),
      expected.files.count == actual.files.count
    else {
      return false
    }
    return zip(expected.files, actual.files).allSatisfy { expectedFile, actualFile in
      expectedFile.path == actualFile.path
        && expectedFile.operation == actualFile.operation
        && expectedFile.status == actualFile.status
        && expectedFile.remoteVersion == actualFile.remoteVersion
        && expectedFile.contentSHA256 == actualFile.contentSHA256
    }
  }

  func remoteArticlePackageContentMatches(
    _ review: RemoteArticlePublicationReview,
    package: PublishPackage
  ) throws -> Bool {
    guard review.files.count == package.files.count else { return false }
    var expected: [String: RemoteArticlePublicationReview.File] = [:]
    for file in review.files {
      guard expected.updateValue(file, forKey: file.path) == nil else {
        return false
      }
    }
    for file in package.files {
      let digest = try remoteRepositoryPublishService.contentSHA256(for: file)
      guard
        expected[file.repositoryPath]?.contentSHA256
          == digest
      else {
        return false
      }
    }
    return true
  }
}
