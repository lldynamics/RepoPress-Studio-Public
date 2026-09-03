import Foundation

extension RepositoryStore {
  /// Builds a read-only, frozen review of every pending Git worktree change.
  /// The service performs its own remote and repository identity checks; this
  /// store boundary only coordinates protected-workbench and operation state.
  public func prepareRepositoryWorktreePublish(
    store: WorkbenchStore,
    commitMessage: String = "Publish all site changes"
  ) async -> RepositoryWorktreePublishConfirmation? {
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
    let service = RepositoryWorktreePublishService()
    store.setPublishActionMessage(
      CoreL10n.text("正在核对仓库全部待提交文件与远端分支…"),
      status: .inProgress
    )
    do {
      let confirmation = try await Task.detached(priority: .userInitiated) {
        try service.prepare(profile: profile, commitMessage: commitMessage)
      }.value
      guard store.activeProfileID == profile.id else {
        store.setPublishActionMessage(
          CoreL10n.text("站点已切换，请重新审阅全部文件。"),
          status: .warning
        )
        return nil
      }
      store.setPublishActionMessage(
        CoreL10n.format(
          "已冻结 %@ 个待推送文件，请确认完整清单。",
          String(confirmation.snapshot.entries.count)
        ),
        status: .information
      )
      return confirmation
    } catch {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return nil
    }
  }

  /// Commits and pushes exactly the frozen review. A stale review is rejected
  /// by the service before mutation. A push failure deliberately preserves the
  /// newly-created local commit and is reported as a partial outcome.
  public func publishRepositoryWorktree(
    _ confirmation: RepositoryWorktreePublishConfirmation,
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
    let service = RepositoryWorktreePublishService()
    isRemoteRepositoryPublishing = true
    store.setPublishActionMessage(
      CoreL10n.format(
        "正在提交并推送 %@ 个已审阅文件…",
        String(confirmation.snapshot.entries.count)
      ),
      status: .inProgress
    )
    defer { isRemoteRepositoryPublishing = false }

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try service.publish(profile: profile, confirmation: confirmation)
      }.value
      store.setPublishActionMessage(
        CoreL10n.format(
          "Git 推送已确认：仓库全部 %@ 个文件变更已到达 %@（提交 %@）；正在等待部署与文章页面验证。",
          String(confirmation.snapshot.entries.count),
          result.branch,
          String(result.commitSHA.prefix(8))
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
