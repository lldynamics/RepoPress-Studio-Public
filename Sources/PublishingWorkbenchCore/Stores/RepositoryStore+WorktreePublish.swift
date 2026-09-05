import Foundation

private struct RepositoryWorktreeDraftFlushCandidate: Sendable {
  let repositoryPath: String
  let repositoryRootURL: URL
  let storedProjectDigest: String?
  let currentDraftDigest: String
}

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
    guard await prepareActiveDraftFilesForWorktreeReview(store: store, profile: profile) else {
      return nil
    }
    guard !Task.isCancelled, store.activeProfileID == profile.id else {
      store.setPublishActionMessage(
        CoreL10n.text("站点已切换，请重新审阅全部文件。"),
        status: .warning
      )
      return nil
    }
    let service = RepositoryWorktreePublishService()
    let articleDraft = store.selectedDraft
    store.setPublishActionMessage(
      CoreL10n.text("正在核对仓库全部待提交文件与远端分支…"),
      status: .inProgress
    )
    do {
      let confirmation = try await Task.detached(priority: .userInitiated) {
        try service.prepare(profile: profile, commitMessage: commitMessage, articleDraft: articleDraft)
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
    guard activeDraftFilesAreStable(store: store, profileID: profile.id) else {
      store.setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }
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
      store.recordConfirmedWorktreePush(result, profile: profile, article: confirmation.articleVerificationTarget)
      store.setPublishActionMessage(
        CoreL10n.format(
          "Git 推送已确认：仓库全部 %@ 个文件变更已到达 %@（提交 %@）。本次只确认仓库推送，网站部署与线上页面仍需另行验证。",
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

  /// Flushes only the active site's dirty editor buffers before the frozen Git
  /// review is built. If the corresponding project file changed outside the
  /// app, the external bytes win and the publish stops instead of overwriting
  /// them with a delayed editor autosave.
  private func prepareActiveDraftFilesForWorktreeReview(
    store: WorkbenchStore,
    profile: SiteProfile
  ) async -> Bool {
    await store.waitForPendingSiteDraftFileWrites()
    guard !Task.isCancelled, store.activeProfileID == profile.id else { return false }

    let dirtyDraftIDs = Set<UUID>(
      store.publishingStore.draftBodyEditorBuffers.values.compactMap { buffer in
        guard buffer.isDirty,
          let draft = store.drafts.first(where: { $0.id == buffer.draftID }),
          draft.belongs(toSiteProfileID: profile.id)
        else {
          return nil
        }
        return buffer.draftID
      }
    )

    if !dirtyDraftIDs.isEmpty {
      guard let repositoryRootURL = profile.localRepositoryRootURL else {
        store.setPublishActionMessage(
          CoreL10n.text("未选择本地仓库。"),
          status: .failure
        )
        return false
      }
      let candidates = store.drafts.compactMap { draft -> RepositoryWorktreeDraftFlushCandidate? in
        guard dirtyDraftIDs.contains(draft.id),
          let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
        else {
          return nil
        }
        return RepositoryWorktreeDraftFlushCandidate(
          repositoryPath: repositoryPath,
          repositoryRootURL: repositoryRootURL,
          storedProjectDigest: draft.repositoryBinding?.projectFileContentDigest,
          currentDraftDigest: draft.renderedRepositoryContentDigest(profile: profile)
        )
      }
      let externallyChangedPaths = await Task.detached(priority: .userInitiated) {
        candidates.compactMap(Self.externallyChangedPath)
      }.value.sorted()
      guard !Task.isCancelled, store.activeProfileID == profile.id else { return false }
      guard externallyChangedPaths.isEmpty else {
        store.setPublishActionMessage(
          CoreL10n.format(
            "检测到外部修改，已停止自动恢复并保留当前文件：%@",
            externallyChangedPaths.joined(separator: "、")
          ),
          status: .warning
        )
        return false
      }

      for draftID in dirtyDraftIDs {
        store.flushDraftBodyEditorBuffer(for: draftID)
      }
      await store.waitForPendingSiteDraftFileWrites()
    }

    guard !Task.isCancelled,
      store.activeProfileID == profile.id,
      activeDraftFilesAreStable(store: store, profileID: profile.id)
    else {
      store.setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return false
    }
    return true
  }

  private nonisolated static func externallyChangedPath(
    _ candidate: RepositoryWorktreeDraftFlushCandidate
  ) -> String? {
    do {
      let contents = try BoundedFileReader.utf8String(
        relativePath: candidate.repositoryPath,
        under: candidate.repositoryRootURL,
        maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
      )
      let diskDigest = ArticleDraft.repositoryDocumentDigest(contents)
      let expectedDigest = candidate.storedProjectDigest ?? candidate.currentDraftDigest
      return diskDigest == expectedDigest ? nil : candidate.repositoryPath
    } catch {
      return candidate.repositoryPath
    }
  }

  private func activeDraftFilesAreStable(
    store: WorkbenchStore,
    profileID: UUID
  ) -> Bool {
    let activeDraftIDs = Set(
      store.drafts.filter { $0.belongs(toSiteProfileID: profileID) }.map(\.id)
    )
    guard !store.publishingStore.draftBodyEditorBuffers.values.contains(where: {
      activeDraftIDs.contains($0.draftID) && $0.isDirty
    }),
      store.siteDraftFileAutosaveTasks.keys.allSatisfy({ !activeDraftIDs.contains($0) }),
      store.siteDraftFileWritesInProgress.isDisjoint(with: activeDraftIDs)
    else {
      return false
    }
    return !store.siteDraftFileSaveStates.contains { draftID, state in
      guard activeDraftIDs.contains(draftID) else { return false }
      switch state {
      case .pending, .failed:
        return true
      case .saved:
        return false
      }
    }
  }
}
