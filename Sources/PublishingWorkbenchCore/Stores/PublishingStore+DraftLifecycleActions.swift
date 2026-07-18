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
      store.setPublishActionMessage(CoreL10n.text("当前内容与最新版本相同，无需重复保存。"))
      return false
    }
    store.setPublishActionMessage(CoreL10n.text("已保存手动版本快照。"))
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
      )
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
    guard recycled.draft.isGeneralDraft
      || profiles.contains(where: { $0.id == recycled.draft.siteProfileID }) else {
      store.setPublishActionMessage(CoreL10n.text("原站点 Profile 已不存在，无法恢复这篇文章。"))
      return false
    }

    recycledDrafts.remove(at: recycledIndex)
    draftRepositoryCleanupRequests.removeAll {
      $0.draftID == draftID && $0.status == .pending
    }
    var restored = recycled.draft
    if restored.isGeneralDraft {
      restored.assignToGeneralDraft(editingProfileID: activeProfileID)
    }
    restored.updatedAt = Date()
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
      )
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
    store.setPublishActionMessage(CoreL10n.text("已永久删除回收站中的文章；待处理的仓库清理记录仍保留。"))
    store.save()
    return true
  }

  public func pendingRepositoryCleanupRequests() -> [DraftRepositoryCleanupRequest] {
    draftRepositoryCleanupRequests
      .filter { $0.status == .pending }
      .sorted { $0.requestedAt > $1.requestedAt }
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
      store.setPublishActionMessage(CoreL10n.text("本地仓库清理被阻止：请先检查仓库路径和安全性问题。"))
      return false
    }

    do {
      _ = try localPublishPreviewService.write(preview: preview, profile: profile)
      draftRepositoryCleanupRequests[requestIndex].status = .completed
      draftRepositoryCleanupRequests[requestIndex].resolvedAt = Date()
      store.setPublishActionMessage(
        CoreL10n.format(
          "已从本地仓库清理 %@；可在同步工作区检查并提交该删除。",
          request.repositoryPath
        )
      )
      store.save()
      return true
    } catch {
      store.setPublishActionMessage(CoreL10n.format("本地仓库清理失败：%@", error.localizedDescription))
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
    store.setPublishActionMessage(CoreL10n.text("已保留仓库文件，该记录不再等待清理。"))
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

  func moveDraftToRecycleBin(_ draft: ArticleDraft) {
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
  }
}
