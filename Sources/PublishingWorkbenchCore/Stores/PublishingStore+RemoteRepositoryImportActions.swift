import Foundation

extension PublishingStore {

  func importRemoteArticleDraftsFromRepositoryOperation(
    repositoryPaths: [String],
    expectedTarget: SiteOperationConfirmationTarget,
    store: WorkbenchStore
  ) async -> LocalContentImportOperationResult {
    guard !Task.isCancelled, expectedTarget.matches(store.activeProfile) else {
      setPublishActionMessage(CoreL10n.text("站点或仓库配置已变化，请重新预览远端文章导入。"), status: .warning)
      return .empty(outcome: .cancelled)
    }
    store.flushDraftBodyEditorBuffers()
    let profile = expectedTarget.profile
    var seenPaths = Set<String>()
    let paths =
      repositoryPaths
      .map { $0.normalizedRelativePath() }
      .filter { path in
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      }
      .filter { seenPaths.insert($0).inserted }
    let snapshots = await store.repositoryStore.remoteFileSnapshotsAsync(
      profile: profile,
      repositoryPaths: paths
    )
    guard !Task.isCancelled else {
      setPublishActionMessage("已取消导入远端文章。", status: .warning)
      return .empty(outcome: .cancelled)
    }
    guard expectedTarget.matches(store.activeProfile) else {
      setPublishActionMessage(CoreL10n.text("站点或仓库配置已变化，请重新预览远端文章导入。"), status: .warning)
      return .empty(outcome: .cancelled)
    }
    guard let result = await remoteContentImportResultAsync(
      paths: paths,
      snapshots: snapshots,
      profile: profile
    ) else {
      setPublishActionMessage("已取消导入远端文章。", status: .warning)
      return .empty(outcome: .cancelled)
    }
    guard expectedTarget.matches(store.activeProfile) else {
      setPublishActionMessage(CoreL10n.text("站点或仓库配置已变化，请重新预览远端文章导入。"), status: .warning)
      return .empty(outcome: .cancelled)
    }
    let mergedOperation = mergeImportedDraftsOperation(result, store: store)
    let mergedSummary = mergedOperation.summary
    let summary = LocalContentImportMergeSummary(
      insertedCount: mergedSummary.insertedCount,
      updatedCount: mergedSummary.updatedCount,
      skippedCount: mergedSummary.skippedCount + result.skippedPaths.count
    )
    selectedSection = .writing
    if let firstPath = paths.first,
      let imported = drafts.first(where: {
        $0.belongs(toSiteProfileID: profile.id)
          && $0.repositoryPath == firstPath.normalizedRelativePath()
      })
    {
      selectedDraftID = imported.id
    }
    if result.skippedPaths.isEmpty, result.issues.isEmpty {
      setPublishActionMessage(
        "已从远端文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。",
        status: .success
      )
    } else {
      let detail = result.issues.first?.message ?? "路径或内容未通过导入校验"
      setPublishActionMessage(
        "远端文章导入未全部完成：新增 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇；跳过 \(result.skippedPaths.count) 个候选文件。\(detail)",
        status: summary.changedCount == 0 ? .failure : .warning
      )
    }
    store.save()
    let outcome: WorkbenchOperationLogOutcome
    if !result.skippedPaths.isEmpty || !result.issues.isEmpty {
      outcome = summary.changedCount == 0 ? .failed : .partial
    } else {
      outcome = mergedOperation.outcome
    }
    return LocalContentImportOperationResult(summary: summary, outcome: outcome)
  }

  /// Imports only remote article changes that can be proven safe. New paths are
  /// accepted, while an existing draft is replaced only when its repository
  /// content still matches the fingerprint recorded by the last import.
  @discardableResult
  public func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    store: WorkbenchStore
  ) -> RemoteArticleAutoImportSummary {
    let profile = store.activeProfile
    let snapshotsByPath = Dictionary(
      snapshots.map { ($0.repositoryPath.normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    var summary = RemoteArticleAutoImportSummary()
    var seenPaths = Set<String>()
    var didMutateDrafts = false

    for file in remoteFiles {
      let path = file.displayPath.normalizedRelativePath()
      guard seenPaths.insert(path).inserted,
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      else {
        continue
      }

      if file.kind == .deleted {
        if confirmExpectedRemoteRepositoryDeletion(
          profileID: profile.id,
          repositoryPath: path
        ) {
          summary.resolvedPaths.append(path)
          didMutateDrafts = true
        } else {
          summary.deletionPaths.append(path)
        }
        continue
      }
      guard file.kind == .added || file.kind == .modified else {
        summary.conflictPaths.append(path)
        continue
      }
      guard !locallyChangedPaths.contains(path) else {
        summary.conflictPaths.append(path)
        continue
      }
      guard let snapshot = snapshotsByPath[path] else {
        summary.failedPaths.append(path)
        continue
      }

      let importResult = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: path,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      guard var remoteDraft = importResult.importedDrafts.first else {
        summary.failedPaths.append(path)
        continue
      }
      let remoteFingerprint = remoteDraft.repositoryContentFingerprint
      let remoteRenderedDigest = remoteDraft.renderedRepositoryContentDigest(profile: profile)
      remoteDraft.repositoryImportFingerprint = remoteFingerprint

      guard
        let existingIndex = drafts.firstIndex(where: {
          $0.belongs(toSiteProfileID: profile.id)
            && $0.repositoryPath?.normalizedRelativePath() == path
        })
      else {
        drafts.append(remoteDraft)
        summary.insertedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = true
        continue
      }

      let existing = drafts[existingIndex]
      let editorBuffer = store.draftBodyEditorBuffer(for: existing.id)
      guard !editorBuffer.isDirty else {
        summary.conflictPaths.append(path)
        continue
      }

      // A site-draft autosave is the first durable signal that the app owns
      // this path locally. Until that write succeeds (or if it failed), the
      // repository scan cannot safely use Git's working-tree status or the
      // content fingerprint to prove that replacing the draft is harmless.
      // Fail closed and leave the path queued for manual review.
      if let saveState = store.siteDraftFileSaveStates[existing.id] {
        switch saveState {
        case .pending, .failed:
          summary.conflictPaths.append(path)
          continue
        case .saved:
          break
        }
      }

      let existingFingerprint = existing.repositoryContentFingerprint
      let existingRenderedDigest = existing.renderedRepositoryContentDigest(profile: profile)
      let normalizedRemoteSHA = snapshot.repositorySHA?.trimmedForPublishing.nilIfEmpty
      if let normalizedRemoteSHA,
        existing.repositorySHA?.trimmedForPublishing == normalizedRemoteSHA
      {
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        continue
      }

      if existingRenderedDigest == remoteRenderedDigest {
        var confirmed = existing
        if let normalizedRemoteSHA {
          confirmed.confirmRepositoryBinding(
            profile: profile,
            repositoryPath: path,
            remoteRevision: normalizedRemoteSHA,
            renderedContentDigest: confirmed.renderedRepositoryContentDigest(profile: profile)
          )
        } else {
          confirmed.repositoryImportFingerprint = remoteFingerprint
        }
        confirmed.markUpdated(at: existing.updatedAt, replacing: existing)
        drafts[existingIndex] = confirmed
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = didMutateDrafts || confirmed != existing
        continue
      }

      let localStillMatchesBaseline =
        existing.repositoryBinding?.renderedContentDigest == existingRenderedDigest
        || existing.repositoryImportFingerprint == existingFingerprint
      guard localStillMatchesBaseline else {
        var diverged = existing
        diverged.markRepositorySyncState(.diverged)
        diverged.markUpdated(at: existing.updatedAt, replacing: existing)
        drafts[existingIndex] = diverged
        didMutateDrafts = didMutateDrafts || diverged != existing
        summary.conflictPaths.append(path)
        continue
      }

      remoteDraft.id = existing.id
      remoteDraft.createdAt = existing.createdAt
      remoteDraft.translationLink = existing.translationLink
      recordAutomaticVersionIfNeeded(for: existing)
      // Remote imports replace front matter and body together. Advance the
      // list/editor metadata clocks rather than only the content timestamp.
      remoteDraft.markUpdated(replacing: existing)
      drafts[existingIndex] = remoteDraft
      store.synchronizeDraftBodyEditorBuffer(with: remoteDraft)
      summary.updatedCount += 1
      summary.resolvedPaths.append(path)
      didMutateDrafts = true
    }

    if didMutateDrafts {
      if automaticallyRefreshPreflightOnEdit {
        store.schedulePreflightRefresh()
      }
      store.save()
    }
    return summary
  }

  /// Explicitly binds an automatic import to the frozen operation profile.
  /// The importer still requires that profile to be active because its draft
  /// mutation and editor-buffer safeguards are intentionally foreground-only.
  /// A background caller for another site therefore fails closed instead of
  /// importing into whichever site the user currently sees.
  @discardableResult
  public func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    profileID: UUID,
    store: WorkbenchStore
  ) -> RemoteArticleAutoImportSummary {
    guard profileID == store.activeProfileID else {
      return RemoteArticleAutoImportSummary()
    }
    return autoImportRemoteArticleDrafts(
      remoteFiles: remoteFiles,
      snapshots: snapshots,
      locallyChangedPaths: locallyChangedPaths,
      store: store
    )
  }

  private func remoteContentImportResultAsync(
    paths: [String],
    snapshots: [RepositoryFileSnapshot],
    profile: SiteProfile
  ) async -> LocalContentImportResult? {
    guard !Task.isCancelled else { return nil }
    let importService = localContentImportService
    let work = Task.detached(priority: .utility) {
      LocalRepositoryImportBackgroundWork.makeRemoteContentImportResult(
        paths: paths,
        snapshots: snapshots,
        profile: profile,
        importService: importService
      )
    }
    let result = await withTaskCancellationHandler(operation: {
      await work.value
    }, onCancel: {
      work.cancel()
    })
    guard !Task.isCancelled else { return nil }
    return result
  }
}
