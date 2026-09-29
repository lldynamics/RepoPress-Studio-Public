import Foundation
import PublishingBackupCore
import PublishingKnowledgeCore
import PublishingWorkbenchCore

struct WorkbenchRuntimePaths: Sendable {
  let persistence: WorkbenchPersistence
  let knowledgeLibraryService: KnowledgeLibraryService
  let rssReaderFileURL: URL
  let managedAttachmentFileStore: ManagedAttachmentFileStore
  let workspaceBackupDirectoryURL: URL

  init(
    persistence: WorkbenchPersistence,
    knowledgeLibraryService: KnowledgeLibraryService,
    rssReaderFileURL: URL,
    managedAttachmentFileStore: ManagedAttachmentFileStore,
    workspaceBackupDirectoryURL: URL
  ) {
    self.persistence = persistence
    self.knowledgeLibraryService = knowledgeLibraryService
    self.rssReaderFileURL = rssReaderFileURL
    self.managedAttachmentFileStore = managedAttachmentFileStore
    self.workspaceBackupDirectoryURL = workspaceBackupDirectoryURL
  }

  init(layout: WorkbenchDataRootLayout) {
    self.init(
      persistence: WorkbenchPersistence(fileURL: layout.workbenchFileURL),
      knowledgeLibraryService: KnowledgeLibraryService(rootURL: layout.knowledgeLibraryURL),
      rssReaderFileURL: layout.rssReaderDatabaseURL,
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: layout.managedAttachmentsURL
      ),
      workspaceBackupDirectoryURL: layout.rootURL.appendingPathComponent(
        WorkspaceBackupService.automaticBackupDirectoryName,
        isDirectory: true
      )
    )
  }
}

enum WorkbenchLaunchPreparation: Sendable {
  struct Ready: Sendable {
    let workspaceRestoreOutcome: WorkspaceBackupRestoreStartupOutcome
    let restoreOutcome: KnowledgeLibraryRestoreStartupOutcome
    let snapshotSource: WorkbenchInitialSnapshotSource
  }

  case ready(Ready)
  case blocked(String)

  static func applyWorkspaceRestore(_ paths: WorkbenchRuntimePaths)
    -> WorkspaceBackupRestoreStartupOutcome
  {
    WorkspaceBackupService.applyPendingRestoreIfNeeded(
      persistenceFileURL: paths.persistence.fileURL,
      knowledgeRootURL: paths.knowledgeLibraryService.rootURL,
      rssDatabaseURL: paths.rssReaderFileURL,
      attachmentRootURL: paths.managedAttachmentFileStore.rootDirectoryURL
    )
  }

  static func prepare(
    paths: WorkbenchRuntimePaths,
    safeMode: Bool,
    applyWorkspaceRestore: @Sendable (WorkbenchRuntimePaths) -> WorkspaceBackupRestoreStartupOutcome
  ) -> Self {
    let workspaceOutcome = safeMode ? .none : applyWorkspaceRestore(paths)
    // Check again after this launch's restore attempt, before any persistence
    // recovery or SQLite bootstrap can write to a partially restored workspace.
    do {
      if try WorkspaceBackupService.hasUnfinishedRestoreTransaction(
        persistenceFileURL: paths.persistence.fileURL
      ) {
        let detail: String
        if case .failed(let message) = workspaceOutcome {
          detail = message
        } else {
          detail = paths.persistence.fileURL.deletingLastPathComponent().path
        }
        return blockedRestore(detail)
      }
    } catch {
      return blockedRestore(error.localizedDescription)
    }

    let knowledgeOutcome: KnowledgeLibraryRestoreStartupOutcome
    if !safeMode, case .none = workspaceOutcome {
      knowledgeOutcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded(
        rootURL: paths.knowledgeLibraryService.rootURL
      )
    } else {
      knowledgeOutcome = .none
    }
    let snapshotSource: WorkbenchInitialSnapshotSource
    do {
      snapshotSource = .preloaded(try paths.persistence.loadWithRecovery())
    } catch {
      snapshotSource = .loadFailure(error.localizedDescription)
    }
    return .ready(
      Ready(
        workspaceRestoreOutcome: workspaceOutcome,
        restoreOutcome: knowledgeOutcome,
        snapshotSource: snapshotSource
      ))
  }

  private static func blockedRestore(_ detail: String) -> Self {
    .blocked(
      String(
        format: String(localized: "工作区恢复尚未完成，已暂停打开。请保留数据文件夹，并在修复磁盘权限或空间问题后重新打开。详情：%@"),
        detail
      ))
  }
}
