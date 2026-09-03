import Foundation

extension RepositoryStore {
  public func prepareRepositoryRebaseSync(
    store: WorkbenchStore
  ) async -> RepositoryRebaseSyncPreparation? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return nil }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    store.setPublishActionMessage(
      CoreL10n.text("正在冻结分叉、远端提交与本地改动…"),
      status: .inProgress
    )
    do {
      let preparation = try await Task.detached(priority: .userInitiated) {
        try RepositoryRebaseSyncService().prepare(profile: profile)
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      switch preparation {
      case .alreadySynchronized(let branch, let headSHA):
        store.setPublishActionMessage(
          CoreL10n.format("本地 %@ 已与远端同步（%@）。", branch, String(headSHA.prefix(8))),
          status: .success
        )
      case .confirmation:
        store.setPublishActionMessage(
          CoreL10n.text("已冻结变基同步复核；请确认后继续。"),
          status: .information
        )
      }
      return preparation
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      presentRepositoryRebaseSyncFailure(error, store: store)
      return nil
    }
  }

  public func applyRepositoryRebaseSync(
    _ confirmation: RepositoryRebaseSyncConfirmation,
    store: WorkbenchStore
  ) async -> RepositoryRebaseSyncResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard repositoryRebaseSyncConfirmation(confirmation, belongsTo: profile) else { return nil }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return nil }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    store.setPublishActionMessage(
      CoreL10n.text("正在封存本地改动并对已审阅远端提交变基…"),
      status: .inProgress
    )
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try RepositoryRebaseSyncService().apply(
          profile: profile,
          confirmation: confirmation
        )
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      if result.stashWasRetained {
        store.setPublishActionMessage(
          CoreL10n.format(
            "已变基同步 %@ 并恢复本地改动；恢复 stash 作为备份保留。",
            result.branch
          ),
          status: .warning
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format("已变基同步 %@，本地未提交改动已恢复。", result.branch),
          status: .success
        )
      }
      return result
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      if repositoryRebaseSyncFailureNeedsRescan(error) {
        await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
        guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      }
      presentRepositoryRebaseSyncFailure(error, store: store)
      return nil
    }
  }

  /// Freezes a safe fast-forward review. The Git service performs the
  /// repository and worktree validation; this boundary serializes it with all
  /// other repository mutations and makes stale UI results harmless.
  public func prepareRepositorySafeSync(
    store: WorkbenchStore
  ) async -> RepositorySafeSyncPreparation? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return nil }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    store.setPublishActionMessage(
      CoreL10n.text("正在安全核对本地工作区与远端分支…"),
      status: .inProgress
    )

    do {
      let preparation = try await Task.detached(priority: .userInitiated) {
        try RepositorySafeSyncService().prepare(profile: profile)
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }

      switch preparation {
      case .alreadySynchronized(let branch, let headSHA):
        store.setPublishActionMessage(
          CoreL10n.format(
            "本地 %@ 已与远端同步（%@）。",
            branch,
            String(headSHA.prefix(8))
          ),
          status: .success
        )
      case .confirmation:
        store.setPublishActionMessage(
          CoreL10n.text("已冻结安全同步复核；请确认后继续。"),
          status: .information
        )
      }
      return preparation
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      presentRepositorySafeSyncFailure(error, store: store)
      return nil
    }
  }

  /// Revalidates and applies the exact fast-forward reviewed by the user.
  /// The service archives only explicitly reconciled identical collisions;
  /// neither this method nor the service stages, commits, or pushes user WIP.
  public func applyRepositorySafeSync(
    _ confirmation: RepositorySafeSyncConfirmation,
    store: WorkbenchStore
  ) async -> RepositorySafeSyncResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard repositorySafeSyncConfirmation(confirmation, belongsTo: profile) else {
      // The confirmation came from a no-longer-active site. Do not run a
      // service operation or replace the feedback now shown for that site.
      return nil
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return nil }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    store.setPublishActionMessage(
      CoreL10n.text("正在安全同步远端分支…"),
      status: .inProgress
    )
    let recoveryRootURL = store.persistenceStore.persistence.recoveryArchiveDirectoryURL
      .appendingPathComponent("RepositorySafeSync", isDirectory: true)

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try RepositorySafeSyncService().apply(
          profile: profile,
          confirmation: confirmation,
          recoveryRootURL: recoveryRootURL
        )
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }

      // This internal overload bypasses the public "busy" guard while the
      // transaction still owns both mutation locks. The Git service has
      // completed before this point, so the scan cannot observe its temporary
      // collision-reconciliation window.
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      if result.remoteAdvancedAgain {
        store.setPublishActionMessage(
          CoreL10n.format(
            "已安全同步 %@ 到审阅版本，但远端又有新提交；请重新审阅同步。",
            result.branch
          ),
          status: .warning
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format("已安全同步 %@，本地工作区已重新扫描。", result.branch),
          status: .success
        )
      }
      return result
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      presentRepositorySafeSyncFailure(error, store: store)
      return nil
    }
  }

  private func presentRepositorySafeSyncFailure(_ error: Error, store: WorkbenchStore) {
    guard let error = error as? RepositorySafeSyncError else {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return
    }
    switch error {
    case .recoveryRequired(let recoveryDirectory, let message):
      store.setPublishActionMessage(
        CoreL10n.format("同步未完成；请保留并检查恢复备份：%@（%@）", recoveryDirectory, message),
        status: .warning
      )
    case .partial(let recoveryDirectory, let message):
      if recoveryDirectory.isEmpty {
        store.setPublishActionMessage(
          CoreL10n.format(
            "同步可能已部分完成；不会回退 HEAD。请检查当前仓库后重新扫描（%@）",
            message
          ),
          status: .warning
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format(
            "同步可能已部分完成；不会回退 HEAD。请检查恢复备份：%@（%@）",
            recoveryDirectory,
            message
          ),
          status: .warning
        )
      }
    default:
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
    }
  }

  private func repositorySafeSyncConfirmation(
    _ confirmation: RepositorySafeSyncConfirmation,
    belongsTo profile: SiteProfile
  ) -> Bool {
    guard let rootURL = profile.localRepositoryRootURL else { return false }
    return confirmation.snapshot.repositoryRoot
      == rootURL.standardizedFileURL.path
      && confirmation.snapshot.branch == profile.branch.trimmedForPublishing
  }

  private func repositoryRebaseSyncConfirmation(
    _ confirmation: RepositoryRebaseSyncConfirmation,
    belongsTo profile: SiteProfile
  ) -> Bool {
    guard let rootURL = profile.localRepositoryRootURL else { return false }
    return confirmation.snapshot.repositoryRoot == rootURL.standardizedFileURL.path
      && confirmation.snapshot.branch == profile.branch.trimmedForPublishing
  }

  private func repositoryRebaseSyncFailureNeedsRescan(_ error: Error) -> Bool {
    guard let error = error as? RepositoryRebaseSyncError else { return false }
    switch error {
    case .rebaseConflict, .stashRestoreConflict, .partial:
      return true
    default:
      return false
    }
  }

  private func presentRepositoryRebaseSyncFailure(_ error: Error, store: WorkbenchStore) {
    guard let error = error as? RepositoryRebaseSyncError else {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return
    }
    switch error {
    case .rebaseConflict:
      store.setPublishActionMessage(
        CoreL10n.format(
          "%@ 请先在冲突解决器中处理并暂存所有路径，再执行 git rebase --continue；不会自动 abort。",
          error.localizedDescription
        ),
        status: .warning
      )
    case .stashRestoreConflict:
      store.setPublishActionMessage(
        CoreL10n.format(
          "%@ 请在冲突解决器中处理；不要删除保留的恢复 stash。",
          error.localizedDescription
        ),
        status: .warning
      )
    case .partial:
      store.setPublishActionMessage(error.localizedDescription, status: .warning)
    default:
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
    }
  }
}
