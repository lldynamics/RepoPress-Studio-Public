import Foundation

extension PublishingStore {
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
      publishActionMessage = "线上 Review 撤回不可用：\(error.localizedDescription)"
      return nil
    }

    guard store.repositoryTokenAvailability.hasToken || (try? repositoryAccessToken(for: profile)) != nil else {
      publishActionMessage = "仓库访问 Token 未保存，无法撤回线上 Review。"
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    let access = store.consumeFeatureUse(.onlinePublishing)
    guard access.isAllowed else {
      publishActionMessage = access.message
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    publishActionMessage = "正在通过 \(profile.repositoryProvider.displayName) 撤回 Review #\(draft.reviewNumber)..."
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let result = try await remoteRepositoryPublishService.withdrawReview(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryReviewWithdrawalResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      releaseRecords.insert(
        .remoteReviewWithdrawal(original: record, profile: profile, result: result),
        at: 0
      )
      publishActionMessage = "线上 Review 已撤回：#\(result.reviewNumber)"
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      publishActionMessage = "线上 Review 撤回失败：\(error.localizedDescription)"
      store.save()
      return nil
    }
  }

  func publishSelectedDraft(mode: LocalGitPublishMode, store: WorkbenchStore) async {
    if let draftID = publishPackage?.draftID {
      _ = store.focusDraft(draftID, section: .sync)
    }

    guard let package = publishPackage else {
      publishActionMessage = "没有可提交的发布包。"
      return
    }

    let profile = store.profile(for: package)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    localPublishPreview = preview
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      profile: profile,
      preview: preview,
      includeRepositoryReadiness: true,
      store: store
    )
    localPublishReadiness = makeLocalPublishReadiness(package: package, profile: profile, preview: preview, store: store)
    guard blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: mode.displayName, issues: blockingIssues)
      return
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在执行\(mode.displayName)…"

    do {
      let result = try await localGitPublishService.publishAsync(package: package, profile: profile, mode: mode)
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.profile(for: package)) else {
        return
      }
      let reviewDraft = remoteReviewDraftBuilder.build(package: package, profile: profile)
      store.setLocalGitPublishResult(result)
      confirmLocalGitPublishLifecycle(package: package, mode: mode)
      publishActionMessage = "\(mode.displayName)完成：\(result.commitSHA.prefix(8))"
      releaseRecords.insert(
        .gitPublish(
          package: package,
          profile: profile,
          result: result,
          reviewDraft: reviewDraft
        ),
        at: 0
      )
      store.requestRepositoryScan()
      store.save()
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.profile(for: package)) else {
        return
      }
      publishActionMessage = "\(mode.displayName)失败：\(error.localizedDescription)"
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
    localPublishPreview = preview
    localPublishReadiness = readiness
    return readiness
  }

  @discardableResult
  public func publishSelectedDraftOnlineUsingPreferredStrategy(
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard store.canUseProtectedWorkbench else {
      publishActionMessage = store.privacyLockedOperationMessage
      return nil
    }

    let package: PublishPackage
    if let currentPackage = publishPackage {
      package = currentPackage
    } else if let draft = store.selectedDraft {
      package = store.publishingPackage(for: draft)
      publishPackage = package
    } else {
      publishActionMessage = "没有可线上发布的文章。"
      return nil
    }

    _ = store.focusDraft(package.draftID, section: .sync)

    let profile = store.profile(for: package)
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    let preview = remoteRepositoryPublishPreview(package: package, profile: profile, mode: mode, store: store)
    guard preview.hasToken else {
      publishActionMessage = "仓库访问 Token 未保存，无法线上发布。"
      return nil
    }
    guard preview.blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: "线上发布", issues: preview.blockingIssues)
      return nil
    }
    guard preview.accessCheck != nil else {
      publishActionMessage = "请先检查 \(profile.repositoryProvider.displayName) Token 权限，确认具备写入权限后再线上发布。"
      return nil
    }
    guard preview.canPublish else {
      publishActionMessage = "Token 无写入权限，无法线上发布。"
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    let access = store.consumeFeatureUse(.onlinePublishing)
    guard access.isAllowed else {
      publishActionMessage = access.message
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    publishActionMessage = "正在通过 \(profile.repositoryProvider.displayName) 执行\(mode.displayName)..."
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
      releaseRecords.insert(releaseRecord, at: 0)
      markDraftsAsPublishedIfDirectRemoteCommit(mode: mode, draftIDs: [package.draftID])
      confirmDirectRemotePublishLifecycle(packages: [package], result: result)
      store.recordRemoteRepositoryPublishInAutoSync(result)
      publishActionMessage = "\(mode.displayName)完成：\(result.commitSHA.map { String($0.prefix(8)) } ?? "无 commit")"
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      if store.remoteRepositoryPublishProgress?.stage != .completed {
        store.setRemoteRepositoryPublishProgress(.init(
          stage: .completed,
          progress: 1,
          message: "线上发布完成",
          detail: "发布流程已结束"
        ))
      }
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let message = "\(mode.displayName)失败：\(error.localizedDescription)"
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      store.setRemoteRepositoryPublishProgress(.init(
        stage: .failed,
        progress: nil,
        message: "发布失败",
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
      releaseRecords.insert(releaseRecord, at: 0)
      publishActionMessage = message
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
      publishActionMessage = store.privacyLockedOperationMessage
      return nil
    }

    let profile = store.profile(for: record)
    let draft: RemoteRepositoryRollbackDraft
    do {
      draft = try RemoteRepositoryRollbackDraft.make(record: record)
    } catch {
      publishActionMessage = "线上回滚不可用：\(error.localizedDescription)"
      return nil
    }

    guard store.repositoryTokenAvailability.hasToken || (try? repositoryAccessToken(for: profile)) != nil else {
      publishActionMessage = "仓库访问 Token 未保存，无法执行线上回滚。"
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    let access = store.consumeFeatureUse(.onlinePublishing)
    guard access.isAllowed else {
      publishActionMessage = access.message
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    publishActionMessage = "正在通过 \(profile.repositoryProvider.displayName) 回滚 \(String(draft.commitSHA.prefix(8)))..."
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let result = try await remoteRepositoryPublishService.rollback(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryRollbackResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let rollbackRecord = ReleaseRecord.remoteRollback(original: record, profile: profile, result: result)
      releaseRecords.insert(rollbackRecord, at: 0)
      publishActionMessage = "线上回滚完成：\(result.shortRollbackCommitSHA)"
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(rollbackRecord) {
        await store.refreshDeploymentStatus(for: rollbackRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      publishActionMessage = "线上回滚失败：\(error.localizedDescription)"
      store.save()
      return nil
    }
  }
}
