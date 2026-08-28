import Foundation
import PublishingGitCore

extension PublishingStore {
  @discardableResult
  public func resolveRemoteRepositoryConflict(
    repositoryPath: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    mergedDocument: String? = nil,
    store: WorkbenchStore
  ) async -> RemoteRepositoryConflictResolutionOutcome {
    let path = repositoryPath.normalizedRelativePath()
    guard let reviewedSession = remoteRepositoryConflictSession,
      reviewedSession.profileID == store.activeProfileID,
      reviewedSession.repositoryIdentity == DraftRepositoryIdentity(profile: store.activeProfile),
      let reviewedItem = reviewedSession.conflicts.first(where: { $0.repositoryPath == path })
    else {
      let message = CoreL10n.text("远端冲突快照已失效，请重新发布以刷新冲突。")
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }

    store.flushDraftBodyEditorBuffers()
    await store.refreshBatchPublishPlanAsync()
    guard let plan = batchPublishPlan,
      let package = remotePublishPackage(
        for: plan,
        cleanupRequests: pendingRemoteRepositoryCleanupRequests(profileID: plan.profileID)
      ),
      remoteRepositoryPublishService.conflictPackageFingerprint(
        package: package,
        profile: store.activeProfile
      ) == reviewedSession.packageFingerprint
    else {
      remoteRepositoryConflictSession = nil
      let message = CoreL10n.text("发布包已变化，已停止冲突处理；请重新审阅发布清单。")
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }

    let profile = store.activeProfile
    do {
      let token = try repositoryAccessToken(for: profile)
      let inspection = try await remoteRepositoryPublishService.preflightInspection(
        package: package,
        profile: profile,
        token: token
      )
      let currentSession = try await remoteRepositoryPublishService.conflictResolutionSession(
        inspection: inspection,
        profile: profile,
        token: token
      )
      guard
        let currentItem = currentSession.conflicts.first(where: {
          $0.repositoryPath == path
        }),
        currentItem.expectedSHA == reviewedItem.expectedSHA,
        currentItem.actualSHA == reviewedItem.actualSHA,
        currentItem.local == reviewedItem.local
      else {
        remoteRepositoryConflictSession = currentSession.isEmpty ? nil : currentSession
        let message =
          currentSession.isEmpty
          ? CoreL10n.text("远端内容已变化且当前冲突不再存在，请重新审阅发布清单。")
          : CoreL10n.text("远端内容在冲突处理期间发生变化，已刷新三方对比；未执行写入。")
        setPublishActionMessage(message, status: .warning)
        return currentSession.isEmpty
          ? .sessionInvalidated(message: message)
          : .sessionRefreshed(message: message)
      }

      switch choice {
      case .keepLocal:
        if await publishBatchThroughReviewRequest(store: store) != nil {
          return .completed(
            message: CoreL10n.text("PR/MR 已准备，等待合并后进入部署。")
          )
        }
        let message =
          publishActionFeedback?.message
          ?? CoreL10n.text("发布或部署检查失败，需要处理后重试。")
        remoteRepositoryConflictSession = reviewedSession
        return .failed(message: message)

      case .useRemote:
        guard currentItem.canUseRemoteText,
          let remoteDocument = currentItem.remote.text,
          let actualSHA = currentItem.actualSHA,
          applyRemoteConflictDocument(
            remoteDocument,
            remoteDocument: remoteDocument,
            actualSHA: actualSHA,
            repositoryPath: path,
            plan: plan,
            profile: profile,
            store: store
          )
        else {
          let message = CoreL10n.text("该远端版本不能安全导入为 Markdown，未修改草稿。")
          setPublishActionMessage(message, status: .warning)
          return .failed(message: message)
        }
        remoteRepositoryConflictSession = nil
        await store.refreshBatchPublishPlanAsync()
        let message = CoreL10n.format("已采用远端版本：%@；没有写入远端。", path)
        setPublishActionMessage(message, status: .success)
        store.save()
        return .completed(message: message)

      case .merge:
        guard currentItem.canMergeText,
          let remoteDocument = currentItem.remote.text,
          let actualSHA = currentItem.actualSHA,
          let mergedDocument,
          isSafeRemoteConflictFinalDocument(mergedDocument),
          applyRemoteConflictDocument(
            mergedDocument,
            remoteDocument: remoteDocument,
            actualSHA: actualSHA,
            repositoryPath: path,
            plan: plan,
            profile: profile,
            store: store
          )
        else {
          let message = CoreL10n.text("最终合并版无效、过大或仍含 Git 冲突标记，未修改草稿。")
          setPublishActionMessage(message, status: .warning)
          return .failed(message: message)
        }
        remoteRepositoryConflictSession = nil
        if await publishBatchThroughReviewRequest(store: store) != nil {
          return .completed(
            message: CoreL10n.text("PR/MR 已准备，等待合并后进入部署。")
          )
        }
        let message =
          publishActionFeedback?.message
          ?? CoreL10n.text("发布或部署检查失败，需要处理后重试。")
        return .sessionInvalidated(message: message)
      }
    } catch {
      let message = CoreL10n.format("刷新远端冲突失败：%@", error.localizedDescription)
      setPublishActionMessage(message, status: .failure)
      return .failed(message: message)
    }
  }

  private func publishBatchThroughReviewRequest(
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    await store.refreshBatchPublishPlanAsync()
    guard let plan = batchPublishPlan,
      let package = remotePublishPackage(
        for: plan,
        cleanupRequests: pendingRemoteRepositoryCleanupRequests(profileID: plan.profileID)
      )
    else {
      setPublishActionMessage(CoreL10n.text("没有可创建 PR/MR 的发布包。"), status: .warning)
      return nil
    }
    let profile = store.activeProfile
    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
      store: store
    )
    return await publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      store: store,
      expectedChangedPaths: Set(preview.changedPaths),
      expectedTarget: RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview),
      modeOverride: .reviewRequest
    )
  }

  private func applyRemoteConflictDocument(
    _ document: String,
    remoteDocument: String,
    actualSHA: String,
    repositoryPath: String,
    plan: BatchPublishPlan,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> Bool {
    guard
      let item = plan.remotePublishableItems.first(where: {
        $0.package.markdownPath.normalizedRelativePath() == repositoryPath
      }),
      let baseline = store.draftOperationBaseline(for: item.draftID)
    else { return false }

    let imported = localContentImportService.importDraft(
      document: document,
      repositoryPath: repositoryPath,
      profile: profile,
      repositorySHA: actualSHA
    )
    guard var resolvedDraft = imported.importedDrafts.first else { return false }
    let localDocument =
      publishPackageBuilder.build(draft: resolvedDraft, profile: profile)
      .markdownFile?.content ?? document
    resolvedDraft.adoptReviewedRemoteBaseline(
      profile: profile,
      repositoryPath: repositoryPath,
      remoteRevision: actualSHA,
      remoteDocument: remoteDocument,
      localDocument: localDocument
    )
    let result = LocalContentImportResult(
      importedDrafts: [resolvedDraft],
      skippedPaths: imported.skippedPaths,
      issues: imported.issues
    )
    let summary = mergeImportedDrafts(
      result,
      expectedBaselinesByRepositoryPath: [repositoryPath: baseline],
      store: store
    )
    guard summary.updatedCount == 1,
      let updated = drafts.first(where: { $0.id == item.draftID })
    else { return false }
    store.synchronizeDraftBodyEditorBuffer(with: updated)
    selectedDraftID = updated.id
    selectedSection = .writing
    return true
  }

  private func isSafeRemoteConflictFinalDocument(_ document: String) -> Bool {
    guard document.utf8.count <= RepositoryMergeConflictPolicy.maximumFinalByteCount else {
      return false
    }
    return !document.components(separatedBy: "\n").contains { line in
      line.hasPrefix("<<<<<<<")
        || line.hasPrefix("|||||||")
        || line.hasPrefix("=======")
        || line.hasPrefix(">>>>>>>")
    }
  }
}
