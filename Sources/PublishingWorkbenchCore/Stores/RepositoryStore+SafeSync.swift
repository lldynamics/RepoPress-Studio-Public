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
    guard repositoryRebaseRecoveryContext(for: profile) == nil,
      repositoryRebaseRecoveryDiagnostic == nil
    else {
      store.setPublishActionMessage(
        CoreL10n.text("仍有未完成的变基恢复上下文，请先完成或检查恢复。"),
        status: .warning
      )
      return nil
    }
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
    guard repositoryRebaseRecoveryContext(for: profile) == nil,
      repositoryRebaseRecoveryDiagnostic == nil
    else {
      store.setPublishActionMessage(
        CoreL10n.text("仍有未完成的变基恢复上下文，请先完成或检查恢复。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return nil }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    store.setPublishActionMessage(
      CoreL10n.text("正在封存本地改动并对已审阅远端提交变基…"),
      status: .inProgress
    )
    let rebaseSyncService = makeRepositoryRebaseSyncService(
      profile: profile,
      store: store
    )
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try rebaseSyncService.apply(
          profile: profile,
          confirmation: confirmation
        )
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      var recoveryCleanupError: Error?
      do {
        try clearRepositoryRebaseRecovery(profile: profile, store: store)
      } catch {
        recoveryCleanupError = error
        repositoryRebaseRecoveryDiagnostic = error.localizedDescription
      }
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      if let recoveryCleanupError {
        store.setPublishActionMessage(
          CoreL10n.format(
            "变基和本地改动恢复已完成，但恢复记录清理失败：%@",
            recoveryCleanupError.localizedDescription
          ),
          status: .warning
        )
      } else if result.stashWasRetained {
        store.setPublishActionMessage(
          CoreL10n.format(
            "已变基同步 %@ 并恢复本地改动；恢复 stash 作为备份保留。",
            result.branch
          ),
          status: .warning
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format(
            "已变基同步 %@，本地未提交改动已恢复；文章变化请在文件变更中审阅导入。",
            result.branch
          ),
          status: .success
        )
      }
      return result
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      let recoverySaveError = recordRecoveryContext(
        from: error,
        profile: profile,
        store: store
      )
      // The service may have durably advanced a recovery phase before a later
      // diagnostic command failed. Always rescan so the persistent banner is
      // installed in this process, not only after the next app launch.
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return nil }
      presentRepositoryRebaseSyncFailure(error, store: store)
      if let recoverySaveError {
        store.setPublishActionMessage(
          CoreL10n.format(
            "%@ 恢复记录未能持久化：%@",
            error.localizedDescription,
            recoverySaveError.localizedDescription
          ),
          status: .warning
        )
      }
      return nil
    }
  }

  public func prepareRepositorySafeSync(
    store: WorkbenchStore
  ) async -> RepositorySafeSyncPreparation? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard repositoryRebaseRecoveryContext(for: profile) == nil,
      repositoryRebaseRecoveryDiagnostic == nil
    else {
      store.setPublishActionMessage(
        CoreL10n.text("仍有未完成的变基恢复上下文，请先完成或检查恢复。"),
        status: .warning
      )
      return nil
    }
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

  public func applyRepositorySafeSync(
    _ confirmation: RepositorySafeSyncConfirmation,
    store: WorkbenchStore
  ) async -> RepositorySafeSyncResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard repositorySafeSyncConfirmation(confirmation, belongsTo: profile) else { return nil }
    guard repositoryRebaseRecoveryContext(for: profile) == nil,
      repositoryRebaseRecoveryDiagnostic == nil
    else {
      store.setPublishActionMessage(
        CoreL10n.text("仍有未完成的变基恢复上下文，请先完成或检查恢复。"),
        status: .warning
      )
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
          CoreL10n.format(
            "已安全同步 %@，本地工作区已重新扫描；文章变化请在文件变更中审阅导入。",
            result.branch
          ),
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
    return confirmation.snapshot.repositoryRoot == rootURL.standardizedFileURL.path
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

  private func presentRepositoryRebaseSyncFailure(_ error: Error, store: WorkbenchStore) {
    guard let error = error as? RepositoryRebaseSyncError else {
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return
    }
    switch error {
    case .rebaseConflict:
      store.setPublishActionMessage(
        CoreL10n.format(
          "%@ 请在冲突解决器中处理并暂存所有路径，然后在软件内继续变基；不会自动放弃。",
          error.localizedDescription
        ),
        status: .warning
      )
    case .stashRestoreConflict:
      store.setPublishActionMessage(
        CoreL10n.format(
          "%@ 请在冲突解决器中处理；不会删除保留的恢复 stash。",
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

  func makeRepositoryRebaseSyncService(
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> RepositoryRebaseSyncService {
    let recoveryStore = RepositoryRebaseRecoveryStore(
      recoveryArchiveDirectoryURL: store.persistenceStore.persistence.recoveryArchiveDirectoryURL
    )
    let profileID = profile.id
    return RepositoryRebaseSyncService { context in
      try recoveryStore.save(context, profileID: profileID)
    }
  }
}
