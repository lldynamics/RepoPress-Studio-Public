import Foundation

extension RepositoryStore {
  public func prepareRepositoryWorktreePushRetry(
    store: WorkbenchStore
  ) async -> RepositoryWorktreePushRetryConfirmation? {
    guard !isRemoteRepositoryPublishing,
      !isRemoteRepositoryChecking,
      !isLocalRepositoryBranchOperationRunning,
      !store.isLocalRepositoryMutationRunning
    else {
      store.setGitActionMessage(
        CoreL10n.text("已有仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let profile = store.activeProfile
    let service = RepositoryWorktreePushRetryService()
    store.setGitActionMessage(
      CoreL10n.text("正在核对本地已提交但尚未推送的内容…"),
      status: .inProgress
    )
    do {
      let receipts = try store.worktreePushRecoveryStore.records(profileID: profile.id)
      for receipt in receipts
      where receipt.repositoryIdentity == DraftRepositoryIdentity(profile: profile)
        && receipt.repositoryRoot == profile.localRepositoryRootURL?.standardizedFileURL.path
      {
        let result = try await Task.detached(priority: .userInitiated) {
          try service.confirmedRecordedPush(receipt, profile: profile)
        }.value
        guard !Task.isCancelled, store.activeProfile == profile else { return nil }
        if let result {
          store.recordConfirmedWorktreePush(
            result, profile: profile, article: receipt.article,
            trackingRequest: receipt.articleTrackingRequest)
          let saved = store.finishWorktreePushRecovery(receipt)
          store.setGitActionMessage(
            saved
              ? CoreL10n.text("已核实此前的 Git 推送成功，并恢复发布记录。当前本地修改已保留；网站部署与页面版本仍需验证。")
              : CoreL10n.text("Git 推送已确认，但发布记录尚未保存。恢复证据已保留；修复保存问题后可重新核对，无需再次推送。"),
            status: saved ? .information : .warning)
          return nil
        }
      }
      let confirmation = try await Task.detached(priority: .userInitiated) {
        try service.prepare(profile: profile)
      }.value
      guard !Task.isCancelled, store.activeProfile == profile else {
        store.setGitActionMessage(
          CoreL10n.text("站点已切换，请重新审阅全部文件。"),
          status: .warning
        )
        return nil
      }
      store.setGitActionMessage(
        CoreL10n.format(
          "已找到 %@ 个待重试推送的本地提交，请确认文件清单。",
          String(confirmation.snapshot.commitCount)
        ),
        status: .information
      )
      return confirmation
    } catch RepositoryWorktreePublishError.noChanges {
      store.setGitActionMessage(
        CoreL10n.text("当前分支没有待重试推送的本地提交。"),
        status: .information
      )
      return nil
    } catch {
      store.setGitActionMessage(error.localizedDescription, status: .failure)
      return nil
    }
  }

  public func retryRepositoryWorktreePush(
    _ confirmation: RepositoryWorktreePushRetryConfirmation,
    store: WorkbenchStore
  ) async -> RepositoryWorktreePublishResult? {
    guard !isRemoteRepositoryPublishing,
      !isRemoteRepositoryChecking,
      !isLocalRepositoryBranchOperationRunning,
      !store.isLocalRepositoryMutationRunning
    else {
      store.setGitActionMessage(
        CoreL10n.text("已有仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let profile = store.activeProfile
    let service = RepositoryWorktreePushRetryService()
    isRemoteRepositoryPublishing = true
    store.setGitActionMessage(
      CoreL10n.format(
        "正在以非强制方式重试推送 %@ 个本地提交…",
        String(confirmation.snapshot.commitCount)
      ),
      status: .inProgress
    )
    defer { isRemoteRepositoryPublishing = false }

    do {
      let receipt = try store.worktreePushRecoveryStore.records(profileID: profile.id).first {
        $0.commitSHA == confirmation.snapshot.localHeadSHA
          && $0.repositoryIdentity == DraftRepositoryIdentity(profile: profile)
      }
      let result = try await Task.detached(priority: .userInitiated) {
        try service.push(profile: profile, confirmation: confirmation)
      }.value
      store.recordConfirmedWorktreePush(
        result, profile: profile, article: receipt?.article,
        trackingRequest: receipt?.articleTrackingRequest)
      let recoverySaved = receipt.map { store.finishWorktreePushRecovery($0) } ?? true
      store.setGitActionMessage(
        CoreL10n.format(
          "Git 推送已确认：本地提交 %@ 已到达 %@。网站部署与线上页面仍需另行验证。",
          String(result.commitSHA.prefix(8)),
          result.branch
        ),
        status: .information
      )
      if !recoverySaved {
        store.setGitActionMessage(
          CoreL10n.text("Git 推送已确认，但发布记录尚未保存。恢复证据已保留；修复保存问题后可重新核对，无需再次推送。"),
          status: .warning)
      }
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
      store.setGitActionMessage(error.localizedDescription, status: status)
      if store.activeProfileID == profile.id {
        await scanRepositoryAsync(store: store)
      }
      return nil
    } catch {
      store.setGitActionMessage(error.localizedDescription, status: .failure)
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
