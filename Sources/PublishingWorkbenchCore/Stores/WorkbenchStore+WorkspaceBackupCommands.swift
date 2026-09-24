import Foundation
import PublishingKnowledgeCore

extension WorkbenchStore {
  public var canRestoreBackupArticles: Bool {
    canUseProtectedWorkbench && !isPersistenceRecoveryWriteProtected
  }

  public func workspaceBackupArticleSelectionPreview(from backupURL: URL) async throws
    -> WorkspaceBackupArticleSelectionPreview
  {
    guard canRestoreBackupArticles else { throw WorkspaceBackupArticleRestoreError.unavailable }
    let currentVersion = Self.workspaceBackupApplicationVersion
    let preview = try await runWorkspaceBackupIO {
      try WorkspaceBackupService().inspectArticlesForRestore(
        at: backupURL, currentApplicationVersion: currentVersion
      )
    }
    try Task.checkCancellation()
    guard canRestoreBackupArticles else { throw WorkspaceBackupArticleRestoreError.unavailable }
    return preview
  }

  @discardableResult
  public func restoreWorkspaceBackupArticles(
    preview: WorkspaceBackupArticleSelectionPreview,
    selectedDraftIDs: Set<UUID>
  ) async throws -> Int {
    guard canRestoreBackupArticles else { throw WorkspaceBackupArticleRestoreError.unavailable }
    let editingProfileID = activeProfileID
    let attachmentRootURL = managedAttachmentFileStore.rootDirectoryURL
    let prepared = try await runWorkspaceBackupIO {
      try WorkspaceBackupService().prepareArticleRestore(
        preview: preview,
        selectedDraftIDs: selectedDraftIDs,
        editingProfileID: editingProfileID,
        attachmentRootURL: attachmentRootURL
      )
    }
    let fileManager = FileManager.default
    var ownsDestination = false
    var committed = false
    var persistenceAttempted = false
    defer {
      // Only this operation's unique directories are eligible for cleanup.
      try? fileManager.removeItem(at: prepared.stagingURL)
      if ownsDestination && !committed && !persistenceAttempted {
        try? fileManager.removeItem(at: prepared.destinationURL)
      }
    }
    try Task.checkCancellation()
    guard canRestoreBackupArticles, profiles.contains(where: { $0.id == editingProfileID }) else {
      throw WorkspaceBackupArticleRestoreError.unavailable
    }
    try fileManager.createDirectory(at: attachmentRootURL, withIntermediateDirectories: true)
    try fileManager.moveItem(at: prepared.stagingURL, to: prepared.destinationURL)
    ownsDestination = true

    // No suspension between append, durable save and rollback: editor changes
    // made during preparation are retained. This does not write site files.
    flushDraftBodyEditorBuffers()
    let previousDrafts = drafts
    publishingStore.drafts.append(contentsOf: prepared.drafts)
    invalidateDraftDerivedCaches()
    persistenceStore.markUnsavedChanges()
    persistenceAttempted = true
    let persisted = persistenceStore.flush(
      input: persistenceStore.persistence.snapshotInput(from: self))
    guard persisted, !persistenceStore.isRecoveryWriteProtected else {
      publishingStore.drafts = previousDrafts
      invalidateDraftDerivedCaches()
      persistenceStore.markUnsavedChanges()
      // A save can throw after the SQLite commit. Keep promoted attachments
      // even on failure: the primary or its recovery generation may reference
      // them. Read only the exact primary, without advancing the writer baseline.
      let persistence = persistenceStore.persistence
      let newIDs = Set(prepared.drafts.map(\.id))
      let primaryIsUnchanged: Bool
      do {
        let stored = try persistence.withRecordFileLock {
          try persistence.loadStoredSnapshot(at: persistence.fileURL)
        }
        primaryIsUnchanged = stored.drafts.allSatisfy { !newIDs.contains($0.id) }
      } catch {
        primaryIsUnchanged = false
      }
      if !primaryIsUnchanged {
        persistenceStore.protectWritesForUnrecoverableSnapshot(
          message: persistenceStore.lastSaveError ?? persistenceStore.status
        )
      }
      throw WorkspaceBackupArticleRestoreError.persistenceFailed
    }
    committed = true
    return prepared.drafts.count
  }

  public func createWorkspaceBackup(
    at destinationURL: URL,
    applicationVersion: String? = nil,
    limits: WorkspaceBackupService.Limits = .init(),
    actor: WorkbenchOperationLogActor = .user,
    selectedCategories: Set<WorkspaceBackupCategory>? = nil
  ) async -> WorkspaceBackupPreview? {
    guard flushPendingChanges() else {
      setLastSaveStatus(CoreL10n.text("工作区备份失败：仍有草稿或站点文件未能保存"))
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceBackupCreated,
          outcome: .failed,
          actor: actor
        )
      )
      return nil
    }

    let shouldIncludeHistory = selectedCategories?.contains(.operationHistory) ?? true
    let operationHistoryDocument = shouldIncludeHistory
      ? await flushOperationLogPersistence()
      : nil
    if shouldIncludeHistory && operationHistoryDocument == nil {
      setLastSaveStatus(CoreL10n.text("工作区备份失败：活动记录尚未安全写入磁盘"))
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceBackupCreated,
          outcome: .failed,
          actor: actor
        )
      )
      return nil
    }

    let snapshot = persistenceStore.persistence.snapshot(from: self)
    let knowledgeRootURL = knowledge.rootURL
    let rssDatabaseURL = rssReaderFileURL
    let rssMediaDirectoryURL = rssDatabaseURL.map {
      RSSReaderStore.mediaCacheDirectoryURL(for: $0)
    }
    let resolvedApplicationVersion = applicationVersion
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"

    setLastSaveStatus(CoreL10n.text("正在创建完整工作区备份…"))
    do {
      let preview = try await runWorkspaceBackupIO {
        try WorkspaceBackupService(limits: limits).createBackup(
          at: destinationURL,
          snapshot: snapshot,
          operationHistoryDocument: operationHistoryDocument,
          knowledgeRootURL: knowledgeRootURL,
          rssDatabaseURL: rssDatabaseURL,
          rssMediaDirectoryURL: rssMediaDirectoryURL,
          applicationVersion: resolvedApplicationVersion,
          currentApplicationVersion: resolvedApplicationVersion,
          selectedCategories: selectedCategories
        )
      }
      setLastSaveStatus(
        CoreL10n.format(
          "工作区备份完成：%d 篇草稿、%d 个历史版本",
          preview.draftCount,
          preview.draftVersionCount
        )
      )
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceBackupCreated,
          outcome: .succeeded,
          actor: actor,
          draftCount: preview.draftCount,
          draftVersionCount: preview.draftVersionCount
        )
      )
      return preview
    } catch {
      setLastSaveStatus(
        error is CancellationError
          ? CoreL10n.text("工作区备份已取消")
          : CoreL10n.format("工作区备份失败：%@", error.localizedDescription)
      )
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceBackupCreated,
          outcome: error is CancellationError ? .cancelled : .failed,
          actor: actor
        )
      )
      return nil
    }
  }

  public func workspaceBackupSelectiveRestorePreview(
    from backupURL: URL
  ) async throws -> WorkspaceBackupSelectiveRestorePreview {
    let appVersion = Self.workspaceBackupApplicationVersion
    return try await runWorkspaceBackupIO {
      try WorkspaceBackupService().inspectSelectiveRestore(
        at: backupURL, currentApplicationVersion: appVersion
      )
    }
  }

  public func stageSelectiveWorkspaceBackupRestore(
    from backupURL: URL,
    categories: Set<WorkspaceBackupCategory>,
    to stagingURL: URL
  ) async throws -> WorkspaceBackupSelectiveRestoreStaging {
    let appVersion = Self.workspaceBackupApplicationVersion
    return try await runWorkspaceBackupIO {
      try WorkspaceBackupService().stageSelectiveRestore(
        from: backupURL,
        categories: categories,
        to: stagingURL,
        currentApplicationVersion: appVersion
      )
    }
  }

  public func prepareSelectiveWorkspaceBackupRestore(
    from backupURL: URL,
    categories: Set<WorkspaceBackupCategory>
  ) async throws -> WorkspaceBackupSelectiveRestorePreview {
    let appVersion = Self.workspaceBackupApplicationVersion
    let persistenceFileURL = persistenceStore.persistence.fileURL
    return try await runWorkspaceBackupIO {
      let service = WorkspaceBackupService()
      let pendingURL = WorkspaceBackupService.pendingRestoreURL(for: persistenceFileURL)
      guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
        throw WorkspaceBackupError.stagingFailed(CoreL10n.text("已有待处理恢复包，请先完成或取消它"))
      }
      let stagingURL = persistenceFileURL.deletingLastPathComponent()
        .appendingPathComponent(".WorkspaceBackupCategoryStage-\(UUID().uuidString).psworkspacebackup",
          isDirectory: true)
      let staged = try service.stageSelectiveRestore(
        from: backupURL, categories: categories, to: stagingURL,
        currentApplicationVersion: appVersion
      )
      defer { try? FileManager.default.removeItem(at: staged.stagedPackageURL) }
      _ = try service.stageRestore(
        from: staged.stagedPackageURL,
        persistenceFileURL: persistenceFileURL,
        currentApplicationVersion: appVersion
      )
      return staged.preview
    }
  }

  public func workspaceBackupPreview(from backupURL: URL) async -> WorkspaceBackupPreview? {
    setLastSaveStatus(CoreL10n.text("正在校验完整工作区备份…"))
    let currentApplicationVersion = Self.workspaceBackupApplicationVersion
    do {
      let preview = try await runWorkspaceBackupIO {
        try WorkspaceBackupService().inspectBackup(
          at: backupURL,
          currentApplicationVersion: currentApplicationVersion
        )
      }
      setLastSaveStatus(CoreL10n.text("工作区备份校验通过，可以预览后恢复"))
      return preview
    } catch {
      setLastSaveStatus(
        CoreL10n.format("工作区备份不可恢复：%@", error.localizedDescription)
      )
      return nil
    }
  }

  public func stageWorkspaceBackupRestore(from backupURL: URL) async -> Bool {
    setLastSaveStatus(CoreL10n.text("正在准备完整工作区恢复…"))
    let currentApplicationVersion = Self.workspaceBackupApplicationVersion
    do {
      let persistenceFileURL = persistenceStore.persistence.fileURL
      let preview = try await runWorkspaceBackupIO {
        try WorkspaceBackupService().stageRestore(
          from: backupURL,
          persistenceFileURL: persistenceFileURL,
          currentApplicationVersion: currentApplicationVersion
        )
      }
      setLastSaveStatus(CoreL10n.text("工作区恢复包已安全暂存，应用重新启动后生效"))
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceRestorePrepared,
          outcome: .recorded,
          draftCount: preview.draftCount,
          draftVersionCount: preview.draftVersionCount
        )
      )
      return true
    } catch {
      setLastSaveStatus(
        error is CancellationError
          ? CoreL10n.text("工作区恢复准备已取消")
          : CoreL10n.format("工作区恢复准备失败：%@", error.localizedDescription)
      )
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceRestorePrepared,
          outcome: error is CancellationError ? .cancelled : .failed
        )
      )
      return false
    }
  }

  public func reportStartupWorkspaceBackupRestoreOutcome(
    _ outcome: WorkspaceBackupRestoreStartupOutcome
  ) {
    switch outcome {
    case .none:
      break
    case .restored(let result):
      setLastSaveStatus(
        CoreL10n.format(
          "工作区备份已恢复：%d 篇草稿；恢复前数据保存在 %@",
          result.restoredPreview.draftCount,
          result.recoveryURL.path
        )
      )
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceRestoreCompleted,
          outcome: .succeeded,
          actor: .background,
          draftCount: result.restoredPreview.draftCount,
          draftVersionCount: result.restoredPreview.draftVersionCount
        )
      )
    case .failed(let detail):
      setLastSaveStatus(CoreL10n.format("工作区备份自动恢复未完成：%@", detail))
      _ = recordOperationEvent(
        WorkbenchOperationEventRecord(
          kind: .workspaceRestoreCompleted,
          outcome: .failed,
          actor: .background
        )
      )
    }
  }

  private static var workspaceBackupApplicationVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }

  /// Detached workers keep blocking filesystem I/O off the main actor. Unlike
  /// awaiting a detached task directly, this handler forwards cancellation to
  /// that worker so its synchronous checkpoints can stop before replacement.
  private func runWorkspaceBackupIO<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .utility, operation: operation)
    return try await withTaskCancellationHandler(
      operation: { try await worker.value },
      onCancel: { worker.cancel() }
    )
  }
}
