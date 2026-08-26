import CryptoKit
import Foundation

extension PublishingStore {
  public func versions(for draftID: UUID) -> [DraftVersionSnapshot] {
    draftVersions
      .filter { $0.draftID == draftID }
      .sorted { $0.capturedAt > $1.capturedAt }
  }

  @discardableResult
  public func createManualVersion(for draftID: UUID, store: WorkbenchStore) -> Bool {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return false }
    let previousCount = draftVersions.count
    draftVersions = draftLifecycleService.recordingVersion(
      of: draft,
      reason: .manual,
      in: draftVersions
    )
    guard draftVersions.count != previousCount else {
      store.setPublishActionMessage(
        CoreL10n.text("当前内容与最新版本相同，无需重复保存。"),
        status: .warning
      )
      return false
    }
    store.setPublishActionMessage(
      CoreL10n.text("已保存手动版本快照。"),
      status: .success
    )
    store.save()
    return true
  }

  @discardableResult
  public func recordVersionsBeforeBatchProcessing(
    draftIDs: Set<UUID>,
    store: WorkbenchStore
  ) -> Int {
    let candidates = drafts.filter { draftIDs.contains($0.id) }
    var recordedCount = 0
    for draft in candidates {
      let previousCount = draftVersions.count
      draftVersions = draftLifecycleService.recordingVersion(
        of: draft,
        reason: .beforeBatchProcessing,
        in: draftVersions
      )
      if draftVersions.count > previousCount {
        recordedCount += 1
      }
    }
    if recordedCount > 0 {
      store.save()
    }
    return recordedCount
  }

  @discardableResult
  public func restoreDraftVersion(_ versionID: UUID, store: WorkbenchStore) -> Bool {
    guard let version = draftVersions.first(where: { $0.id == versionID }),
          let currentIndex = drafts.firstIndex(where: { $0.id == version.draftID })
    else {
      return false
    }

    let currentDraft = drafts[currentIndex]
    draftVersions = draftLifecycleService.recordingVersion(
      of: currentDraft,
      reason: .beforeRestore,
      in: draftVersions
    )
    var restored = DraftVersionComparisonService().restoringContent(
      from: version.draft,
      into: currentDraft
    )
    if restored.isGeneralDraft,
       !profiles.contains(where: { $0.id == restored.siteProfileID }) {
      restored.assignToGeneralDraft(editingProfileID: activeProfileID)
    }
    restored.markUpdated(replacing: currentDraft)
    drafts[currentIndex] = restored
    selectedDraftID = restored.id
    if restored.isGeneralDraft {
      draftListContentScope = .general
    } else {
      activeProfileID = restored.siteProfileID
      draftListContentScope = .currentSite
    }
    store.synchronizeDraftBodyEditorBuffer(with: restored)
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: restored)
    store.refreshPublishPreviewInBackground(for: restored)
    store.setPublishActionMessage(
      CoreL10n.format(
        "已恢复到 %@ 的版本。",
        version.capturedAt.formatted(date: .abbreviated, time: .shortened)
      ),
      status: .success
    )
    store.save()
    return true
  }

  @discardableResult
  public func restoreRecycledDraft(_ draftID: UUID, store: WorkbenchStore) -> Bool {
    guard !drafts.contains(where: { $0.id == draftID }),
          let recycledIndex = recycledDrafts.firstIndex(where: { $0.id == draftID })
    else {
      return false
    }
    let recycled = recycledDrafts[recycledIndex]
    if draftRepositoryCleanupRequests.contains(where: {
      $0.draftID == draftID && $0.isAwaitingRemoteReview
    }) {
      store.setPublishActionMessage(
        CoreL10n.text("这篇文章已有待合并的下线 PR/MR；请先关闭该 PR/MR，再恢复文章。"),
        status: .warning
      )
      return false
    }
    guard recycled.draft.isGeneralDraft
      || profiles.contains(where: { $0.id == recycled.draft.siteProfileID }) else {
      store.setPublishActionMessage(
        CoreL10n.text("原站点 Profile 已不存在，无法恢复这篇文章。"),
        status: .warning
      )
      return false
    }

    recycledDrafts.remove(at: recycledIndex)
    draftRepositoryCleanupRequests.removeAll {
      $0.draftID == draftID && $0.remoteStatus == .pending
    }
    for index in draftRepositoryCleanupRequests.indices where
      draftRepositoryCleanupRequests[index].draftID == draftID
        && draftRepositoryCleanupRequests[index].remoteStatus == .completed
        && draftRepositoryCleanupRequests[index].status == .pending
    {
      draftRepositoryCleanupRequests[index].status = .kept
      draftRepositoryCleanupRequests[index].resolvedAt = Date()
    }
    var restored = recycled.draft
    if restored.isGeneralDraft {
      restored.assignToGeneralDraft(editingProfileID: activeProfileID)
    }
    restored.markMetadataUpdated()
    drafts.insert(restored, at: 0)
    if restored.isGeneralDraft {
      draftListContentScope = .general
    } else {
      activeProfileID = restored.siteProfileID
      draftListContentScope = .currentSite
    }
    selectedDraftID = restored.id
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: restored)
    store.refreshPublishPreviewInBackground(for: restored)
    store.setPublishActionMessage(
      CoreL10n.format(
        "已从回收站恢复「%@」。",
        restored.title.nilIfEmpty ?? CoreL10n.text("未命名文章")
      ),
      status: .success
    )
    store.save()
    return true
  }

  @discardableResult
  public func permanentlyDeleteRecycledDraft(_ draftID: UUID, store: WorkbenchStore) -> Bool {
    guard recycledDrafts.contains(where: { $0.id == draftID }) else { return false }
    recycledDrafts.removeAll { $0.id == draftID }
    draftVersions.removeAll { $0.draftID == draftID }
    markdownEditorSessionStates.removeValue(forKey: draftID)
    store.setPublishActionMessage(
      CoreL10n.text("已永久删除回收站中的文章；待处理的仓库清理记录仍保留。"),
      status: .success
    )
    store.save()
    return true
  }

  public func pendingRepositoryCleanupRequests() -> [DraftRepositoryCleanupRequest] {
    draftRepositoryCleanupRequests
      .filter(\.needsAttention)
      .sorted { $0.requestedAt > $1.requestedAt }
  }

  public func pendingRemoteRepositoryCleanupRequests(
    profileID: UUID? = nil
  ) -> [DraftRepositoryCleanupRequest] {
    draftRepositoryCleanupRequests
      .filter { request in
        request.needsRemoteCleanup
          && profileID.map { request.siteProfileID == $0 } != false
      }
      .sorted { $0.requestedAt < $1.requestedAt }
  }

  public func repositoryCleanupPreview(for requestID: UUID) -> LocalPublishPreview? {
    guard let request = draftRepositoryCleanupRequests.first(where: { $0.id == requestID }),
          let profile = profiles.first(where: { $0.id == request.siteProfileID })
    else {
      return nil
    }
    return localPublishPreviewService.preview(
      package: draftLifecycleService.cleanupPackage(for: request),
      profile: profile
    )
  }

  @discardableResult
  public func performLocalRepositoryCleanup(
    _ requestID: UUID,
    preview providedPreview: LocalPublishPreview? = nil,
    store: WorkbenchStore
  ) -> Bool {
    guard let requestIndex = draftRepositoryCleanupRequests.firstIndex(where: {
      $0.id == requestID && $0.status == .pending
    }),
    let profile = profiles.first(where: { $0.id == draftRepositoryCleanupRequests[requestIndex].siteProfileID })
    else {
      return false
    }

    let request = draftRepositoryCleanupRequests[requestIndex]
    let package = draftLifecycleService.cleanupPackage(for: request)
    let preview = providedPreview ?? localPublishPreviewService.preview(package: package, profile: profile)
    guard !preview.issues.contains(where: { $0.severity == .error }) else {
      store.setPublishActionMessage(
        CoreL10n.text("本地仓库清理被阻止：请先检查仓库路径和安全性问题。"),
        status: .warning
      )
      return false
    }

    do {
      _ = try localPublishPreviewService.write(preview: preview, profile: profile)
      draftRepositoryCleanupRequests[requestIndex].status = .completed
      draftRepositoryCleanupRequests[requestIndex].resolvedAt = Date()
      store.setPublishActionMessage(
        draftRepositoryCleanupRequests[requestIndex].remoteStatus == .completed
          ? CoreL10n.format("已完成文章下线并清理本地文件：%@。", request.repositoryPath)
          : CoreL10n.format(
            "已从本地仓库清理 %@；远端下线仍在待处理队列。",
            request.repositoryPath
          ),
        status: .success
      )
      store.save()
      return true
    } catch {
      store.setPublishActionMessage(
        CoreL10n.format("本地仓库清理失败：%@", error.localizedDescription),
        status: .failure
      )
      return false
    }
  }

  @discardableResult
  public func keepRepositoryFile(_ requestID: UUID, store: WorkbenchStore) -> Bool {
    guard let index = draftRepositoryCleanupRequests.firstIndex(where: {
      $0.id == requestID && $0.status == .pending
    }) else {
      return false
    }
    draftRepositoryCleanupRequests[index].status = .kept
    draftRepositoryCleanupRequests[index].resolvedAt = Date()
    store.setPublishActionMessage(
      CoreL10n.text("已保留本地仓库文件；远端下线请求仍会继续处理。"),
      status: .success
    )
    store.save()
    return true
  }

  @discardableResult
  func recordRemoteRepositoryCleanupResult(
    requestIDs: Set<UUID>,
    result: RemoteRepositoryPublishResult,
    at resolvedAt: Date = Date()
  ) -> Int {
    let changedPaths = Set(result.changedPaths.map { $0.normalizedRelativePath() })
    // Newer services identify review-backed deletion paths explicitly. A
    // missing value is an old result snapshot, so retain the legacy fallback
    // of treating only changed paths as review-pending.
    let explicitReviewPendingPaths = result.reviewPendingPaths.map {
      Set($0.map { $0.normalizedRelativePath() })
    }
    var updatedCount = 0
    for index in draftRepositoryCleanupRequests.indices {
      guard requestIDs.contains(draftRepositoryCleanupRequests[index].id) else { continue }
      let path = draftRepositoryCleanupRequests[index].repositoryPath.normalizedRelativePath()
      let isReviewPendingPath: Bool
      if let explicitReviewPendingPaths {
        isReviewPendingPath = explicitReviewPendingPaths.contains(path)
      } else {
        isReviewPendingPath = changedPaths.contains(path)
      }
      if result.mode == .reviewRequest, isReviewPendingPath {
        draftRepositoryCleanupRequests[index].remoteStatus = .reviewRequested
        draftRepositoryCleanupRequests[index].remoteReviewURL = result.reviewURL
        draftRepositoryCleanupRequests[index].remoteResolvedAt = nil
      } else {
        // A delete package that completed without changing this path proved
        // that it was already absent. Treat that retry as idempotent success.
        draftRepositoryCleanupRequests[index].remoteStatus = .completed
        draftRepositoryCleanupRequests[index].remoteResolvedAt = resolvedAt
        draftRepositoryCleanupRequests[index].remoteReviewURL = nil
      }
      draftRepositoryCleanupRequests[index].lastRemoteErrorMessage = nil
      updatedCount += 1
    }
    return updatedCount
  }

  @discardableResult
  func recordRemoteRepositoryCleanupFailure(
    requestIDs: Set<UUID>,
    message: String
  ) -> Int {
    var updatedCount = 0
    for index in draftRepositoryCleanupRequests.indices where
      requestIDs.contains(draftRepositoryCleanupRequests[index].id)
        && draftRepositoryCleanupRequests[index].remoteStatus == .pending
    {
      draftRepositoryCleanupRequests[index].lastRemoteErrorMessage = message
      updatedCount += 1
    }
    return updatedCount
  }

  @discardableResult
  func confirmExpectedRemoteRepositoryDeletion(
    profileID: UUID,
    repositoryPath: String,
    at resolvedAt: Date = Date()
  ) -> Bool {
    let path = repositoryPath.normalizedRelativePath()
    var didResolve = false
    for index in draftRepositoryCleanupRequests.indices where
      draftRepositoryCleanupRequests[index].siteProfileID == profileID
        && draftRepositoryCleanupRequests[index].repositoryPath.normalizedRelativePath() == path
        && draftRepositoryCleanupRequests[index].remoteStatus != .completed
    {
      draftRepositoryCleanupRequests[index].remoteStatus = .completed
      draftRepositoryCleanupRequests[index].remoteResolvedAt = resolvedAt
      draftRepositoryCleanupRequests[index].remoteReviewURL = nil
      draftRepositoryCleanupRequests[index].lastRemoteErrorMessage = nil
      didResolve = true
    }
    return didResolve
  }

  @discardableResult
  func restoreRemoteCleanupRequestsAfterReviewWithdrawal(
    reviewURLs: Set<String>,
    profileID: UUID
  ) -> Int {
    let normalizedReviewURLs = Set(
      reviewURLs.compactMap { $0.trimmedForPublishing.nilIfEmpty }
    )
    guard !normalizedReviewURLs.isEmpty else { return 0 }

    var restoredCount = 0
    for index in draftRepositoryCleanupRequests.indices where
      draftRepositoryCleanupRequests[index].siteProfileID == profileID
        && draftRepositoryCleanupRequests[index].remoteStatus == .reviewRequested
        && draftRepositoryCleanupRequests[index].remoteReviewURL
          .flatMap({ $0.trimmedForPublishing.nilIfEmpty })
          .map(normalizedReviewURLs.contains) == true
    {
      draftRepositoryCleanupRequests[index].remoteStatus = .pending
      draftRepositoryCleanupRequests[index].remoteResolvedAt = nil
      draftRepositoryCleanupRequests[index].remoteReviewURL = nil
      draftRepositoryCleanupRequests[index].lastRemoteErrorMessage = nil
      restoredCount += 1
    }
    return restoredCount
  }

  @discardableResult
  public func acknowledgeRemoteCleanupReviewClosed(
    requestID: UUID,
    store: WorkbenchStore
  ) -> Bool {
    guard let index = draftRepositoryCleanupRequests.firstIndex(where: {
      $0.id == requestID && $0.remoteStatus == .reviewRequested
    }) else {
      return false
    }

    draftRepositoryCleanupRequests[index].remoteStatus = .pending
    draftRepositoryCleanupRequests[index].remoteResolvedAt = nil
    draftRepositoryCleanupRequests[index].remoteReviewURL = nil
    draftRepositoryCleanupRequests[index].lastRemoteErrorMessage = nil
    store.setPublishActionMessage(
      CoreL10n.text("已确认下线 PR/MR 已关闭；现在可以恢复文章或重新发起远端下线。"),
      status: .success
    )
    store.save()
    return true
  }

  func recordAutomaticVersionIfNeeded(for draft: ArticleDraft) {
    draftVersions = draftLifecycleService.recordingVersion(
      of: draft,
      reason: .automatic,
      in: draftVersions
    )
  }

  func moveDraftToRecycleBin(_ draft: ArticleDraft, store: WorkbenchStore) {
    let now = Date()
    draftVersions = draftLifecycleService.recordingVersion(
      of: draft,
      reason: .beforeDeletion,
      in: draftVersions,
      at: now
    )
    recycledDrafts = draftLifecycleService.recycling(
      draft,
      existing: recycledDrafts,
      at: now
    )
    draftRepositoryCleanupRequests = draftLifecycleService.cleanupRequest(
      for: draft,
      existing: draftRepositoryCleanupRequests,
      at: now
    )
    guard let requestIndex = draftRepositoryCleanupRequests.firstIndex(where: {
      $0.draftID == draft.id && $0.needsAttention
    }) else {
      return
    }
    let request = draftRepositoryCleanupRequests[requestIndex]
    if request.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty == nil,
       let snapshotSHA = store.repositoryStore.remoteFileSnapshot(
         profile: store.profile(for: draft),
         repositoryPath: request.repositoryPath
       )?.repositorySHA?.trimmedForPublishing.nilIfEmpty {
      draftRepositoryCleanupRequests[requestIndex].expectedRemoteSHA = snapshotSHA
    }
    let profile = store.profile(for: draft)
    if let evidence = localPublishPreviewService.deletionEvidence(
      repositoryPath: request.repositoryPath,
      profile: profile
    ) {
      draftRepositoryCleanupRequests[requestIndex].expectedContentSHA256 = evidence.contentSHA256
      draftRepositoryCleanupRequests[requestIndex].expectedGitBlobSHA = evidence.gitBlobSHA
    } else if let generatedContent = publishPackageBuilder
      .build(draft: draft, profile: profile)
      .files
      .first(where: {
        $0.kind == .markdown
          && $0.repositoryPath.normalizedRelativePath()
            == request.repositoryPath.normalizedRelativePath()
      })?.content {
      let evidence = deletionEvidence(for: generatedContent)
      draftRepositoryCleanupRequests[requestIndex].expectedContentSHA256 = evidence.contentSHA256
      draftRepositoryCleanupRequests[requestIndex].expectedGitBlobSHA = evidence.gitBlobSHA
    }
  }

  private func deletionEvidence(for content: String) -> (contentSHA256: String, gitBlobSHA: String) {
    let data = Data(content.utf8)
    let contentSHA256 = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    var blob = Data("blob \(data.count)\0".utf8)
    blob.append(data)
    let gitBlobSHA = Insecure.SHA1.hash(data: blob)
      .map { String(format: "%02x", $0) }
      .joined()
    return (contentSHA256: contentSHA256, gitBlobSHA: gitBlobSHA)
  }
}
