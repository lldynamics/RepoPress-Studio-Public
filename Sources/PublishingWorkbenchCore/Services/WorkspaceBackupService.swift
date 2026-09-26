import CryptoKit
import PublishingBackupCore
import Foundation
import PublishingKnowledgeCore

enum WorkspaceBackupRestoreMutationCheckpoint: Hashable, Sendable {
  case transactionRecorded
  case pendingRestoreMoved
  case existingDataMoved
  case newDataInstalled
}
struct WorkspaceRestoreProcessInterruption: Error, Sendable {}

/// Creates and restores a portable, integrity-checked workspace package.
///
/// The package intentionally contains the Codable workbench snapshot, the
/// privacy-bounded operation ledger, and app-owned knowledge/RSS/attachment
/// files only. Credentials are managed separately in a restricted local file,
/// Keychain, or memory, so this service never receives a credential store and
/// never reads API keys.
public final class WorkspaceBackupService: Sendable {
  public struct Limits: Sendable {
    public var maximumManifestByteCount: Int
    public var maximumWorkbenchByteCount: Int64
    public var maximumFileCount: Int
    public var maximumSingleFileByteCount: Int64
    public var maximumTotalByteCount: Int64

    public init(
      maximumManifestByteCount: Int = 8 * 1_024 * 1_024,
      maximumWorkbenchByteCount: Int64 = 256 * 1_024 * 1_024,
      maximumFileCount: Int = 100_000,
      maximumSingleFileByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024,
      maximumTotalByteCount: Int64 = 20 * 1_024 * 1_024 * 1_024
    ) {
      precondition(maximumManifestByteCount > 0)
      precondition(maximumWorkbenchByteCount > 0)
      precondition(maximumFileCount > 0)
      precondition(maximumSingleFileByteCount > 0)
      precondition(maximumTotalByteCount > 0)
      self.maximumManifestByteCount = maximumManifestByteCount
      self.maximumWorkbenchByteCount = maximumWorkbenchByteCount
      self.maximumFileCount = maximumFileCount
      self.maximumSingleFileByteCount = maximumSingleFileByteCount
      self.maximumTotalByteCount = maximumTotalByteCount
    }
  }

  public static let manifestFileName = "manifest.json"
  public static let workbenchRelativePath = "workbench/workbench.json"
  public static let operationHistoryRelativePath = "operation-history/operation-log.json"
  public static let knowledgePackageName = "knowledge.pslibrarybackup"
  public static let rssDirectoryName = "rss"
  public static let rssDatabaseRelativePath = "rss/reader.sqlite"
  public static let rssMediaRelativePrefix = "rss/RSSMedia"
  public static let attachmentsDirectoryName = "attachments"
  public static let attachmentMarkerPrefix = WorkspaceBackupManifest.attachmentMarkerPrefix
  public static let automaticBackupDirectoryName = "WorkspaceBackups"
  public static let automaticBackupFilePrefix = "自动工作区备份-"
  static let restoreTransactionFileName = ".WorkspaceBackupRestoreTransaction.json"

  let fileManagerDependency: SendableFileManager
  let limits: Limits
  let restoreMutationHook: @Sendable (WorkspaceBackupRestoreMutationCheckpoint) throws
    -> Void
  let fileCopyProgressHook: @Sendable (String, Int64) -> Void
  let backupCommitHook: @Sendable () -> Void

  var fileManager: FileManager {
    fileManagerDependency.value
  }

  public init(
    fileManager: FileManager = .default,
    limits: Limits = Limits()
  ) {
    self.fileManagerDependency = SendableFileManager(fileManager)
    self.limits = limits
    self.restoreMutationHook = { _ in }
    self.fileCopyProgressHook = { _, _ in }
    self.backupCommitHook = {}
  }

  init(
    fileManager: FileManager = .default,
    limits: Limits = Limits(),
    restoreMutationHook: @escaping @Sendable (WorkspaceBackupRestoreMutationCheckpoint) throws
      -> Void,
    fileCopyProgressHook: @escaping @Sendable (String, Int64) -> Void = { _, _ in },
    backupCommitHook: @escaping @Sendable () -> Void = {}
  ) {
    self.fileManagerDependency = SendableFileManager(fileManager)
    self.limits = limits
    self.restoreMutationHook = restoreMutationHook
    self.fileCopyProgressHook = fileCopyProgressHook
    self.backupCommitHook = backupCommitHook
  }

  public static func defaultAutomaticBackupDirectoryURL(
    fileManager: FileManager = .default
  ) -> URL {
    let supportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent(Self.automaticBackupDirectoryName, isDirectory: true)
  }

  public func createBackup(
    at destinationURL: URL,
    snapshot: WorkbenchSnapshot,
    operationHistoryDocument: WorkbenchOperationLedgerDocument? = nil,
    knowledgeRootURL: URL,
    rssDatabaseURL: URL? = nil,
    rssMediaDirectoryURL: URL? = nil,
    applicationVersion: String,
    currentApplicationVersion: String? = nil,
    selectedCategories requestedCategories: Set<WorkspaceBackupCategory>? = nil
  ) throws -> WorkspaceBackupPreview {
    try Task.checkCancellation()
    let packageURL = normalizedPackageURL(destinationURL)
    let parentURL = packageURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(
      ".\(packageURL.lastPathComponent).creating-\(UUID().uuidString)",
      isDirectory: true
    )
    try? fileManager.removeItem(at: temporaryURL)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    var shouldRemoveTemporary = true
    defer {
      if shouldRemoveTemporary { try? fileManager.removeItem(at: temporaryURL) }
    }

    let hasExplicitCategorySelection = requestedCategories != nil
    let selectedCategories = requestedCategories ?? Set([
      .workbench, .knowledgeLibrary
    ] + (rssDatabaseURL == nil ? [] : [.rssReader])
      + (operationHistoryDocument == nil ? [] : [.operationHistory]))
    guard !selectedCategories.isEmpty else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("至少选择一类备份数据"))
    }
    let includesWorkbench = selectedCategories.contains(.workbench)
    let preparedAttachments = includesWorkbench
      ? try prepareAttachmentSnapshot(snapshot)
      : PreparedAttachmentSnapshot(snapshot: snapshot, references: [], unresolvedAttachmentCount: 0)
    try Task.checkCancellation()
    let sanitizedSnapshot = preparedAttachments.snapshot
    var records = [WorkspaceBackupFileRecord]()
    if includesWorkbench {
      let workbenchURL = temporaryURL.appendingPathComponent(Self.workbenchRelativePath)
      try fileManager.createDirectory(
        at: workbenchURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let workbenchData = try encodedWorkbenchSnapshot(sanitizedSnapshot)
      guard Int64(workbenchData.count) <= limits.maximumWorkbenchByteCount else {
        throw WorkspaceBackupError.fileTooLarge(
          path: Self.workbenchRelativePath,
          maximumByteCount: limits.maximumWorkbenchByteCount
        )
      }
      try workbenchData.write(to: workbenchURL, options: .atomic)
      records.append(try fileRecord(
        relativePath: Self.workbenchRelativePath,
        component: .workbenchState,
        under: temporaryURL
      ))
    }

    if selectedCategories.contains(.operationHistory) {
      guard let operationHistoryDocument else {
        throw WorkspaceBackupError.sourceUnavailable(Self.operationHistoryRelativePath)
      }
      try Task.checkCancellation()
      let operationHistoryURL = temporaryURL.appendingPathComponent(
        Self.operationHistoryRelativePath
      )
      try fileManager.createDirectory(
        at: operationHistoryURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let operationHistoryData = try WorkbenchOperationLedgerPersistence.encodedDocument(
        operationHistoryDocument
      )
      try operationHistoryData.write(to: operationHistoryURL, options: .atomic)
      records.append(
        try fileRecord(
          relativePath: Self.operationHistoryRelativePath,
          component: .operationHistory,
          under: temporaryURL
        ))
    }

    for preparedAttachment in preparedAttachments.references {
      try Task.checkCancellation()
      let destination = temporaryURL.appendingPathComponent(
        preparedAttachment.reference.archiveRelativePath
      )
      records.append(try copyRegularFile(
        from: preparedAttachment.sourceURL,
        to: destination,
        relativePath: preparedAttachment.reference.archiveRelativePath,
        component: .draftAttachments
      ))
    }

    if selectedCategories.contains(.knowledgeLibrary) {
      let knowledgePackageURL = temporaryURL.appendingPathComponent(
        Self.knowledgePackageName,
        isDirectory: true
      )
      let knowledgeService = KnowledgeLibraryService(
        rootURL: knowledgeRootURL,
        fileManager: fileManager
      )
      try Task.checkCancellation()
      _ = try knowledgeService.createBackupSynchronously(
        at: knowledgePackageURL,
        applicationVersion: applicationVersion
      )
      records.append(contentsOf: try recordsInDirectory(
        knowledgePackageURL,
        relativePrefix: Self.knowledgePackageName,
        component: .knowledgeLibrary,
        under: temporaryURL
      ))
    }

    var includesRSS = false
    if selectedCategories.contains(.rssReader), let rssDatabaseURL {
      try Task.checkCancellation()
      let rssBackupURL = temporaryURL.appendingPathComponent(Self.rssDatabaseRelativePath)
      _ = try RSSReaderBackupService(fileManager: fileManager).createBackup(
        from: rssDatabaseURL,
        at: rssBackupURL
      )
      records.append(try fileRecord(
        relativePath: Self.rssDatabaseRelativePath,
        component: .rssReader,
        under: temporaryURL
      ))
      let sourceMediaURL = rssMediaDirectoryURL
        ?? RSSReaderStore.mediaCacheDirectoryURL(for: rssDatabaseURL)
      for sourceFileURL in try regularFileURLs(in: sourceMediaURL)
        where !sourceFileURL.lastPathComponent.hasPrefix(".") {
        try Task.checkCancellation()
        let relativeMediaPath = try relativePath(of: sourceFileURL, under: sourceMediaURL)
        let archivePath = "\(Self.rssMediaRelativePrefix)/\(relativeMediaPath)"
        records.append(try copyRegularFile(
          from: sourceFileURL,
          to: temporaryURL.appendingPathComponent(archivePath),
          relativePath: archivePath,
          component: .rssReader
        ))
      }
      includesRSS = true
    } else if selectedCategories.contains(.rssReader) {
      throw WorkspaceBackupError.sourceUnavailable(Self.rssDatabaseRelativePath)
    }

    // Preserve the historical contracts for callers that do not yet supply an
    // operation ledger. A complete app backup supplies the ledger and writes
    // v3; legacy workspace-only and RSS-aware callers continue to write v1/v2.
    let formatVersion = hasExplicitCategorySelection
      ? WorkspaceBackupManifest.currentFormatVersion
      : (operationHistoryDocument != nil
          ? 3
          : (includesRSS ? 2 : WorkspaceBackupManifest.minimumSupportedFormatVersion))

    records.sort { $0.relativePath < $1.relativePath }
    try Task.checkCancellation()
    let totalByteCount = try validateFileLimits(records)
    let manifest = WorkspaceBackupManifest(
      formatVersion: formatVersion,
      applicationVersion: applicationVersion,
      includesAPIKeys: false,
      profileCount: includesWorkbench ? sanitizedSnapshot.profiles.count : 0,
      draftCount: includesWorkbench ? sanitizedSnapshot.drafts.count : 0,
      draftVersionCount: includesWorkbench ? sanitizedSnapshot.draftVersions.count : 0,
      releaseRecordCount: includesWorkbench ? sanitizedSnapshot.releaseRecords.count : 0,
      attachmentReferenceCount: preparedAttachments.references.count,
      unresolvedAttachmentCount: preparedAttachments.unresolvedAttachmentCount,
      components: componentSummaries(for: records, formatVersion: formatVersion),
      fileCount: records.count,
      totalByteCount: totalByteCount,
      attachmentReferences: preparedAttachments.references.map(\.reference),
      files: records,
      selectedCategories: hasExplicitCategorySelection
        ? WorkspaceBackupCategory.allCases.filter { selectedCategories.contains($0) }
        : nil,
      categorySummaries: hasExplicitCategorySelection
        ? categorySummaries(for: records, selectedCategories: selectedCategories)
        : nil
    )
    try encodeManifest(
      manifest,
      to: temporaryURL.appendingPathComponent(Self.manifestFileName)
    )
    try Task.checkCancellation()
    var committedPreview = try validatedBackup(
      at: temporaryURL,
      currentApplicationVersion: currentApplicationVersion ?? applicationVersion
    ).preview
    committedPreview.backupURL = packageURL

    // This is the last cancellation boundary. Once replacement commits, do
    // not run another cancellation-aware read that could report cancellation
    // after the destination has already changed.
    try Task.checkCancellation()
    try replaceItem(at: packageURL, withItemAt: temporaryURL)
    shouldRemoveTemporary = false
    backupCommitHook()
    return committedPreview
  }

  public func inspectBackup(
    at backupURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupPreview {
    try Task.checkCancellation()
    let packageURL = normalizedPackageURL(backupURL)
    return try validatedBackup(
      at: packageURL,
      currentApplicationVersion: currentApplicationVersion
    ).preview
  }

  public func inspectSelectiveRestore(
    at backupURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupSelectiveRestorePreview {
    let validated = try validatedBackup(at: normalizedPackageURL(backupURL),
      currentApplicationVersion: currentApplicationVersion)
    let available = availableCategories(in: validated.manifest)
    return WorkspaceBackupSelectiveRestorePreview(
      backupPreview: validated.preview,
      availableCategories: available,
      selectedCategories: Set(available),
      replacementCategories: Set(available),
      categorySummaries: validated.manifest.categorySummaries
        ?? categorySummaries(for: validated.manifest.files, selectedCategories: Set(available))
    )
  }

  /// Produces a separately validated, isolated package containing only the
  /// chosen categories. It does not mutate live stores.
  public func stageSelectiveRestore(
    from backupURL: URL,
    categories: Set<WorkspaceBackupCategory>,
    to stagingURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupSelectiveRestoreStaging {
    try Task.checkCancellation()
    let sourceURL = normalizedPackageURL(backupURL)
    let validated = try validatedBackup(at: sourceURL,
      currentApplicationVersion: currentApplicationVersion)
    let available = Set(availableCategories(in: validated.manifest))
    guard !categories.isEmpty, categories.isSubset(of: available) else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("所选恢复类别不在备份中"))
    }
    let chosenRecords = validated.manifest.files.filter { record in
      switch record.component {
      case .workbenchState, .draftAttachments: return categories.contains(.workbench)
      case .knowledgeLibrary: return categories.contains(.knowledgeLibrary)
      case .rssReader: return categories.contains(.rssReader)
      case .operationHistory: return categories.contains(.operationHistory)
      }
    }
    var manifest = validated.manifest
    manifest.formatVersion = WorkspaceBackupManifest.currentFormatVersion
    manifest.selectedCategories = WorkspaceBackupCategory.allCases.filter { categories.contains($0) }
    manifest.files = chosenRecords
    manifest.fileCount = chosenRecords.count
    manifest.totalByteCount = try validateFileLimits(chosenRecords)
    manifest.components = componentSummaries(for: chosenRecords, formatVersion: manifest.formatVersion)
    manifest.categorySummaries = categorySummaries(for: chosenRecords, selectedCategories: categories)
    if !categories.contains(.workbench) {
      manifest.profileCount = 0
      manifest.draftCount = 0
      manifest.draftVersionCount = 0
      manifest.releaseRecordCount = 0
      manifest.attachmentReferenceCount = 0
      manifest.unresolvedAttachmentCount = 0
      manifest.attachmentReferences = []
    }
    let destinationURL = normalizedPackageURL(stagingURL)
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw WorkspaceBackupError.stagingFailed(CoreL10n.text("恢复暂存目录已存在"))
    }
    let parentURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(".selective-restore-\(UUID().uuidString)",
      isDirectory: true)
    try? fileManager.removeItem(at: temporaryURL)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryURL) }
    for record in chosenRecords {
      try Task.checkCancellation()
      let copied = try copyRegularFile(
        from: sourceURL.appendingPathComponent(record.relativePath),
        to: temporaryURL.appendingPathComponent(record.relativePath),
        relativePath: record.relativePath,
        component: record.component
      )
      guard copied == record else { throw WorkspaceBackupError.checksumMismatch(record.relativePath) }
    }
    try encodeManifest(manifest, to: temporaryURL.appendingPathComponent(Self.manifestFileName))
    _ = try validatedBackup(at: temporaryURL, currentApplicationVersion: currentApplicationVersion)
    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    let preview = WorkspaceBackupSelectiveRestorePreview(
      backupPreview: validated.preview,
      availableCategories: available.sorted { $0.rawValue < $1.rawValue },
      selectedCategories: categories,
      replacementCategories: categories,
      categorySummaries: manifest.categorySummaries ?? []
    )
    return WorkspaceBackupSelectiveRestoreStaging(preview: preview, stagedPackageURL: destinationURL)
  }

  func availableCategories(in manifest: WorkspaceBackupManifest) -> [WorkspaceBackupCategory] {
    if let declared = manifest.selectedCategories { return declared }
    var result = [WorkspaceBackupCategory]()
    let paths = Set(manifest.files.map(\.relativePath))
    if paths.contains(Self.workbenchRelativePath) { result.append(.workbench) }
    if paths.contains(where: { $0.hasPrefix(Self.knowledgePackageName + "/") }) {
      result.append(.knowledgeLibrary)
    }
    if paths.contains(Self.rssDatabaseRelativePath) { result.append(.rssReader) }
    if paths.contains(Self.operationHistoryRelativePath) { result.append(.operationHistory) }
    return result
  }

  public func stageRestore(
    from backupURL: URL,
    persistenceFileURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupPreview {
    try Task.checkCancellation()
    let sourceURL = normalizedPackageURL(backupURL)
    let validated = try validatedBackup(
      at: sourceURL,
      currentApplicationVersion: currentApplicationVersion
    )
    let pendingURL = Self.pendingRestoreURL(for: persistenceFileURL)
    let parentURL = pendingURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(
      ".WorkspaceBackupPendingRestore-\(UUID().uuidString)",
      isDirectory: true
    )
    try? fileManager.removeItem(at: temporaryURL)
    do {
      try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
      try encodeManifest(
        validated.manifest,
        to: temporaryURL.appendingPathComponent(Self.manifestFileName)
      )
      for record in validated.manifest.files {
        try Task.checkCancellation()
        let destination = temporaryURL.appendingPathComponent(record.relativePath)
        let copiedRecord = try copyRegularFile(
          from: sourceURL.appendingPathComponent(record.relativePath),
          to: destination,
          relativePath: record.relativePath,
          component: record.component
        )
        guard copiedRecord == record else {
          throw WorkspaceBackupError.checksumMismatch(record.relativePath)
        }
      }
      _ = try validatedBackup(
        at: temporaryURL,
        currentApplicationVersion: currentApplicationVersion
      )
      try Task.checkCancellation()
      try replaceItem(at: pendingURL, withItemAt: temporaryURL)
    } catch is CancellationError {
      try? fileManager.removeItem(at: temporaryURL)
      throw CancellationError()
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw WorkspaceBackupError.stagingFailed(error.localizedDescription)
    }
    return validated.preview
  }

  public static func pendingRestoreURL(for persistenceFileURL: URL) -> URL {
    persistenceFileURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".WorkspaceBackupPendingRestore.psworkspacebackup",
        isDirectory: true
      )
  }

  /// Rolls back a restore transaction that was interrupted after destructive
  /// filesystem moves began. The operation is idempotent: repeated calls after
  /// a successful rollback return `.none` and leave the restored live data
  /// untouched.
  public static func recoverInterruptedRestoreIfNeeded(
    persistenceFileURL: URL = WorkbenchPersistence().fileURL,
    knowledgeRootURL: URL = KnowledgeLibraryService.defaultRootURL(),
    rssDatabaseURL: URL = RSSReaderStore.defaultFileURL(),
    attachmentRootURL: URL = ManagedAttachmentFileStore.defaultRootDirectoryURL(),
    fileManager: FileManager = .default
  ) -> WorkspaceBackupRestoreRecoveryOutcome {
    do {
      let service = WorkspaceBackupService(fileManager: fileManager)
      let paths = RestoreRuntimePaths(
        persistenceFileURL: persistenceFileURL,
        knowledgeRootURL: knowledgeRootURL,
        rssDatabaseURL: rssDatabaseURL,
        attachmentRootURL: attachmentRootURL
      )
      return try service.rollbackInterruptedRestoreIfNeeded(paths: paths)
        ? .rolledBack
        : .none
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  public static func applyPendingRestoreIfNeeded(
    persistenceFileURL: URL = WorkbenchPersistence().fileURL,
    knowledgeRootURL: URL = KnowledgeLibraryService.defaultRootURL(),
    rssDatabaseURL: URL = RSSReaderStore.defaultFileURL(),
    attachmentRootURL: URL = ManagedAttachmentFileStore.defaultRootDirectoryURL(),
    currentApplicationVersion: String? = nil,
    fileManager: FileManager = .default
  ) -> WorkspaceBackupRestoreStartupOutcome {
    do {
      let service = WorkspaceBackupService(fileManager: fileManager)
      guard let result = try service.applyPendingRestore(
          persistenceFileURL: persistenceFileURL,
          knowledgeRootURL: knowledgeRootURL,
          rssDatabaseURL: rssDatabaseURL,
          attachmentRootURL: attachmentRootURL,
          currentApplicationVersion: currentApplicationVersion
        ) else {
        return .none
      }
      return .restored(result)
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
