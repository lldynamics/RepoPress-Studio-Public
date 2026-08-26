import Foundation

extension PublishingStore {
  func prependReleaseRecord(_ record: ReleaseRecord) {
    releaseRecords.insert(record, at: 0)
    if releaseRecords.count > ReleaseRecord.maximumRetainedRecords {
      releaseRecords = ReleaseRecord.limitedHistory(releaseRecords)
    }
  }

  @discardableResult
  public func resumeRemoteReview(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }

    let profile = store.profile(for: record)
    let draft: RemoteRepositoryReviewRecoveryDraft
    do {
      draft = try RemoteRepositoryReviewRecoveryDraft.make(record: record)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("继续创建 PR/MR 不可用：%@", error.localizedDescription),
        status: .warning
      )
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let token: String?
    do {
      token = try repositoryAccessToken(for: profile)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("继续创建 PR/MR 失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
    guard token != nil else {
      setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法继续创建 PR/MR。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    setPublishActionMessage(
      CoreL10n.format("正在从已写入分支 %@ 继续创建 PR/MR…", draft.branchName),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let result = try await remoteRepositoryPublishService.resumeReview(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryPublishResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let recoveredRecord = ReleaseRecord.resumedRemoteReview(
        original: record,
        profile: profile,
        result: result
      )
      if let index = releaseRecords.firstIndex(where: { $0.id == record.id }) {
        releaseRecords[index] = recoveredRecord
      } else {
        prependReleaseRecord(recoveredRecord)
      }
      setPublishActionMessage(
        CoreL10n.format("PR/MR 已恢复：%@", result.reviewURL ?? result.branchName),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let failureMessage = CoreL10n.format("继续创建 PR/MR 失败：%@", error.localizedDescription)
      setPublishActionMessage(failureMessage, status: .failure)
      if let index = releaseRecords.firstIndex(where: { $0.id == record.id }) {
        releaseRecords[index].summary = failureMessage
      }
      store.save()
      return nil
    }
  }

  @discardableResult
  public func withdrawRemoteReview(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) async -> RemoteRepositoryReviewWithdrawalResult? {
    let profile = store.profile(for: record)
    let draft: RemoteRepositoryReviewWithdrawalDraft
    do {
      draft = try RemoteRepositoryReviewWithdrawalDraft.make(record: record)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("线上 Review 撤回不可用：%@", error.localizedDescription),
        status: .warning
      )
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let token: String?
    do {
      token = try repositoryAccessToken(for: profile)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("线上 Review 撤回失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
    guard token != nil else {
      setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法撤回线上 Review。"),
        status: .warning
      )
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    setPublishActionMessage(
      CoreL10n.format(
        "正在通过 %@ 撤回 Review #%@...",
        profile.repositoryProvider.displayName,
        String(draft.reviewNumber)
      ),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let result = try await remoteRepositoryPublishService.withdrawReview(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryReviewWithdrawalResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let withdrawnReviewURLs = Set(
        [record.reviewURL, result.reviewURL].compactMap {
          $0?.trimmedForPublishing.nilIfEmpty
        }
      )
      _ = restoreRemoteCleanupRequestsAfterReviewWithdrawal(
        reviewURLs: withdrawnReviewURLs,
        profileID: profile.id
      )
      prependReleaseRecord(
        .remoteReviewWithdrawal(original: record, profile: profile, result: result)
      )
      setPublishActionMessage(
        CoreL10n.format("线上 Review 已撤回：#%@", String(result.reviewNumber)),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      setPublishActionMessage(
        CoreL10n.format("线上 Review 撤回失败：%@", error.localizedDescription),
        status: .failure
      )
      store.save()
      return nil
    }
  }

  func publishSelectedDraft(mode: LocalGitPublishMode, store: WorkbenchStore) async {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else { return }
    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishActionMessage(CoreL10n.text("没有可提交的发布包。"), status: .warning)
      return
    }

    let profile = store.profile(for: package)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      preview: preview,
      includeRepositoryReadiness: true,
      store: store
    )
    guard blockingIssues.isEmpty else {
      setPublishActionMessage(
        blockedLocalPublishMessage(action: mode.displayName, issues: blockingIssues),
        status: .warning
      )
      return
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(
      CoreL10n.format("正在执行%@…", mode.displayName),
      status: .inProgress
    )

    do {
      let result = try await localGitPublishService.publishAsync(
        package: package,
        profile: profile,
        mode: mode,
        preview: preview
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.profile(for: package)) else {
        return
      }
      let reviewDraft = remoteReviewDraftBuilder.build(package: package, profile: profile)
      store.setLocalGitPublishResult(result)
      confirmLocalGitPublishLifecycle(package: package, mode: mode)
      setPublishActionMessage(
        CoreL10n.format("%@完成：%@", mode.displayName, String(result.commitSHA.prefix(8))),
        status: .success
      )
      prependReleaseRecord(
        .gitPublish(
          package: package,
          profile: profile,
          result: result,
          reviewDraft: reviewDraft
        )
      )
      store.requestRepositoryScan()
      store.save()
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.profile(for: package)) else {
        return
      }
      setPublishActionMessage(
        CoreL10n.format("%@失败：%@", mode.displayName, error.localizedDescription),
        status: .failure
      )
    }
  }

  @discardableResult
  func refreshCommitReadiness(
    package: PublishPackage,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> LocalPublishReadiness {
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    let readiness = makeLocalPublishReadiness(package: package, profile: profile, preview: preview, store: store)
    return readiness
  }

  @discardableResult
  public func publishSelectedDraftOnlineUsingPreferredStrategy(
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else { return nil }
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }

    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishActionMessage(CoreL10n.text("没有可线上发布的文章。"), status: .warning)
      return nil
    }

    let profile = store.profile(for: package)
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    return await publishSelectedDraftOnline(
      package: package,
      profile: profile,
      mode: mode,
      store: store
    )
  }

  /// Pushes only the selected article to its stable `draft/<slug>` branch.
  /// The operation intentionally uses the same preflight and mutation guards
  /// as normal online publishing, but never marks the draft as published.
  @discardableResult
  public func publishSelectedDraftToPreviewBranch(
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else { return nil }
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }

    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishActionMessage(CoreL10n.text("没有可线上预览的文章。"), status: .warning)
      return nil
    }
    let profile = store.profile(for: package)
    return await publishSelectedDraftOnline(
      package: package,
      profile: profile,
      mode: .previewBranch,
      store: store
    )
  }

  private func publishSelectedDraftOnline(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    let preview = remoteRepositoryPublishPreview(package: package, profile: profile, mode: mode, store: store)
    if let tokenAccessFailureMessage = preview.tokenAccessFailureMessage {
      setPublishActionMessage(
        CoreL10n.format(
          "仓库 Token 状态读取失败：%@",
          tokenAccessFailureMessage
        ),
        status: .failure
      )
      return nil
    }
    guard preview.hasToken else {
      setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法线上发布。"),
        status: .warning
      )
      return nil
    }
    guard preview.blockingIssues.isEmpty else {
      setPublishActionMessage(
        blockedLocalPublishMessage(
          action: CoreL10n.text("线上发布"),
          issues: preview.blockingIssues
        ),
        status: .warning
      )
      return nil
    }
    guard preview.accessCheck != nil else {
      setPublishActionMessage(
        CoreL10n.format(
          "请先检查 %@ Token 权限，确认具备写入权限后再线上发布。",
          profile.repositoryProvider.displayName
        ),
        status: .warning
      )
      return nil
    }
    guard preview.canPublish else {
      setPublishActionMessage(
        CoreL10n.text("Token 无写入权限，无法线上发布。"),
        status: .failure
      )
      return nil
    }

    guard await ensureDraftMaterializedForRemotePublish(
      package: package,
      profile: profile,
      store: store
    ) else {
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    setPublishActionMessage(
      mode == .directCommit
        ? CoreL10n.format("正在通过 %@ 核对远端版本并执行%@...", profile.repositoryProvider.displayName, mode.displayName)
        : CoreL10n.format("正在通过 %@ 执行%@...", profile.repositoryProvider.displayName, mode.displayName),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let progressHandler: @Sendable (RemoteRepositoryPublishProgress) -> Void = { [weak self, weak store] progress in
        Task { @MainActor in
          guard let self, let store,
                self.remoteRepositoryMutationIsCurrent(operation, store: store) else { return }
          store.setRemoteRepositoryPublishProgress(progress)
        }
      }
      let result = try await remoteRepositoryPublishService.publish(
        package: package,
        profile: profile,
        mode: mode,
        token: token,
        onProgress: progressHandler
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryPublishResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let releaseRecord = ReleaseRecord.remotePublish(package: package, profile: profile, result: result)
      prependReleaseRecord(releaseRecord)
      markDraftsAsPublishedIfDirectRemoteCommit(mode: mode, draftIDs: [package.draftID])
      confirmDirectRemotePublishLifecycle(packages: [package], result: result)
      if mode.createsReview {
        markRemotePublishReviewSuccess(packages: [package])
      }
      if mode != .previewBranch {
        store.recordRemoteRepositoryPublishInAutoSync(result, profileID: profile.id)
      }
      let commitSummary = result.commitSHA.map { String($0.prefix(8)) } ?? CoreL10n.text("无 commit")
      let adoptedSummary = result.automaticallyAdoptedPaths.isEmpty
        ? ""
        : "；自动认领 \(result.automaticallyAdoptedPaths.count) 个已存在且内容一致的文件"
      let branchSummary = mode == .previewBranch
        ? CoreL10n.format("；分支 %@", result.branchName)
        : ""
      setPublishActionMessage(
        CoreL10n.format("%@完成：%@%@%@", mode.displayName, commitSummary, branchSummary, adoptedSummary),
        status: .success
      )
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      if store.remoteRepositoryPublishProgress?.stage != .completed {
        store.setRemoteRepositoryPublishProgress(.init(
          stage: .completed,
          progress: 1,
          message: CoreL10n.text("线上发布完成"),
          detail: CoreL10n.text("发布流程已结束")
        ))
      }
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let message = CoreL10n.format("%@失败：%@", mode.displayName, error.localizedDescription)
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      store.setRemoteRepositoryPublishProgress(.init(
        stage: .failed,
        progress: nil,
        message: CoreL10n.text("发布失败"),
        detail: error.localizedDescription
      ))
      let releaseRecord = ReleaseRecord.remotePublishFailure(
        package: package,
        profile: profile,
        mode: mode,
        errorMessage: message,
        changedPaths: partialFailure?.changedPaths,
        commitSHA: partialFailure?.commitSHA
      )
      prependReleaseRecord(releaseRecord)
      markRemotePublishFailure(packages: [package], error: error)
      setPublishActionMessage(message, status: .failure)
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }

  @discardableResult
  public func rollbackRemoteRelease(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) async -> RemoteRepositoryRollbackResult? {
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }

    let profile = store.profile(for: record)
    let draft: RemoteRepositoryRollbackDraft
    do {
      draft = try RemoteRepositoryRollbackDraft.make(record: record)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("线上回滚不可用：%@", error.localizedDescription),
        status: .warning
      )
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let token: String?
    do {
      token = try repositoryAccessToken(for: profile)
    } catch {
      setPublishActionMessage(
        CoreL10n.format("线上回滚失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
    guard token != nil else {
      setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法执行线上回滚。"),
        status: .warning
      )
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    setPublishActionMessage(
      CoreL10n.format(
        "正在通过 %@ 回滚 %@...",
        profile.repositoryProvider.displayName,
        String(draft.commitSHA.prefix(8))
      ),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let result = try await remoteRepositoryPublishService.rollback(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryRollbackResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let rollbackRecord = ReleaseRecord.remoteRollback(original: record, profile: profile, result: result)
      prependReleaseRecord(rollbackRecord)
      setPublishActionMessage(
        CoreL10n.format("线上回滚完成：%@", result.shortRollbackCommitSHA),
        status: .success
      )
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(rollbackRecord) {
        await store.refreshDeploymentStatus(for: rollbackRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      setPublishActionMessage(
        CoreL10n.format("线上回滚失败：%@", error.localizedDescription),
        status: .failure
      )
      store.save()
      return nil
    }
  }
}
