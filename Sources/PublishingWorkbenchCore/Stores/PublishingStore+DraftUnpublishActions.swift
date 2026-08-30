import Foundation

extension PublishingStore {
  @discardableResult
  public func unpublishDraft(
    id draftID: UUID,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return nil }
    let hasRepositoryFile =
      !draft.isGeneralDraft
      && draft.repositoryPath?.trimmedForPublishing.nilIfEmpty != nil

    deleteDraft(id: draftID, store: store)
    guard hasRepositoryFile,
      let request = draftRepositoryCleanupRequests.first(where: {
        $0.draftID == draftID && $0.needsAttention
      })
    else {
      return nil
    }
    return await publishRepositoryCleanupRequestOnline(request.id, store: store)
  }

  @discardableResult
  public func publishRepositoryCleanupRequestOnline(
    _ requestID: UUID,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard
      let requestIndex = draftRepositoryCleanupRequests.firstIndex(where: {
        $0.id == requestID
      })
    else {
      return nil
    }
    if !draftRepositoryCleanupRequests[requestIndex].hasRemoteCleanupIntent {
      draftRepositoryCleanupRequests[requestIndex].enqueueRemoteCleanup()
      store.save()
    }
    let request = draftRepositoryCleanupRequests[requestIndex]
    guard request.needsRemoteCleanup,
      let profile = profiles.first(where: { $0.id == request.siteProfileID }),
      let package = draftLifecycleService.cleanupPackage(for: [request])
    else {
      return nil
    }

    guard store.canUseProtectedWorkbench else {
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: store.quickHideOperationMessage,
        store: store
      )
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      let message = CoreL10n.text("已有远端仓库操作正在运行；文章已进入下线队列，稍后可在发布抽屉重试。")
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: message,
        store: store
      )
      return nil
    }

    setPublishActionMessage(
      CoreL10n.format("正在核对并下线「%@」…", request.draftTitle.nilIfEmpty ?? CoreL10n.text("未命名文章")),
      status: .inProgress
    )

    let token: String?
    let accessCheck: RemoteRepositoryAccessCheck
    do {
      token = try repositoryAccessToken(for: profile)
      // Cleanup requests can belong to a site other than the currently active
      // editor profile. Always validate the request's own repository and token,
      // and avoid trusting an indefinitely cached foreground access check.
      accessCheck = try await remoteRepositoryPublishService.checkAccess(
        profile: profile,
        token: token
      )
    } catch {
      let message = CoreL10n.format(
        "远端下线权限检查失败：%@；请求已保留在发布抽屉。",
        error.localizedDescription
      )
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: message,
        store: store
      )
      return nil
    }
    guard accessCheck.canWrite else {
      let message = CoreL10n.text("远端下线暂未执行：Token 没有仓库写入权限；请求已保留在发布抽屉。")
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: message,
        store: store
      )
      return nil
    }

    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      let message = CoreL10n.text("已有远端仓库操作正在运行；文章已进入下线队列，稍后可在发布抽屉重试。")
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: message,
        store: store
      )
      return nil
    }
    defer { finishRemoteRepositoryMutation(operation, store: store) }
    store.setRemoteRepositoryPublishProgress(nil)

    do {
      let progressHandler: @Sendable (RemoteRepositoryPublishProgress) -> Void = {
        [weak self, weak store] progress in
        Task { @MainActor in
          guard let self, let store,
            self.remoteRepositoryMutationIsCurrent(operation, store: store)
          else { return }
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
      let releaseRecord = ReleaseRecord.remotePublish(
        package: package,
        profile: profile,
        result: result
      )
      prependReleaseRecord(releaseRecord)
      _ = recordRemoteRepositoryCleanupResult(
        requestIDs: Set([request.id]),
        result: result
      )
      store.recordRemoteRepositoryPublishInAutoSync(result, profileID: profile.id)

      let locallyCleanedCount = cleanLocalRepositoryFilesAfterUnpublish(
        requests: [request],
        store: store
      )
      let remoteSummary: String
      if result.mode == .reviewRequest,
        result.reviewURL?.trimmedForPublishing.nilIfEmpty != nil
          || result.changedPaths.contains(request.repositoryPath)
      {
        remoteSummary = CoreL10n.text("已创建下线 PR/MR，合并后软件会自动确认远端删除")
      } else if result.changedPaths.isEmpty {
        remoteSummary = CoreL10n.text("远端文件已不存在，按幂等成功处理")
      } else {
        remoteSummary = CoreL10n.text("远端文章已下线")
      }
      let localSummary =
        locallyCleanedCount == 1
        ? CoreL10n.text("本地 Markdown 已清理")
        : CoreL10n.text("本地 Markdown 仍在待清理队列")
      setPublishActionMessage(
        CoreL10n.format("%@；%@。图片资源未自动删除。", remoteSummary, localSummary),
        status: locallyCleanedCount == 1 ? .success : .warning
      )
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      let message = CoreL10n.format("远端下线失败：%@", error.localizedDescription)
      _ = recordRemoteRepositoryCleanupFailure(
        requestIDs: Set([request.id]),
        message: error.localizedDescription
      )
      prependReleaseRecord(
        .remotePublishFailure(
          package: package,
          profile: profile,
          mode: mode,
          errorMessage: message,
          changedPaths: partialFailure?.changedPaths,
          commitSHA: partialFailure?.commitSHA
        )
      )
      store.setRemoteRepositoryPublishProgress(
        .init(
          stage: .failed,
          progress: nil,
          message: CoreL10n.text("下线失败"),
          detail: error.localizedDescription
        )
      )
      finishRepositoryCleanupAttempt(
        requests: [request],
        remoteFailureMessage: message,
        store: store
      )
      return nil
    }
  }

  private func cleanLocalRepositoryFilesAfterUnpublish(
    requests: [DraftRepositoryCleanupRequest],
    store: WorkbenchStore
  ) -> Int {
    requests.reduce(into: 0) { count, request in
      guard
        draftRepositoryCleanupRequests.first(where: { $0.id == request.id })?.needsLocalCleanup
          == true
      else {
        return
      }
      if performLocalRepositoryCleanup(request.id, store: store) {
        count += 1
      }
    }
  }

  private func finishRepositoryCleanupAttempt(
    requests: [DraftRepositoryCleanupRequest],
    remoteFailureMessage: String,
    store: WorkbenchStore
  ) {
    _ = recordRemoteRepositoryCleanupFailure(
      requestIDs: Set(requests.map(\.id)),
      message: remoteFailureMessage
    )
    let locallyCleanedCount = cleanLocalRepositoryFilesAfterUnpublish(
      requests: requests,
      store: store
    )
    let localSummary =
      locallyCleanedCount > 0
      ? CoreL10n.text("本地 Markdown 已清理")
      : CoreL10n.text("本地 Markdown 仍在待清理队列")
    setPublishActionMessage(
      CoreL10n.format("%@；%@。可在发布抽屉重试，图片资源未删除。", remoteFailureMessage, localSummary),
      status: .warning
    )
    store.save()
  }
}
