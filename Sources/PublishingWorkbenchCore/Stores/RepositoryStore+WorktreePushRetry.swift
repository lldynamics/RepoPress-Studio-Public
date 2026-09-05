import Foundation

extension RepositoryStore {
  public func prepareRepositoryWorktreePushRetry(
    store: WorkbenchStore
  ) async -> RepositoryWorktreePushRetryConfirmation? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    guard !isRemoteRepositoryPublishing,
      !isRemoteRepositoryChecking,
      !isLocalRepositoryBranchOperationRunning,
      !store.isLocalRepositoryMutationRunning
    else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let profile = store.activeProfile
    let service = RepositoryWorktreePushRetryService()
    store.setPublishActionMessage(
      CoreL10n.text("正在核对本地已提交但尚未推送的内容…"),
      status: .inProgress
    )
    do {
      let confirmation = try await Task.detached(priority: .userInitiated) {
        try service.prepare(profile: profile)
      }.value
      guard !Task.isCancelled, store.activeProfileID == profile.id else {
        store.setPublishActionMessage(
          CoreL10n.text("站点已切换，请重新审阅全部文件。"),
          status: .warning
        )
        return nil
      }
      store.setPublishActionMessage(
        CoreL10n.format(
          "已找到 %@ 个待重试推送的本地提交，请确认文件清单。",
          String(confirmation.snapshot.commitCount)
        ),
        status: .information
      )
      return confirmation
    } catch RepositoryWorktreePublishError.noChanges {
      store.setPublishActionMessage(
        CoreL10n.text("当前分支没有待重试推送的本地提交。"),
        status: .information
      )
      return nil
    } catch {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return nil
    }
  }

  public func retryRepositoryWorktreePush(
    _ confirmation: RepositoryWorktreePushRetryConfirmation,
    store: WorkbenchStore
  ) async -> RepositoryWorktreePublishResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    guard !isRemoteRepositoryPublishing,
      !isRemoteRepositoryChecking,
      !isLocalRepositoryBranchOperationRunning,
      !store.isLocalRepositoryMutationRunning
    else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let profile = store.activeProfile
    let service = RepositoryWorktreePushRetryService()
    isRemoteRepositoryPublishing = true
    store.setPublishActionMessage(
      CoreL10n.format(
        "正在以非强制方式重试推送 %@ 个本地提交…",
        String(confirmation.snapshot.commitCount)
      ),
      status: .inProgress
    )
    defer { isRemoteRepositoryPublishing = false }

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try service.push(profile: profile, confirmation: confirmation)
      }.value
      store.recordConfirmedWorktreePush(result, profile: profile, article: nil)
      store.setPublishActionMessage(
        CoreL10n.format(
          "Git 推送已确认：本地提交 %@ 已到达 %@。网站部署与线上页面仍需另行验证。",
          String(result.commitSHA.prefix(8)),
          result.branch
        ),
        status: .information
      )
      if store.activeProfileID == profile.id {
        await scanRepositoryAsync(store: store)
      }
      return result
    } catch let error as RepositoryWorktreePublishError {
      let status: PublishActionMessageStatus
      if case .commitSucceededButPushFailed = error {
        status = .warning
      } else {
        status = .failure
      }
      store.setPublishActionMessage(error.localizedDescription, status: status)
      if store.activeProfileID == profile.id {
        await scanRepositoryAsync(store: store)
      }
      return nil
    } catch {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return nil
    }
  }
}

extension WorkbenchStore {
  public func prepareRepositoryWorktreePushRetry()
    async -> RepositoryWorktreePushRetryConfirmation?
  {
    await repositoryStore.prepareRepositoryWorktreePushRetry(store: self)
  }

  public func retryRepositoryWorktreePush(
    _ confirmation: RepositoryWorktreePushRetryConfirmation
  ) async -> RepositoryWorktreePublishResult? {
    await repositoryStore.retryRepositoryWorktreePush(confirmation, store: self)
  }
}
