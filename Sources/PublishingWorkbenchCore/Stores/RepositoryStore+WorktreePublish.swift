import Foundation

private struct RepositoryWorktreeDraftFlushCandidate: Sendable {
  let repositoryPath: String
  let repositoryRootURL: URL
  let storedProjectDigest: String?
  let currentDraftDigest: String
}

extension RepositoryStore {
  /// Builds a read-only, frozen review of every pending Git worktree change,
  /// or of only `pathScope` when one article is published on its own.
  /// The service performs its own remote and repository identity checks; this
  /// store boundary only coordinates protected-workbench and operation state.
  public func prepareRepositoryWorktreePublish(
    store: WorkbenchStore,
    commitMessage: String = "Publish all site changes",
    pathScope: [String]? = nil,
    articleDraftID: UUID? = nil
  ) async -> RepositoryWorktreePublishConfirmation? {
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
    let draftIDs = reviewDraftIDs(
      store: store, profileID: profile.id, pathScope: pathScope, articleDraftID: articleDraftID)
    guard
      await prepareActiveDraftFilesForWorktreeReview(
        store: store, profile: profile, draftIDs: draftIDs)
    else {
      return nil
    }
    guard !Task.isCancelled, store.activeProfileID == profile.id else {
      store.setGitActionMessage(
        CoreL10n.text("站点已切换，请重新审阅全部文件。"),
        status: .warning
      )
      return nil
    }
    let service = RepositoryWorktreePublishService()
    let articleDraft = articleDraftID.map { store.draft(for: $0) } ?? store.selectedDraft
    store.setGitActionMessage(
      pathScope == nil
        ? CoreL10n.text("正在核对仓库全部待提交文件与远端分支…")
        : CoreL10n.text("正在核对这篇文章的文件与远端分支…"),
      status: .inProgress
    )
    do {
      let confirmation = try await Task.detached(priority: .userInitiated) {
        try service.prepare(
          profile: profile, commitMessage: commitMessage, articleDraft: articleDraft,
          pathScope: pathScope)
      }.value
      guard store.activeProfileID == profile.id else {
        store.setGitActionMessage(
          CoreL10n.text("站点已切换，请重新审阅全部文件。"),
          status: .warning
        )
        return nil
      }
      store.setGitActionMessage(
        CoreL10n.format(
          "已冻结 %@ 个待推送文件，请确认完整清单。",
          String(confirmation.snapshot.entries.count)
        ),
        status: .information
      )
      return confirmation
    } catch RepositoryWorktreePublishError.noChanges where pathScope != nil {
      store.setGitActionMessage(
        CoreL10n.text("这篇文章没有需要发布的新变化，线上仓库已是最新内容。"),
        status: .information
      )
      return nil
    } catch {
      store.setGitActionMessage(error.localizedDescription, status: .failure)
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
    let draftIDs = reviewDraftIDs(
      store: store, profileID: profile.id, pathScope: confirmation.pathScope,
      articleDraftID: confirmation.articleVerificationTarget?.draftID)
    if let message = activeDraftFilesReadinessMessage(
      store: store, profileID: profile.id, draftIDs: draftIDs)
    {
      store.setGitActionMessage(
        message,
        status: .warning
      )
      return nil
    }
    let service = RepositoryWorktreePublishService()
    isRemoteRepositoryPublishing = true
    let recoveryStore = store.worktreePushRecoveryStore
    let trackingRequest =
      confirmation.isScoped ? ArticlePublishTrackingRequest(profile: profile) : nil
    store.setGitActionMessage(
      CoreL10n.format(
        "正在提交并推送 %@ 个已审阅文件…",
        String(confirmation.snapshot.entries.count)
      ),
      status: .inProgress
    )
    defer { isRemoteRepositoryPublishing = false }

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try service.publish(profile: profile, confirmation: confirmation) { commitSHA in
          try recoveryStore.save(
            RepositoryWorktreePushRecoveryRecord(
              profile: profile, confirmation: confirmation, commitSHA: commitSHA,
              trackingRequest: trackingRequest))
        }
      }.value
      store.recordConfirmedWorktreePush(
        result, profile: profile, article: confirmation.articleVerificationTarget,
        trackingRequest: trackingRequest)
      let recoverySaved = store.finishWorktreePushRecovery(
        RepositoryWorktreePushRecoveryRecord(
          profile: profile, confirmation: confirmation, commitSHA: result.commitSHA))
      let fileCount = String(confirmation.snapshot.entries.count)
      let shortSHA = String(result.commitSHA.prefix(8))
      store.setGitActionMessage(
        confirmation.isScoped
          ? CoreL10n.format(
            "Git 推送已确认：这篇文章的 %@ 个文件已到达 %@（提交 %@）。其他未发布的变更仍留在本地。",
            fileCount, result.branch, shortSHA)
          : CoreL10n.format(
            "Git 推送已确认：仓库全部 %@ 个文件变更已到达 %@（提交 %@）。本次只确认仓库推送，网站部署与线上页面仍需另行验证。",
            fileCount, result.branch, shortSHA),
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

  /// Flushes only the active site's dirty editor buffers before the frozen Git
  /// review is built. If the corresponding project file changed outside the
  /// app, the external bytes win and the publish stops instead of overwriting
  /// them with a delayed editor autosave.
  private func prepareActiveDraftFilesForWorktreeReview(
    store: WorkbenchStore,
    profile: SiteProfile,
    draftIDs: Set<UUID>?
  ) async -> Bool {
    await store.waitForPendingSiteDraftFileWrites(draftIDs: draftIDs)
    guard !Task.isCancelled, store.activeProfileID == profile.id else { return false }

    let dirtyDraftIDs = Set<UUID>(
      store.publishingStore.draftBodyEditorBuffers.values.compactMap { buffer in
        guard buffer.isDirty, draftIDs?.contains(buffer.draftID) ?? true,
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
        store.setGitActionMessage(
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
        store.setGitActionMessage(
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
      await store.waitForPendingSiteDraftFileWrites(draftIDs: draftIDs)
    }

    guard !Task.isCancelled, store.activeProfileID == profile.id else { return false }
    if let message = activeDraftFilesReadinessMessage(
      store: store, profileID: profile.id, draftIDs: draftIDs)
    {
      store.setGitActionMessage(message, status: .warning)
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

  private func activeDraftFilesReadinessMessage(
    store: WorkbenchStore,
    profileID: UUID,
    draftIDs: Set<UUID>?
  ) -> String? {
    let activeDraftIDs = Set(
      store.drafts.filter {
        $0.belongs(toSiteProfileID: profileID) && (draftIDs?.contains($0.id) ?? true)
      }.map(\.id)
    )
    let failures = store.siteDraftFileSaveStates.compactMap { draftID, state -> String? in
      guard activeDraftIDs.contains(draftID), case .failed(let path, let message) = state else {
        return nil
      }
      let title = store.draft(for: draftID)?.title ?? path
      return "\(title)（\(path)）：\(message)"
    }.sorted()
    if !failures.isEmpty {
      return CoreL10n.format(
        "以下文章未能写入本地仓库，已停止发布：%@", failures.joined(separator: "\n"))
    }
    let pendingPaths = store.siteDraftFileSaveStates.compactMap { draftID, state -> String? in
      guard activeDraftIDs.contains(draftID), case .pending(let path) = state else { return nil }
      return path
    }.sorted()
    if !pendingPaths.isEmpty {
      return CoreL10n.text("文章尚未保存成功，请先处理保存问题。") + "\n"
        + pendingPaths.joined(separator: "\n")
    }
    if store.publishingStore.draftBodyEditorBuffers.values.contains(where: {
      activeDraftIDs.contains($0.draftID) && $0.isDirty
    }) || !store.siteDraftFileAutosaveTasks.keys.allSatisfy({ !activeDraftIDs.contains($0) })
      || !store.siteDraftFileWritesInProgress.isDisjoint(with: activeDraftIDs)
    {
      return CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。")
    }
    return nil
  }

  /// Article save readiness follows the reviewed paths, while repository-wide
  /// branch, index and remote safety checks remain enforced by the Git service.
  private func reviewDraftIDs(
    store: WorkbenchStore, profileID: UUID, pathScope: [String]?, articleDraftID: UUID?
  ) -> Set<UUID>? {
    guard let pathScope else { return nil }
    let paths = Set(pathScope.map { $0.normalizedRelativePath() })
    var ids = Set(
      store.drafts.filter { draft in
        draft.belongs(toSiteProfileID: profileID)
          && draft.repositoryPath.map { paths.contains($0.normalizedRelativePath()) } == true
      }.map(\.id))
    if let articleDraftID { ids.insert(articleDraftID) }
    return ids
  }
}
