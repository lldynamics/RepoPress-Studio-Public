import Foundation
import PublishingBackupCore
import PublishingCoreSupport
import PublishingKnowledgeCore

/// The scheduler can request a backup without owning or inspecting the workbench root.
@MainActor
protocol WorkspaceBackupSource: AnyObject {
  var isAvailable: Bool { get }
  var lastSaveStatus: String { get }

  func estimatedBackupBytes(
    categories: Set<WorkspaceBackupCategory>, fileManager: FileManager
  ) throws -> Int64

  func createBackup(
    at destinationURL: URL,
    applicationVersion: String,
    limits: WorkspaceBackupService.Limits,
    actor: WorkbenchOperationLogActor,
    selectedCategories: Set<WorkspaceBackupCategory>
  ) async -> WorkspaceBackupPreview?
}

/// The adapter alone knows how a workbench snapshot and its auxiliary data are stored.
/// Its root reference stays weak, preserving the scheduler's former lifetime behavior.
@MainActor
final class WorkbenchBackupSourceAdapter: WorkspaceBackupSource {
  private weak var store: WorkbenchStore?

  init(store: WorkbenchStore) {
    self.store = store
  }

  var isAvailable: Bool { store != nil }
  var lastSaveStatus: String { store?.lastSaveStatus ?? "" }

  func createBackup(
    at destinationURL: URL,
    applicationVersion: String,
    limits: WorkspaceBackupService.Limits,
    actor: WorkbenchOperationLogActor,
    selectedCategories: Set<WorkspaceBackupCategory>
  ) async -> WorkspaceBackupPreview? {
    guard let store else { return nil }
    return await store.createWorkspaceBackup(
      at: destinationURL,
      applicationVersion: applicationVersion,
      limits: limits,
      actor: actor,
      selectedCategories: selectedCategories
    )
  }

  func estimatedBackupBytes(
    categories: Set<WorkspaceBackupCategory>, fileManager: FileManager
  ) throws -> Int64 {
    guard let store else {
      throw WorkspaceBackupError.sourceUnavailable(
        CoreL10n.text("自动备份暂不可用：工作区尚未准备完成")
      )
    }
    var total: Int64 = 0
    if categories.contains(.workbench) {
      let snapshot = store.persistenceStore.persistence.snapshot(from: store)
      total = Int64(try JSONEncoder().encode(snapshot).count)
      var countedAttachmentPaths = Set<String>()
      let attachments =
        snapshot.drafts.flatMap(\.attachments)
        + snapshot.recycledDrafts.flatMap { $0.draft.attachments }
        + snapshot.draftVersions.flatMap { $0.draft.attachments }
      for attachment in attachments {
        guard let sourcePath = attachment.sourceFilePath else { continue }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard countedAttachmentPaths.insert(sourceURL.standardizedFileURL.path).inserted else {
          continue
        }
        total = try addingEstimate(total, estimatedSize(at: sourceURL, fileManager: fileManager))
      }
      total = try addingEstimate(
        total,
        estimatedSize(
          at: store.persistenceStore.persistence.retiredFeatureArchiveDirectoryURL,
          fileManager: fileManager
        )
      )
    }
    if categories.contains(.knowledgeLibrary) {
      let size = try estimatedSize(at: store.knowledge.rootURL, fileManager: fileManager)
      total = try addingEstimate(total, size)
    }
    if categories.contains(.rssReader), let rssURL = store.rssReaderFileURL {
      var databaseSize = try estimatedSize(at: rssURL, fileManager: fileManager)
      databaseSize = try addingEstimate(
        databaseSize,
        estimatedSize(at: URL(fileURLWithPath: rssURL.path + "-wal"), fileManager: fileManager)
      )
      databaseSize = try addingEstimate(
        databaseSize,
        estimatedSize(at: URL(fileURLWithPath: rssURL.path + "-shm"), fileManager: fileManager)
      )
      total = try addingEstimate(total, databaseSize)
      total = try addingEstimate(
        total,
        estimatedSize(
          at: RSSReaderStore.mediaCacheDirectoryURL(for: rssURL), fileManager: fileManager)
      )
    }
    if categories.contains(.operationHistory) {
      let history = try WorkbenchOperationLedgerPersistence.encodedDocument(
        store.operationHistory.document)
      total = try addingEstimate(total, Int64(history.count))
    }
    return total
  }

  private func estimatedSize(at root: URL, fileManager: FileManager) throws -> Int64 {
    guard fileManager.fileExists(atPath: root.path) else { return 0 }
    let values = try root.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
    ])
    if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
    guard values.isDirectory == true,
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
      )
    else { return 0 }
    var size: Int64 = 0
    for case let fileURL as URL in enumerator {
      let fileValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if fileValues.isRegularFile == true {
        size = try addingEstimate(size, Int64(fileValues.fileSize ?? 0))
      }
    }
    return size
  }

  private func addingEstimate(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let addition = lhs.addingReportingOverflow(rhs)
    guard !addition.overflow else {
      throw WorkspaceBackupError.backupTooLarge(
        maximumByteCount: WorkspaceBackupScheduler.selectedDiskBackupMaximumByteCount)
    }
    return addition.partialValue
  }
}
