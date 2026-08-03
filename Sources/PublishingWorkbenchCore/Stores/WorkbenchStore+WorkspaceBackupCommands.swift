import Foundation

extension WorkbenchStore {
  public func createWorkspaceBackup(
    at destinationURL: URL,
    applicationVersion: String? = nil
  ) async -> WorkspaceBackupPreview? {
    guard flushPendingChanges() else {
      setLastSaveStatus(CoreL10n.text("工作区备份失败：仍有草稿或站点文件未能保存"))
      return nil
    }

    let snapshot = persistenceStore.persistence.snapshot(from: self)
    let knowledgeRootURL = knowledge.rootURL
    let rssDatabaseURL = rssReaderFileURL
    let resolvedApplicationVersion = applicationVersion
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"

    setLastSaveStatus(CoreL10n.text("正在创建完整工作区备份…"))
    do {
      let preview = try await Task.detached(priority: .utility) {
        try WorkspaceBackupService().createBackup(
          at: destinationURL,
          snapshot: snapshot,
          knowledgeRootURL: knowledgeRootURL,
          rssDatabaseURL: rssDatabaseURL,
          applicationVersion: resolvedApplicationVersion,
          currentApplicationVersion: resolvedApplicationVersion
        )
      }.value
      setLastSaveStatus(
        CoreL10n.format(
          "工作区备份完成：%d 篇草稿、%d 个历史版本",
          preview.draftCount,
          preview.draftVersionCount
        )
      )
      return preview
    } catch {
      setLastSaveStatus(CoreL10n.format("工作区备份失败：%@", error.localizedDescription))
      return nil
    }
  }

  public func workspaceBackupPreview(from backupURL: URL) async -> WorkspaceBackupPreview? {
    setLastSaveStatus(CoreL10n.text("正在校验完整工作区备份…"))
    let currentApplicationVersion = Self.workspaceBackupApplicationVersion
    do {
      let preview = try await Task.detached(priority: .utility) {
        try WorkspaceBackupService().inspectBackup(
          at: backupURL,
          currentApplicationVersion: currentApplicationVersion
        )
      }.value
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
      _ = try await Task.detached(priority: .utility) {
        try WorkspaceBackupService().stageRestore(
          from: backupURL,
          persistenceFileURL: persistenceFileURL,
          currentApplicationVersion: currentApplicationVersion
        )
      }.value
      setLastSaveStatus(CoreL10n.text("工作区恢复包已安全暂存，应用重新启动后生效"))
      return true
    } catch {
      setLastSaveStatus(
        CoreL10n.format("工作区恢复准备失败：%@", error.localizedDescription)
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
    case .failed(let detail):
      setLastSaveStatus(CoreL10n.format("工作区备份自动恢复未完成：%@", detail))
    }
  }

  private static var workspaceBackupApplicationVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }
}
