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

/// Choosing which data folder the app opens: the fresh-install default, an
/// existing folder picked in Settings, and resolving a user's folder choice.
extension WorkbenchLaunchCoordinator {
  /// The app's coordinator: a fresh install uses the recommended data folder.
  static func production() -> WorkbenchLaunchCoordinator {
    WorkbenchLaunchCoordinator(firstLaunchDataRootParentURL: recommendedDataRootParentURL)
  }

  /// A fresh install opens the data folder at the recommended location, or
  /// creates it there, instead of asking first. Legacy data still asks so the
  /// user can choose migration; other locations remain available in Settings.
  func prepareFirstLaunchDataRoot() async {
    guard let parentURL = firstLaunchDataRootParentURL, !legacyDataAvailability() else {
      showDataRootSetup(
        message: String(localized: "请恢复以前的数据文件夹，或新建一个工作区。")
      )
      return
    }
    let defaultRootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let probe = await Task.detached(priority: .utility) {
      WorkbenchDataRootInspector().probe(at: defaultRootURL)
    }.value
    guard !Task.isCancelled else { return }
    if case .existing = probe {
      await restoreExistingDataRoot(at: defaultRootURL)
    } else {
      await createRecommendedDataRoot(in: parentURL)
    }
  }

  /// Remembers another existing data folder chosen in Settings. The current
  /// workspace is saved first and stays unchanged; the chosen folder opens on
  /// the next launch, so nothing is copied or merged.
  func switchToExistingDataRoot(at selectedURL: URL) async -> URL? {
    guard let pathStore, let store, let rssStore else {
      dataRootMessage = String(localized: "当前数据文件夹尚未准备完成，无法更改位置。")
      return nil
    }
    guard !store.knowledge.isBusy,
      !rssStore.isRefreshing,
      !store.workspaceBackupScheduler.isRunning
    else {
      dataRootMessage = String(localized: "资料库、RSS 刷新或备份仍在运行，请完成后再更改存储位置。")
      return nil
    }
    let selection = await Task.detached(priority: .utility) {
      Self.resolveDataRootSelection(selectedURL)
    }.value
    guard case .root(let rootURL) = selection else {
      dataRootMessage = String(localized: "所选位置不是 RepoPress 数据文件夹，请直接选择数据文件夹。")
      return nil
    }
    guard rootURL.path != dataRootPath else {
      dataRootMessage = String(localized: "已在使用这个数据文件夹。")
      return nil
    }
    let probe = await Task.detached(priority: .utility) {
      WorkbenchDataRootInspector().probe(at: rootURL)
    }.value
    guard case .existing(let manifest) = probe else {
      if case .incompatible(let reason) = probe {
        dataRootMessage = friendlyMessage(for: reason)
      } else {
        dataRootMessage = String(localized: "所选位置不是 RepoPress 数据文件夹，请直接选择数据文件夹。")
      }
      return nil
    }
    guard store.flushPendingChanges() else {
      dataRootMessage = String(localized: "仍有修改未能保存，未更改存储位置。请先解决保存错误。")
      return nil
    }
    do {
      try pathStore.rememberRoot(rootURL, dataID: manifest.dataID)
      dataRootMessage = nil
      return rootURL
    } catch {
      dataRootMessage = friendlyMessage(for: error)
      return nil
    }
  }

  enum DataRootSelectionResolution: Sendable {
    case root(URL)
    case multipleRoots
    case notFound(WorkbenchDataRootProbeResult)
  }

  nonisolated static func resolveDataRootSelection(
    _ selectedURL: URL
  ) -> DataRootSelectionResolution {
    let standardizedURL = selectedURL.standardizedFileURL
    let inspector = WorkbenchDataRootInspector()
    let selectedProbe = inspector.probe(at: standardizedURL)
    if case .existing = selectedProbe {
      return .root(standardizedURL)
    }

    let childURLs: [URL]
    do {
      childURLs = try FileManager.default.contentsOfDirectory(
        at: standardizedURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      return .notFound(selectedProbe)
    }

    let existingRoots =
      childURLs
      .filter { url in
        guard
          let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
          )
        else {
          return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
      }
      .filter { url in
        if case .existing = inspector.probe(at: url) {
          return true
        }
        return false
      }
      .map(\.standardizedFileURL)
      .sorted { $0.path < $1.path }

    switch existingRoots.count {
    case 1:
      return .root(existingRoots[0])
    case 2...:
      return .multipleRoots
    default:
      return .notFound(selectedProbe)
    }
  }
}
