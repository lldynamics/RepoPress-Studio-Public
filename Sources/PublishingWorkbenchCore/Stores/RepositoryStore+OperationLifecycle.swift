import Foundation
import PublishingGitCore

extension RepositoryStore {
  /// Completes the currently scanned merge/rebase step. Rebase completion also
  /// restores the exact RepoPress stash recorded before the operation.
  @discardableResult
  public func completeRepositoryOperation(
    mergeMessage: String,
    store: WorkbenchStore
  ) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let profile = store.activeProfile
    guard let lifecycle = repositoryMergeConflictSession(for: profile, store: store)?
      .operationLifecycle
    else {
      store.setPublishActionMessage(
        CoreL10n.text("请先重新扫描仓库，再完成 Git 操作。"),
        status: .warning
      )
      return false
    }
    guard lifecycle.isCompletionReady else {
      store.setPublishActionMessage(
        lifecycle.unresolvedConflictCount > 0
          ? CoreL10n.format(
            "仍有 %d 个未解决冲突，请先应用最终版本并暂存。",
            lifecycle.unresolvedConflictCount
          )
          : CoreL10n.text("当前 Git 状态不支持通用的完成操作。"),
        status: .warning
      )
      return false
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return false }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    let repositoryService = repositoryService
    do {
      switch lifecycle.kind {
      case .merge:
        store.setPublishActionMessage(CoreL10n.text("正在完成合并提交…"), status: .inProgress)
        _ = try await Task.detached(priority: .userInitiated) {
          try repositoryService.commitMerge(profile: profile, message: mergeMessage)
        }.value
        guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
        await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
        store.setPublishActionMessage(
          CoreL10n.text("合并已完成并提交，发布门禁已恢复正常检查。"),
          status: .success
        )
        return true

      case .rebase:
        store.setPublishActionMessage(CoreL10n.text("正在继续变基…"), status: .inProgress)
        let after = try await Task.detached(priority: .userInitiated) {
          try repositoryService.continueRebase(profile: profile)
        }.value
        guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
        if after.kind == .rebase {
          await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
          store.setPublishActionMessage(
            CoreL10n.text("变基已进入下一个冲突步骤，请继续逐个处理。"),
            status: .warning
          )
          return true
        }
        try await restoreRebaseWIPIfNeeded(profile: profile, store: store)
        guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
        await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
        store.setPublishActionMessage(
          CoreL10n.text("变基已完成，变基前的本地改动已按精确 stash 恢复。"),
          status: .success
        )
        return true

      case .none, .unmergedIndex, .ambiguous:
        return false
      }
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
      let recoverySaveError = recordRecoveryContext(from: error, profile: profile, store: store)
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      presentRepositoryOperationFailure(error, recoverySaveError: recoverySaveError, store: store)
      return false
    }
  }

  /// Runs Git's native abort for the exact detected sequencer. For a RepoPress
  /// rebase, the pre-rebase WIP is then restored by its frozen stash SHA.
  @discardableResult
  public func abortRepositoryOperation(store: WorkbenchStore) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let profile = store.activeProfile
    guard let lifecycle = repositoryMergeConflictSession(for: profile, store: store)?
      .operationLifecycle
    else {
      store.setPublishActionMessage(
        CoreL10n.text("请先重新扫描仓库，再放弃 Git 操作。"),
        status: .warning
      )
      return false
    }
    guard lifecycle.kind == .merge || lifecycle.kind == .rebase else {
      store.setPublishActionMessage(
        CoreL10n.text("当前不是可安全放弃的 Merge/Rebase sequencer。"),
        status: .warning
      )
      return false
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return false }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }

    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    let repositoryService = repositoryService
    do {
      switch lifecycle.kind {
      case .merge:
        _ = try await Task.detached(priority: .userInitiated) {
          try repositoryService.abortMerge(profile: profile)
        }.value
      case .rebase:
        _ = try await Task.detached(priority: .userInitiated) {
          try repositoryService.abortRebase(profile: profile)
        }.value
        guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
        try await restoreRebaseWIPIfNeeded(
          profile: profile,
          store: store,
          afterAbort: true
        )
      case .none, .unmergedIndex, .ambiguous:
        return false
      }
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        lifecycle.kind == .merge
          ? CoreL10n.text("已放弃本次合并，仓库已恢复到合并前状态。")
          : CoreL10n.text("已放弃本次变基，变基前的本地改动已恢复。"),
        status: .success
      )
      return true
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
      let recoverySaveError = recordRecoveryContext(from: error, profile: profile, store: store)
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      presentRepositoryOperationFailure(error, recoverySaveError: recoverySaveError, store: store)
      return false
    }
  }

  /// A stash-apply conflict has no Git sequencer to continue. Once every U
  /// entry is resolved, this acknowledges the restored WIP and intentionally
  /// keeps the stash as a recoverable backup.
  @discardableResult
  public func finishRepositoryStashConflictRecovery(store: WorkbenchStore) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let profile = store.activeProfile
    guard let recovery = repositoryRebaseRecoveryContext(for: profile),
      recovery.phase == .stashRestoreConflict || recovery.phase == .completed
    else {
      store.setPublishActionMessage(CoreL10n.text("当前没有待完成的 stash 恢复。"), status: .warning)
      return false
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return false }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }
    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)

    let repositoryService = repositoryService
    let lifecycle = await Task.detached(priority: .userInitiated) {
      repositoryService.operationLifecycle(profile: profile)
    }.value
    guard lifecycle.kind == .none else {
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        lifecycle.unresolvedConflictCount > 0
          ? CoreL10n.format("仍有 %d 个 stash 恢复冲突未解决。", lifecycle.unresolvedConflictCount)
          : CoreL10n.text("当前 Git 状态尚未恢复正常。"),
        status: .warning
      )
      return false
    }
    do {
      try clearRepositoryRebaseRecovery(profile: profile, store: store)
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        recovery.phase == .completed
          ? CoreL10n.text("已清理完成的恢复记录；不会重复应用 stash。")
          : CoreL10n.text("本地改动冲突已全部处理；原恢复 stash 作为备份保留。"),
        status: .warning
      )
      return true
    } catch {
      repositoryRebaseRecoveryDiagnostic = error.localizedDescription
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return false
    }
  }

  /// Removes only RepoPress's profile-scoped recovery sidecar after an
  /// explicit user confirmation. The Git stash, index, HEAD, and worktree are
  /// deliberately left untouched, providing an in-app escape hatch for a
  /// corrupt, mismatched, or crash-ambiguous recovery record.
  @discardableResult
  public func discardRepositoryRebaseRecoveryRecord(store: WorkbenchStore) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let profile = store.activeProfile
    guard repositoryRebaseRecoveryProfileID == profile.id,
      repositoryRebaseRecoveryContext != nil || repositoryRebaseRecoveryDiagnostic != nil
    else {
      store.setPublishActionMessage(
        CoreL10n.text("当前没有待处理的变基恢复记录。"),
        status: .warning
      )
      return false
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return false }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }
    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)

    let repositoryService = repositoryService
    let lifecycle = await Task.detached(priority: .userInitiated) {
      repositoryService.operationLifecycle(profile: profile)
    }.value
    guard lifecycle.kind == .none else {
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        CoreL10n.text("当前仍有 Git 操作，不能移除其恢复记录。"),
        status: .warning
      )
      return false
    }

    do {
      try clearRepositoryRebaseRecovery(profile: profile, store: store)
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        CoreL10n.text("已移除软件恢复记录；Git stash 与工作区均保持不变。"),
        status: .warning
      )
      return true
    } catch {
      repositoryRebaseRecoveryDiagnostic = error.localizedDescription
      store.setPublishActionMessage(error.localizedDescription, status: .failure)
      return false
    }
  }

  /// Restores a verified stash after an app interruption only when no Git
  /// sequencer remains and the frozen repository identity still matches.
  @discardableResult
  public func restoreRepositoryRebaseWIP(store: WorkbenchStore) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let profile = store.activeProfile
    guard let recovery = repositoryRebaseRecoveryContext(for: profile),
      [.stashedBeforeRebase, .rebaseConflict, .rebaseCompleted].contains(recovery.phase)
    else {
      store.setPublishActionMessage(
        CoreL10n.text("当前恢复记录不允许自动重放 stash。"),
        status: .warning
      )
      return false
    }
    guard let operation = beginRepositorySafeSyncOperation(store: store) else { return false }
    defer { finishRepositorySafeSyncOperation(operation, store: store) }
    await cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)

    let repositoryService = repositoryService
    let lifecycle = await Task.detached(priority: .userInitiated) {
      repositoryService.operationLifecycle(profile: profile)
    }.value
    guard lifecycle.kind == .none else {
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        CoreL10n.text("请先在软件内完成或放弃当前 Merge/Rebase，再恢复封存的本地改动。"),
        status: .warning
      )
      return false
    }

    let rebaseSyncService = makeRepositoryRebaseSyncService(
      profile: profile,
      store: store
    )
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try rebaseSyncService.restoreAfterRebase(profile: profile, recovery: recovery)
      }.value
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
      do {
        try clearRepositoryRebaseRecovery(profile: profile, store: store)
      } catch {
        repositoryRebaseRecoveryDiagnostic = error.localizedDescription
        await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
        store.setPublishActionMessage(
          CoreL10n.format(
            "本地改动已恢复，但恢复记录清理失败：%@",
            error.localizedDescription
          ),
          status: .warning
        )
        return true
      }
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      store.setPublishActionMessage(
        result.stashWasRetained
          ? CoreL10n.text("已恢复封存的本地改动；原 stash 作为备份保留。")
          : CoreL10n.text("已按精确 stash 恢复变基前的本地改动。"),
        status: result.stashWasRetained ? .warning : .success
      )
      return true
    } catch {
      guard repositorySafeSyncOperationIsCurrent(operation, store: store) else { return false }
      let recoverySaveError = recordRecoveryContext(
        from: error,
        profile: profile,
        store: store
      )
      await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
      presentRepositoryOperationFailure(error, recoverySaveError: recoverySaveError, store: store)
      return false
    }
  }

  private func restoreRebaseWIPIfNeeded(
    profile: SiteProfile,
    store: WorkbenchStore,
    afterAbort: Bool = false
  ) async throws {
    guard let recovery = repositoryRebaseRecoveryContext(for: profile) else { return }
    guard [.stashedBeforeRebase, .rebaseConflict, .rebaseCompleted].contains(recovery.phase)
    else {
      throw RepositoryRebaseSyncError.invalidRecoveryContext(
        "当前恢复阶段不允许自动应用 stash。"
      )
    }
    if afterAbort, recovery.phase == .rebaseCompleted {
      throw RepositoryRebaseSyncError.invalidRecoveryContext(
        "变基已完成的恢复记录不能用于放弃变基。"
      )
    }
    let readyRecovery = afterAbort || recovery.phase == .rebaseCompleted
      ? recovery
      : recovery.changingPhase(to: .rebaseCompleted)
    try saveRepositoryRebaseRecovery(readyRecovery, profile: profile, store: store)
    let rebaseSyncService = makeRepositoryRebaseSyncService(
      profile: profile,
      store: store
    )
    do {
      _ = try await Task.detached(priority: .userInitiated) {
        try rebaseSyncService.restoreAfterRebase(
          profile: profile,
          recovery: readyRecovery
        )
      }.value
      try clearRepositoryRebaseRecovery(profile: profile, store: store)
    } catch {
      _ = recordRecoveryContext(from: error, profile: profile, store: store)
      throw error
    }
  }

  @discardableResult
  func recordRecoveryContext(
    from error: Error,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> Error? {
    let context: RepositoryRebaseRecoveryContext?
    switch error as? RepositoryRebaseSyncError {
    case .rebaseConflict(let recovery, _):
      context = recovery
    case .stashRestoreConflict(let recovery, _):
      context = recovery
    case .partial(let recovery, _):
      context = recovery
    default:
      context = nil
    }
    guard let context else { return nil }
    do {
      try saveRepositoryRebaseRecovery(context, profile: profile, store: store)
      return nil
    } catch {
      repositoryRebaseRecoveryContext = context
      repositoryRebaseRecoveryProfileID = profile.id
      repositoryRebaseRecoveryDiagnostic = error.localizedDescription
      return error
    }
  }

  func saveRepositoryRebaseRecovery(
    _ context: RepositoryRebaseRecoveryContext,
    profile: SiteProfile,
    store: WorkbenchStore
  ) throws {
    try RepositoryRebaseRecoveryStore(
      recoveryArchiveDirectoryURL: store.persistenceStore.persistence.recoveryArchiveDirectoryURL
    ).save(context, profileID: profile.id)
    repositoryRebaseRecoveryContext = context
    repositoryRebaseRecoveryProfileID = profile.id
    repositoryRebaseRecoveryDiagnostic = nil
  }

  func clearRepositoryRebaseRecovery(
    profile: SiteProfile,
    store: WorkbenchStore
  ) throws {
    try RepositoryRebaseRecoveryStore(
      recoveryArchiveDirectoryURL: store.persistenceStore.persistence.recoveryArchiveDirectoryURL
    ).remove(profileID: profile.id)
    repositoryRebaseRecoveryContext = nil
    repositoryRebaseRecoveryProfileID = nil
    repositoryRebaseRecoveryDiagnostic = nil
  }

  private func presentRepositoryOperationFailure(
    _ error: Error,
    recoverySaveError: Error?,
    store: WorkbenchStore
  ) {
    var message = error.localizedDescription
    if let recoverySaveError {
      message += CoreL10n.format(
        " 恢复记录未能持久化：%@",
        recoverySaveError.localizedDescription
      )
    }
    store.setPublishActionMessage(message, status: .warning)
  }
}
