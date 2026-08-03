import CryptoKit
import Foundation

enum WorkspaceBackupRestoreMutationCheckpoint: Hashable, Sendable {
  case transactionRecorded
  case pendingRestoreMoved
  case existingDataMoved
  case newDataInstalled
}

struct WorkspaceRestoreProcessInterruption: Error, Sendable {}

/// Creates and restores a portable, integrity-checked workspace package.
///
/// The package intentionally contains the Codable workbench snapshot and the
/// app-owned knowledge/RSS/attachment files only. Credentials are Keychain data,
/// so this service never receives a Keychain store and never reads API keys.
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
  public static let knowledgePackageName = "knowledge.pslibrarybackup"
  public static let rssDirectoryName = "rss"
  public static let rssDatabaseRelativePath = "rss/reader.sqlite"
  public static let attachmentsDirectoryName = "attachments"
  public static let attachmentMarkerPrefix = WorkspaceBackupManifest.attachmentMarkerPrefix
  public static let automaticBackupDirectoryName = "WorkspaceBackups"
  public static let automaticBackupFilePrefix = "自动工作区备份-"
  static let restoreTransactionFileName = ".WorkspaceBackupRestoreTransaction.json"

  private let fileManagerDependency: SendableFileManager
  private let limits: Limits
  private let restoreMutationHook: @Sendable (WorkspaceBackupRestoreMutationCheckpoint) throws
    -> Void

  private var fileManager: FileManager {
    fileManagerDependency.value
  }

  public init(
    fileManager: FileManager = .default,
    limits: Limits = Limits()
  ) {
    self.fileManagerDependency = SendableFileManager(fileManager)
    self.limits = limits
    self.restoreMutationHook = { _ in }
  }

  init(
    fileManager: FileManager = .default,
    limits: Limits = Limits(),
    restoreMutationHook: @escaping @Sendable (WorkspaceBackupRestoreMutationCheckpoint) throws
      -> Void
  ) {
    self.fileManagerDependency = SendableFileManager(fileManager)
    self.limits = limits
    self.restoreMutationHook = restoreMutationHook
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
    knowledgeRootURL: URL,
    rssDatabaseURL: URL? = nil,
    applicationVersion: String,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupPreview {
    let packageURL = normalizedPackageURL(destinationURL)
    let didAccess = packageURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { packageURL.stopAccessingSecurityScopedResource() }
    }

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

    let preparedAttachments = try prepareAttachmentSnapshot(snapshot)
    let sanitizedSnapshot = preparedAttachments.snapshot
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

    var records = [try fileRecord(
      relativePath: Self.workbenchRelativePath,
      component: .workbenchState,
      under: temporaryURL
    )]

    for preparedAttachment in preparedAttachments.references {
      let destination = temporaryURL.appendingPathComponent(
        preparedAttachment.reference.archiveRelativePath
      )
      let didStartAccessing = preparedAttachment.sourceURL.startAccessingSecurityScopedResource()
      defer {
        if didStartAccessing {
          preparedAttachment.sourceURL.stopAccessingSecurityScopedResource()
        }
      }
      records.append(try copyRegularFile(
        from: preparedAttachment.sourceURL,
        to: destination,
        relativePath: preparedAttachment.reference.archiveRelativePath,
        component: .draftAttachments
      ))
    }

    let knowledgePackageURL = temporaryURL.appendingPathComponent(
      Self.knowledgePackageName,
      isDirectory: true
    )
    let knowledgeService = KnowledgeLibraryService(
      rootURL: knowledgeRootURL,
      fileManager: fileManager
    )
    let knowledgeDatabase = try knowledgeService.database()
    _ = try KnowledgeLibraryBackupService(
      rootURL: knowledgeRootURL,
      fileManager: fileManager
    ).createBackup(
      at: knowledgePackageURL,
      database: knowledgeDatabase,
      applicationVersion: applicationVersion
    )
    records.append(contentsOf: try recordsInDirectory(
      knowledgePackageURL,
      relativePrefix: Self.knowledgePackageName,
      component: .knowledgeLibrary,
      under: temporaryURL
    ))

    let formatVersion: Int
    if let rssDatabaseURL {
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
      formatVersion = WorkspaceBackupManifest.currentFormatVersion
    } else {
      // Preserve the v1 contract for callers that intentionally create a
      // workspace-only archive. The app's complete-backup path always passes
      // the configured RSS database and therefore writes v2.
      formatVersion = WorkspaceBackupManifest.minimumSupportedFormatVersion
    }

    records.sort { $0.relativePath < $1.relativePath }
    let totalByteCount = try validateFileLimits(records)
    let manifest = WorkspaceBackupManifest(
      formatVersion: formatVersion,
      applicationVersion: applicationVersion,
      includesAPIKeys: false,
      profileCount: sanitizedSnapshot.profiles.count,
      draftCount: sanitizedSnapshot.drafts.count,
      draftVersionCount: sanitizedSnapshot.draftVersions.count,
      releaseRecordCount: sanitizedSnapshot.releaseRecords.count,
      attachmentReferenceCount: preparedAttachments.references.count,
      unresolvedAttachmentCount: preparedAttachments.unresolvedAttachmentCount,
      components: componentSummaries(for: records, formatVersion: formatVersion),
      fileCount: records.count,
      totalByteCount: totalByteCount,
      attachmentReferences: preparedAttachments.references.map(\.reference),
      files: records
    )
    try encodeManifest(
      manifest,
      to: temporaryURL.appendingPathComponent(Self.manifestFileName)
    )
    _ = try validatedBackup(at: temporaryURL)

    try replaceItem(at: packageURL, withItemAt: temporaryURL)
    shouldRemoveTemporary = false
    return try inspectBackup(
      at: packageURL,
      currentApplicationVersion: currentApplicationVersion ?? applicationVersion
    )
  }

  public func inspectBackup(
    at backupURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupPreview {
    let packageURL = normalizedPackageURL(backupURL)
    let didAccess = packageURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { packageURL.stopAccessingSecurityScopedResource() }
    }
    return try validatedBackup(
      at: packageURL,
      currentApplicationVersion: currentApplicationVersion
    ).preview
  }

  public func stageRestore(
    from backupURL: URL,
    persistenceFileURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> WorkspaceBackupPreview {
    let sourceURL = normalizedPackageURL(backupURL)
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
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
      try replaceItem(at: pendingURL, withItemAt: temporaryURL)
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

  func applyPendingRestore(
    persistenceFileURL: URL,
    knowledgeRootURL: URL,
    rssDatabaseURL: URL,
    attachmentRootURL: URL,
    currentApplicationVersion: String?
  ) throws -> WorkspaceBackupRestoreStartupResult? {
    let runtimePaths = RestoreRuntimePaths(
      persistenceFileURL: persistenceFileURL,
      knowledgeRootURL: knowledgeRootURL,
      rssDatabaseURL: rssDatabaseURL,
      attachmentRootURL: attachmentRootURL
    )
    _ = try rollbackInterruptedRestoreIfNeeded(paths: runtimePaths)
    let pendingURL = Self.pendingRestoreURL(for: persistenceFileURL)
    guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }

    let validated = try validatedBackup(
      at: pendingURL,
      currentApplicationVersion: currentApplicationVersion
    )
    let parentURL = persistenceFileURL.deletingLastPathComponent()
    let transactionID = UUID()
    let stagingURL = restoreStagingURL(
      transactionID: transactionID,
      parentURL: parentURL
    )
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    var preserveStagingForSimulatedInterruption = false
    defer {
      if !preserveStagingForSimulatedInterruption {
        try? fileManager.removeItem(at: stagingURL)
      }
    }

    let restoredSnapshot = try restoredSnapshot(
      validated.snapshot,
      references: validated.manifest.attachmentReferences,
      attachmentRootURL: attachmentRootURL
    )
    try WorkbenchSnapshotSemanticValidator.validate(restoredSnapshot)
    let restoredSnapshotData = try encodedWorkbenchSnapshot(restoredSnapshot)
    guard Int64(restoredSnapshotData.count) <= limits.maximumWorkbenchByteCount else {
      throw WorkspaceBackupError.fileTooLarge(
        path: Self.workbenchRelativePath,
        maximumByteCount: limits.maximumWorkbenchByteCount
      )
    }

    let stagedWorkbenchURL = stagingURL.appendingPathComponent("workbench.json")
    let stagedLastKnownGoodURL = stagingURL.appendingPathComponent("last-known-good.json")
    try restoredSnapshotData.write(to: stagedWorkbenchURL, options: .atomic)
    try restoredSnapshotData.write(to: stagedLastKnownGoodURL, options: .atomic)

    let stagedKnowledgeURL = stagingURL.appendingPathComponent(
      Self.knowledgePackageName,
      isDirectory: true
    )
    for record in validated.manifest.files where record.relativePath.hasPrefix(
      Self.knowledgePackageName + "/"
    ) {
      let relativePath = String(
        record.relativePath.dropFirst(Self.knowledgePackageName.count + 1)
      )
      let destination = stagedKnowledgeURL.appendingPathComponent(relativePath)
      let copiedRecord = try copyRegularFile(
        from: pendingURL.appendingPathComponent(record.relativePath),
        to: destination,
        relativePath: record.relativePath,
        component: record.component
      )
      guard copiedRecord == record else {
        throw WorkspaceBackupError.checksumMismatch(record.relativePath)
      }
    }
    do {
      _ = try KnowledgeLibraryBackupService(
        rootURL: stagedKnowledgeURL,
        fileManager: fileManager
      ).inspectBackup(at: stagedKnowledgeURL)
    } catch {
      throw WorkspaceBackupError.knowledgeLibraryInvalid(error.localizedDescription)
    }

    let stagedRSSDirectoryURL = stagingURL.appendingPathComponent(
      "RSSReader",
      isDirectory: true
    )
    let stagedRSSDatabaseURL = stagedRSSDirectoryURL.appendingPathComponent(
      RSSReaderBackupService.databaseFileName
    )
    if validated.manifest.formatVersion >= 2 {
      guard let rssRecord = validated.manifest.files.first(where: {
        $0.relativePath == Self.rssDatabaseRelativePath && $0.component == .rssReader
      }) else {
        throw WorkspaceBackupError.missingFile(Self.rssDatabaseRelativePath)
      }
      let copiedRecord = try copyRegularFile(
        from: pendingURL.appendingPathComponent(Self.rssDatabaseRelativePath),
        to: stagedRSSDatabaseURL,
        relativePath: Self.rssDatabaseRelativePath,
        component: .rssReader
      )
      guard copiedRecord == rssRecord else {
        throw WorkspaceBackupError.checksumMismatch(Self.rssDatabaseRelativePath)
      }
      do {
        _ = try RSSReaderBackupService(fileManager: fileManager).inspectBackup(
          at: stagedRSSDatabaseURL
        )
      } catch {
        throw WorkspaceBackupError.rssReaderInvalid(error.localizedDescription)
      }
    }

    let stagedAttachmentsURL = stagingURL.appendingPathComponent(
      "ManagedAttachments",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: stagedAttachmentsURL,
      withIntermediateDirectories: true
    )
    for reference in validated.manifest.attachmentReferences {
      let destination = stagedAttachmentsURL.appendingPathComponent(
        reference.restoredRelativePath
      )
      let record = validated.manifest.files.first {
        $0.relativePath == reference.archiveRelativePath
      }
      guard let record else {
        throw WorkspaceBackupError.invalidAttachmentReference(reference.marker)
      }
      let copiedRecord = try copyRegularFile(
        from: pendingURL.appendingPathComponent(record.relativePath),
        to: destination,
        relativePath: record.relativePath,
        component: record.component
      )
      guard copiedRecord == record else {
        throw WorkspaceBackupError.checksumMismatch(record.relativePath)
      }
    }

    let transaction = makeRestoreTransaction(
      transactionID: transactionID,
      includesRSS: validated.manifest.formatVersion >= 2,
      paths: runtimePaths
    )
    let recoveryRoot = restoreRecoveryRootURL(
      transactionID: transactionID,
      parentURL: parentURL
    )
    try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
    try encodeManifest(
      validated.manifest,
      to: recoveryRoot.appendingPathComponent("restored-manifest.json")
    )
    do {
      try writeRestoreTransaction(transaction, paths: runtimePaths)
    } catch {
      try? fileManager.removeItem(at: recoveryRoot)
      throw error
    }

    do {
      try restoreMutationHook(.transactionRecorded)
      let pendingRecoveryURL = restorePendingRecoveryURL(recoveryRoot: recoveryRoot)
      try fileManager.moveItem(at: pendingURL, to: pendingRecoveryURL)
      try restoreMutationHook(.pendingRestoreMoved)

      for item in transaction.items where item.existedBefore {
        let itemPaths = restoreItemPaths(
          for: item.kind,
          runtimePaths: runtimePaths,
          recoveryRoot: recoveryRoot
        )
        try moveRequiredItem(from: itemPaths.currentURL, to: itemPaths.recoveryURL)
      }
      try restoreMutationHook(.existingDataMoved)

      let lastKnownGoodURL = WorkbenchPersistence(fileURL: persistenceFileURL).lastKnownGoodURL
      try fileManager.createDirectory(
        at: persistenceFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try restoredSnapshotData.write(to: persistenceFileURL, options: .atomic)
      try restoredSnapshotData.write(to: lastKnownGoodURL, options: .atomic)

      try installDirectory(
        stagedKnowledgeURL,
        at: knowledgeRootURL
      )
      if validated.manifest.formatVersion >= 2 {
        try installDirectory(
          stagedRSSDirectoryURL,
          at: rssDatabaseURL.deletingLastPathComponent()
        )
      }
      try installDirectory(
        stagedAttachmentsURL,
        at: attachmentRootURL
      )
      try restoreMutationHook(.newDataInstalled)

      try fileManager.removeItem(at: recoveryRoot.appendingPathComponent("restored-manifest.json"))
      try? fileManager.removeItem(at: stagingURL)
      try fileManager.removeItem(at: restoreTransactionURL(for: persistenceFileURL))
      return WorkspaceBackupRestoreStartupResult(
        restoredPreview: validated.preview,
        recoveryURL: recoveryRoot
      )
    } catch let interruption as WorkspaceRestoreProcessInterruption {
      preserveStagingForSimulatedInterruption = true
      throw interruption
    } catch let restoreError {
      do {
        try rollbackRestoreTransaction(transaction, paths: runtimePaths)
      } catch let rollbackError {
        throw WorkspaceBackupError.restoreFailed(
          "\(restoreError.localizedDescription); \(rollbackError.localizedDescription)"
        )
      }
      throw WorkspaceBackupError.restoreFailed(restoreError.localizedDescription)
    }
  }

  private struct RestoreRuntimePaths: Sendable {
    var persistenceFileURL: URL
    var knowledgeRootURL: URL
    var rssDatabaseURL: URL
    var attachmentRootURL: URL
  }

  private enum RestoreItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workbench
    case lastKnownGood
    case draftRecoveryJournal
    case knowledgeLibrary
    case rssReader
    case managedAttachments
    case pendingKnowledgeRestore
  }

  private struct RestoreTransactionItem: Codable, Hashable, Sendable {
    var kind: RestoreItemKind
    var existedBefore: Bool
  }

  private struct RestoreTransaction: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var transactionID: UUID
    var includesRSS: Bool
    var items: [RestoreTransactionItem]
  }

  private struct RestoreItemPaths {
    var currentURL: URL
    var recoveryURL: URL
  }

  private func makeRestoreTransaction(
    transactionID: UUID,
    includesRSS: Bool,
    paths: RestoreRuntimePaths
  ) -> RestoreTransaction {
    var kinds: [RestoreItemKind] = [
      .workbench,
      .lastKnownGood,
      .draftRecoveryJournal,
      .knowledgeLibrary
    ]
    if includesRSS {
      kinds.append(.rssReader)
    }
    kinds.append(contentsOf: [.managedAttachments, .pendingKnowledgeRestore])
    let recoveryRoot = restoreRecoveryRootURL(
      transactionID: transactionID,
      parentURL: paths.persistenceFileURL.deletingLastPathComponent()
    )
    let items = kinds.map { kind in
      let itemPaths = restoreItemPaths(
        for: kind,
        runtimePaths: paths,
        recoveryRoot: recoveryRoot
      )
      return RestoreTransactionItem(
        kind: kind,
        existedBefore: fileManager.fileExists(atPath: itemPaths.currentURL.path)
      )
    }
    return RestoreTransaction(
      formatVersion: RestoreTransaction.currentFormatVersion,
      transactionID: transactionID,
      includesRSS: includesRSS,
      items: items
    )
  }

  private func rollbackInterruptedRestoreIfNeeded(
    paths: RestoreRuntimePaths
  ) throws -> Bool {
    let transactionURL = restoreTransactionURL(for: paths.persistenceFileURL)
    guard fileManager.fileExists(atPath: transactionURL.path) else { return false }
    let transaction = try readRestoreTransaction(at: transactionURL)
    try rollbackRestoreTransaction(transaction, paths: paths)
    return true
  }

  private func rollbackRestoreTransaction(
    _ transaction: RestoreTransaction,
    paths: RestoreRuntimePaths
  ) throws {
    try validateRestoreTransaction(transaction)
    let parentURL = paths.persistenceFileURL.deletingLastPathComponent()
    let recoveryRoot = restoreRecoveryRootURL(
      transactionID: transaction.transactionID,
      parentURL: parentURL
    )

    for item in transaction.items.reversed() {
      let itemPaths = restoreItemPaths(
        for: item.kind,
        runtimePaths: paths,
        recoveryRoot: recoveryRoot
      )
      let currentExists = fileManager.fileExists(atPath: itemPaths.currentURL.path)
      let recoveryExists = fileManager.fileExists(atPath: itemPaths.recoveryURL.path)

      if recoveryExists {
        guard item.existedBefore else {
          throw CocoaError(.fileReadCorruptFile)
        }
        if currentExists {
          try fileManager.removeItem(at: itemPaths.currentURL)
        }
        try fileManager.createDirectory(
          at: itemPaths.currentURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: itemPaths.recoveryURL, to: itemPaths.currentURL)
      } else if item.existedBefore {
        guard currentExists else {
          throw CocoaError(.fileNoSuchFile)
        }
      } else if currentExists {
        try fileManager.removeItem(at: itemPaths.currentURL)
      }
    }

    let pendingURL = Self.pendingRestoreURL(for: paths.persistenceFileURL)
    let pendingRecoveryURL = restorePendingRecoveryURL(recoveryRoot: recoveryRoot)
    let pendingExists = fileManager.fileExists(atPath: pendingURL.path)
    let pendingRecoveryExists = fileManager.fileExists(atPath: pendingRecoveryURL.path)
    if pendingRecoveryExists {
      guard !pendingExists else {
        throw CocoaError(.fileWriteFileExists)
      }
      try fileManager.moveItem(at: pendingRecoveryURL, to: pendingURL)
    } else if !pendingExists {
      throw CocoaError(.fileNoSuchFile)
    }

    let restoredManifestURL = recoveryRoot.appendingPathComponent("restored-manifest.json")
    if fileManager.fileExists(atPath: restoredManifestURL.path) {
      try fileManager.removeItem(at: restoredManifestURL)
    }
    let stagingURL = restoreStagingURL(
      transactionID: transaction.transactionID,
      parentURL: parentURL
    )
    if fileManager.fileExists(atPath: stagingURL.path) {
      try fileManager.removeItem(at: stagingURL)
    }
    if fileManager.fileExists(atPath: recoveryRoot.path),
       try fileManager.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty {
      try fileManager.removeItem(at: recoveryRoot)
    }
    try fileManager.removeItem(at: restoreTransactionURL(for: paths.persistenceFileURL))
  }

  private func writeRestoreTransaction(
    _ transaction: RestoreTransaction,
    paths: RestoreRuntimePaths
  ) throws {
    try validateRestoreTransaction(transaction)
    let transactionURL = restoreTransactionURL(for: paths.persistenceFileURL)
    guard !fileManager.fileExists(atPath: transactionURL.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(transaction).write(to: transactionURL, options: .atomic)
  }

  private func readRestoreTransaction(at transactionURL: URL) throws -> RestoreTransaction {
    let attributes = try fileManager.attributesOfItem(atPath: transactionURL.path)
    guard let size = attributes[.size] as? NSNumber,
          size.intValue <= 1_048_576 else {
      throw CocoaError(.fileReadTooLarge)
    }
    let transaction = try JSONDecoder().decode(
      RestoreTransaction.self,
      from: Data(contentsOf: transactionURL, options: .mappedIfSafe)
    )
    try validateRestoreTransaction(transaction)
    return transaction
  }

  private func validateRestoreTransaction(_ transaction: RestoreTransaction) throws {
    guard transaction.formatVersion == RestoreTransaction.currentFormatVersion else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var expectedKinds = Set(RestoreItemKind.allCases)
    if !transaction.includesRSS {
      expectedKinds.remove(.rssReader)
    }
    let actualKinds = transaction.items.map(\.kind)
    guard actualKinds.count == Set(actualKinds).count,
          Set(actualKinds) == expectedKinds else {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  private func restoreItemPaths(
    for kind: RestoreItemKind,
    runtimePaths: RestoreRuntimePaths,
    recoveryRoot: URL
  ) -> RestoreItemPaths {
    let persistence = WorkbenchPersistence(fileURL: runtimePaths.persistenceFileURL)
    switch kind {
    case .workbench:
      return RestoreItemPaths(
        currentURL: runtimePaths.persistenceFileURL,
        recoveryURL: recoveryRoot.appendingPathComponent("workbench.json")
      )
    case .lastKnownGood:
      return RestoreItemPaths(
        currentURL: persistence.lastKnownGoodURL,
        recoveryURL: recoveryRoot.appendingPathComponent("last-known-good.json")
      )
    case .draftRecoveryJournal:
      return RestoreItemPaths(
        currentURL: persistence.draftRecoveryJournalURL,
        recoveryURL: recoveryRoot.appendingPathComponent("draft-recovery.json")
      )
    case .knowledgeLibrary:
      return RestoreItemPaths(
        currentURL: runtimePaths.knowledgeRootURL,
        recoveryURL: recoveryRoot.appendingPathComponent("KnowledgeLibrary")
      )
    case .rssReader:
      return RestoreItemPaths(
        currentURL: runtimePaths.rssDatabaseURL.deletingLastPathComponent(),
        recoveryURL: recoveryRoot.appendingPathComponent("RSSReader")
      )
    case .managedAttachments:
      return RestoreItemPaths(
        currentURL: runtimePaths.attachmentRootURL,
        recoveryURL: recoveryRoot.appendingPathComponent("ManagedAttachments")
      )
    case .pendingKnowledgeRestore:
      return RestoreItemPaths(
        currentURL: KnowledgeLibraryBackupService.pendingRestoreURL(
          for: runtimePaths.knowledgeRootURL
        ),
        recoveryURL: recoveryRoot.appendingPathComponent(
          "superseded-knowledge-pending.pslibrarybackup"
        )
      )
    }
  }

  private func restoreTransactionURL(for persistenceFileURL: URL) -> URL {
    persistenceFileURL.deletingLastPathComponent().appendingPathComponent(
      Self.restoreTransactionFileName,
      isDirectory: false
    )
  }

  private func restoreStagingURL(transactionID: UUID, parentURL: URL) -> URL {
    parentURL.appendingPathComponent(
      ".WorkspaceBackupApplying-\(transactionID.uuidString.lowercased())",
      isDirectory: true
    )
  }

  private func restoreRecoveryRootURL(transactionID: UUID, parentURL: URL) -> URL {
    parentURL
      .appendingPathComponent("WorkspaceBackupRecovery", isDirectory: true)
      .appendingPathComponent(
        "BeforeRestore-\(transactionID.uuidString.lowercased())",
        isDirectory: true
      )
  }

  private func restorePendingRecoveryURL(recoveryRoot: URL) -> URL {
    recoveryRoot.appendingPathComponent(
      "source.psworkspacebackup",
      isDirectory: true
    )
  }

  private func moveRequiredItem(from currentURL: URL, to recoveryURL: URL) throws {
    guard fileManager.fileExists(atPath: currentURL.path),
          !fileManager.fileExists(atPath: recoveryURL.path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    try fileManager.createDirectory(
      at: recoveryURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.moveItem(at: currentURL, to: recoveryURL)
  }

  private struct PreparedAttachmentReference {
    var reference: WorkspaceBackupAttachmentReference
    var sourceURL: URL
  }

  private struct PreparedAttachmentSnapshot {
    var snapshot: WorkbenchSnapshot
    var references: [PreparedAttachmentReference]
    var unresolvedAttachmentCount: Int
  }

  private struct ValidatedBackup {
    var manifest: WorkspaceBackupManifest
    var snapshot: WorkbenchSnapshot
    var preview: WorkspaceBackupPreview
  }

  private func prepareAttachmentSnapshot(
    _ originalSnapshot: WorkbenchSnapshot
  ) throws -> PreparedAttachmentSnapshot {
    var sourceURLsByPath: [String: URL] = [:]
    var unresolvedAttachmentCount = 0
    for attachment in allAttachments(in: originalSnapshot) {
      guard let sourcePath = attachment.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sourcePath.isEmpty else {
        unresolvedAttachmentCount += 1
        continue
      }
      guard !sourcePath.hasPrefix(Self.attachmentMarkerPrefix) else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
      let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
      let values = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw WorkspaceBackupError.attachmentSourceUnavailable(sourcePath)
      }
      sourceURLsByPath[sourceURL.path] = sourceURL
    }

    var references: [PreparedAttachmentReference] = []
    var referenceByPath: [String: WorkspaceBackupAttachmentReference] = [:]
    for sourceURL in sourceURLsByPath.values.sorted(by: { $0.path < $1.path }) {
      let digest = SHA256.hash(data: Data(sourceURL.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
      let identifier = String(digest.prefix(32))
      let filename = safeFilename(sourceURL.lastPathComponent, fallback: "attachment")
      let reference = WorkspaceBackupAttachmentReference(
        marker: Self.attachmentMarkerPrefix + identifier,
        archiveRelativePath: "\(Self.attachmentsDirectoryName)/\(identifier)-\(filename)",
        restoredRelativePath: "WorkspaceBackup/\(identifier)-\(filename)"
      )
      references.append(
        PreparedAttachmentReference(reference: reference, sourceURL: sourceURL)
      )
      referenceByPath[sourceURL.path] = reference
    }

    var sanitizedSnapshot = originalSnapshot
    sanitizedSnapshot.drafts = try sanitizedSnapshot.drafts.map {
      try sanitizedDraft($0, referenceByPath: referenceByPath)
    }
    sanitizedSnapshot.recycledDrafts = try sanitizedSnapshot.recycledDrafts.map { recycled in
      var copy = recycled
      copy.draft = try sanitizedDraft(copy.draft, referenceByPath: referenceByPath)
      return copy
    }
    sanitizedSnapshot.draftVersions = try sanitizedSnapshot.draftVersions.map { version in
      var copy = version
      copy.draft = try sanitizedDraft(copy.draft, referenceByPath: referenceByPath)
      return copy
    }
    return PreparedAttachmentSnapshot(
      snapshot: sanitizedSnapshot,
      references: references,
      unresolvedAttachmentCount: unresolvedAttachmentCount
    )
  }

  private func sanitizedDraft(
    _ draft: ArticleDraft,
    referenceByPath: [String: WorkspaceBackupAttachmentReference]
  ) throws -> ArticleDraft {
    var copy = draft
    for index in copy.attachments.indices {
      guard let sourcePath = copy.attachments[index].sourceFilePath?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !sourcePath.isEmpty else {
        continue
      }
      let key = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
      guard let reference = referenceByPath[key] else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
      copy.attachments[index].sourceFilePath = reference.marker
    }
    return copy
  }

  private func restoredSnapshot(
    _ originalSnapshot: WorkbenchSnapshot,
    references: [WorkspaceBackupAttachmentReference],
    attachmentRootURL: URL
  ) throws -> WorkbenchSnapshot {
    let referencesByMarker = Dictionary(uniqueKeysWithValues: references.map { ($0.marker, $0) })
    var snapshot = originalSnapshot
    snapshot.drafts = try snapshot.drafts.map {
      try restoredDraft($0, referencesByMarker: referencesByMarker, attachmentRootURL: attachmentRootURL)
    }
    snapshot.recycledDrafts = try snapshot.recycledDrafts.map { recycled in
      var copy = recycled
      copy.draft = try restoredDraft(
        copy.draft,
        referencesByMarker: referencesByMarker,
        attachmentRootURL: attachmentRootURL
      )
      return copy
    }
    snapshot.draftVersions = try snapshot.draftVersions.map { version in
      var copy = version
      copy.draft = try restoredDraft(
        copy.draft,
        referencesByMarker: referencesByMarker,
        attachmentRootURL: attachmentRootURL
      )
      return copy
    }
    return snapshot
  }

  private func restoredDraft(
    _ draft: ArticleDraft,
    referencesByMarker: [String: WorkspaceBackupAttachmentReference],
    attachmentRootURL: URL
  ) throws -> ArticleDraft {
    var copy = draft
    for index in copy.attachments.indices {
      guard let sourcePath = copy.attachments[index].sourceFilePath,
            !sourcePath.isEmpty else {
        continue
      }
      guard let reference = referencesByMarker[sourcePath] else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
      copy.attachments[index].sourceFilePath = attachmentRootURL
        .appendingPathComponent(reference.restoredRelativePath)
        .standardizedFileURL
        .path
    }
    return copy
  }

  private func allAttachments(in snapshot: WorkbenchSnapshot) -> [DraftAttachment] {
    snapshot.drafts.flatMap(\.attachments)
      + snapshot.recycledDrafts.flatMap { $0.draft.attachments }
      + snapshot.draftVersions.flatMap { $0.draft.attachments }
  }

  private func validatedBackup(
    at packageURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> ValidatedBackup {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw WorkspaceBackupError.sourceUnavailable(packageURL.path)
    }
    let packageValues = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard packageValues.isSymbolicLink != true else {
      throw WorkspaceBackupError.invalidPath(packageURL.path)
    }

    let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
    let manifestData = try boundedData(
      at: manifestURL,
      maximumByteCount: limits.maximumManifestByteCount,
      relativePath: Self.manifestFileName
    )
    let manifest: WorkspaceBackupManifest
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      manifest = try decoder.decode(WorkspaceBackupManifest.self, from: manifestData)
    } catch {
      throw WorkspaceBackupError.invalidManifest(error.localizedDescription)
    }
    guard manifest.formatVersion >= WorkspaceBackupManifest.minimumSupportedFormatVersion,
          manifest.formatVersion <= WorkspaceBackupManifest.currentFormatVersion else {
      throw WorkspaceBackupError.unsupportedFormat(manifest.formatVersion)
    }
    guard !manifest.includesAPIKeys else {
      throw WorkspaceBackupError.apiKeysNotAllowed
    }
    guard manifest.fileCount == manifest.files.count else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("文件数量与清单不一致"))
    }
    guard manifest.attachmentReferenceCount == manifest.attachmentReferences.count else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("附件引用数量与清单不一致")
      )
    }

    var seenPaths = Set<String>()
    for record in manifest.files {
      try validateRelativePath(record.relativePath)
      guard seenPaths.insert(record.relativePath).inserted else {
        throw WorkspaceBackupError.invalidManifest(
          CoreL10n.format("文件路径重复：%@", record.relativePath)
        )
      }
      guard component(for: record.relativePath) == record.component else {
        throw WorkspaceBackupError.invalidManifest(
          CoreL10n.format("组件与文件路径不一致：%@", record.relativePath)
        )
      }
      let actual = try fileRecord(
        relativePath: record.relativePath,
        component: record.component,
        under: packageURL
      )
      guard actual.sha256 == record.sha256.lowercased() else {
        throw WorkspaceBackupError.checksumMismatch(record.relativePath)
      }
      guard actual.byteCount == record.byteCount else {
        throw WorkspaceBackupError.fileSizeMismatch(record.relativePath)
      }
    }
    let declaredTotalByteCount = try validateFileLimits(manifest.files)
    guard declaredTotalByteCount == manifest.totalByteCount else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("总大小与文件清单不一致"))
    }
    let actualPaths = try regularFilePaths(in: packageURL).filter {
      $0 != Self.manifestFileName
    }
    guard Set(actualPaths) == seenPaths else {
      let missing = seenPaths.subtracting(actualPaths).sorted()
      let extra = Set(actualPaths).subtracting(seenPaths).sorted()
      let missingSummary = missing.joined(separator: ", ").nilIfEmpty ?? CoreL10n.text("无")
      let extraSummary = extra.joined(separator: ", ").nilIfEmpty ?? CoreL10n.text("无")
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.format(
          "实际文件与清单不同；缺少 %@，多出 %@",
          missingSummary,
          extraSummary
        )
      )
    }
    guard manifest.components == componentSummaries(
      for: manifest.files,
      formatVersion: manifest.formatVersion
    ) else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("组件统计与文件清单不一致")
      )
    }

    let workbenchData = try boundedData(
      at: packageURL.appendingPathComponent(Self.workbenchRelativePath),
      maximumByteCount: Int(limits.maximumWorkbenchByteCount),
      relativePath: Self.workbenchRelativePath
    )
    let snapshot: WorkbenchSnapshot
    do {
      snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: workbenchData)
      try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    } catch {
      throw WorkspaceBackupError.invalidWorkbenchSnapshot(error.localizedDescription)
    }
    try validateAttachmentReferences(
      in: snapshot,
      references: manifest.attachmentReferences,
      files: manifest.files
    )
    guard manifest.profileCount == snapshot.profiles.count,
          manifest.draftCount == snapshot.drafts.count,
          manifest.draftVersionCount == snapshot.draftVersions.count,
          manifest.releaseRecordCount == snapshot.releaseRecords.count,
          manifest.unresolvedAttachmentCount == unresolvedAttachmentCount(in: snapshot)
    else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("工作区数据统计与快照不一致")
      )
    }

    let knowledgeURL = packageURL.appendingPathComponent(Self.knowledgePackageName)
    do {
      _ = try KnowledgeLibraryBackupService(
        rootURL: knowledgeURL,
        fileManager: fileManager
      ).inspectBackup(at: knowledgeURL)
    } catch {
      throw WorkspaceBackupError.knowledgeLibraryInvalid(error.localizedDescription)
    }

    if manifest.formatVersion >= 2 {
      do {
        _ = try RSSReaderBackupService(fileManager: fileManager).inspectBackup(
          at: packageURL.appendingPathComponent(Self.rssDatabaseRelativePath)
        )
      } catch {
        throw WorkspaceBackupError.rssReaderInvalid(error.localizedDescription)
      }
    }

    let preview = WorkspaceBackupPreview(
      backupURL: packageURL,
      createdAt: manifest.createdAt,
      applicationVersion: manifest.applicationVersion,
      formatVersion: manifest.formatVersion,
      compatibility: compatibility(
        backupApplicationVersion: manifest.applicationVersion,
        currentApplicationVersion: currentApplicationVersion
      ),
      includesAPIKeys: manifest.includesAPIKeys,
      profileCount: manifest.profileCount,
      draftCount: manifest.draftCount,
      draftVersionCount: manifest.draftVersionCount,
      releaseRecordCount: manifest.releaseRecordCount,
      attachmentReferenceCount: manifest.attachmentReferenceCount,
      unresolvedAttachmentCount: manifest.unresolvedAttachmentCount,
      components: manifest.components,
      fileCount: manifest.fileCount,
      totalByteCount: manifest.totalByteCount
    )
    return ValidatedBackup(manifest: manifest, snapshot: snapshot, preview: preview)
  }

  private func compatibility(
    backupApplicationVersion: String,
    currentApplicationVersion: String?
  ) -> WorkspaceBackupCompatibility {
    guard let currentApplicationVersion,
          let backupComponents = versionComponents(backupApplicationVersion),
          let currentComponents = versionComponents(currentApplicationVersion) else {
      return .unknownApplicationVersion
    }
    if backupComponents == currentComponents {
      return .compatible
    }
    return backupComponents.lexicographicallyPrecedes(currentComponents)
      ? .createdByOlderApplication
      : .createdByNewerApplication
  }

  private func versionComponents(_ rawVersion: String) -> [Int]? {
    let components = rawVersion.split { character in
      !character.isNumber
    }
    let numbers = components.compactMap { Int($0) }
    guard !numbers.isEmpty else {
      return nil
    }
    var normalized = numbers
    while normalized.last == 0, normalized.count > 1 {
      normalized.removeLast()
    }
    return normalized
  }

  private func validateAttachmentReferences(
    in snapshot: WorkbenchSnapshot,
    references: [WorkspaceBackupAttachmentReference],
    files: [WorkspaceBackupFileRecord]
  ) throws {
    var markers = Set<String>()
    var archivePaths = Set<String>()
    var restoredPaths = Set<String>()
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
    for reference in references {
      guard reference.marker.hasPrefix(Self.attachmentMarkerPrefix),
            reference.marker.dropFirst(Self.attachmentMarkerPrefix.count).isEmpty == false,
            markers.insert(reference.marker).inserted else {
        throw WorkspaceBackupError.invalidAttachmentReference(reference.marker)
      }
      try validateRelativePath(reference.archiveRelativePath)
      try validateRelativePath(reference.restoredRelativePath)
      guard reference.archiveRelativePath.hasPrefix(Self.attachmentsDirectoryName + "/"),
            reference.restoredRelativePath.hasPrefix("WorkspaceBackup/"),
            filesByPath[reference.archiveRelativePath]?.component == .draftAttachments,
            archivePaths.insert(reference.archiveRelativePath).inserted,
            restoredPaths.insert(reference.restoredRelativePath).inserted else {
        throw WorkspaceBackupError.invalidAttachmentReference(reference.marker)
      }
    }
    for attachment in allAttachments(in: snapshot) {
      guard let sourcePath = attachment.sourceFilePath,
            !sourcePath.isEmpty else {
        continue
      }
      guard sourcePath.hasPrefix(Self.attachmentMarkerPrefix),
            markers.contains(sourcePath) else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
    }
  }

  private func unresolvedAttachmentCount(in snapshot: WorkbenchSnapshot) -> Int {
    allAttachments(in: snapshot).reduce(into: 0) { count, attachment in
      guard let sourcePath = attachment.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sourcePath.isEmpty else {
        count += 1
        return
      }
    }
  }

  private func component(for relativePath: String) -> WorkspaceBackupComponent? {
    if relativePath == Self.workbenchRelativePath { return .workbenchState }
    if relativePath.hasPrefix(Self.attachmentsDirectoryName + "/") {
      return .draftAttachments
    }
    if relativePath.hasPrefix(Self.knowledgePackageName + "/") {
      return .knowledgeLibrary
    }
    if relativePath == Self.rssDatabaseRelativePath {
      return .rssReader
    }
    return nil
  }

  private func componentSummaries(
    for records: [WorkspaceBackupFileRecord],
    formatVersion: Int
  ) -> [WorkspaceBackupComponentSummary] {
    let components = WorkspaceBackupComponent.allCases.filter { component in
      formatVersion >= 2 || component != .rssReader
    }
    return components.map { component in
      let matching = records.filter { $0.component == component }
      return WorkspaceBackupComponentSummary(
        component: component,
        fileCount: matching.count,
        byteCount: matching.reduce(0) { $0 + $1.byteCount }
      )
    }
  }

  private func recordsInDirectory(
    _ directoryURL: URL,
    relativePrefix: String,
    component: WorkspaceBackupComponent,
    under rootURL: URL
  ) throws -> [WorkspaceBackupFileRecord] {
    let files = try regularFileURLs(in: directoryURL)
    return try files.map { fileURL in
      let relativePath = try relativePath(of: fileURL, under: rootURL)
      guard relativePath.hasPrefix(relativePrefix + "/") else {
        throw WorkspaceBackupError.invalidPath(relativePath)
      }
      return try fileRecord(
        relativePath: relativePath,
        component: component,
        under: rootURL
      )
    }
  }

  private func regularFilePaths(in directoryURL: URL) throws -> [String] {
    try regularFileURLs(in: directoryURL).map {
      try relativePath(of: $0, under: directoryURL)
    }
  }

  private func regularFileURLs(in directoryURL: URL) throws -> [URL] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      throw WorkspaceBackupError.sourceUnavailable(directoryURL.path)
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true else {
        throw WorkspaceBackupError.invalidPath(url.path)
      }
      if values.isDirectory == true { continue }
      guard values.isRegularFile == true else {
        throw WorkspaceBackupError.invalidPath(url.path)
      }
      files.append(url)
    }
    return files.sorted { $0.path < $1.path }
  }

  private func relativePath(of fileURL: URL, under rootURL: URL) throws -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else {
      throw WorkspaceBackupError.invalidPath(filePath)
    }
    let relativePath = String(filePath.dropFirst(prefix.count))
    try validateRelativePath(relativePath)
    return relativePath
  }

  private func validateRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          !path.contains("\0"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw WorkspaceBackupError.invalidPath(path)
    }
  }

  private func fileRecord(
    relativePath: String,
    component: WorkspaceBackupComponent,
    under rootURL: URL
  ) throws -> WorkspaceBackupFileRecord {
    try validateRelativePath(relativePath)
    let url = rootURL.appendingPathComponent(relativePath)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    let byteCount = try fileSize(of: url, relativePath: relativePath)
    guard byteCount <= limits.maximumSingleFileByteCount else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: limits.maximumSingleFileByteCount
      )
    }
    return WorkspaceBackupFileRecord(
      relativePath: relativePath,
      component: component,
      byteCount: byteCount,
      sha256: try sha256(of: url, relativePath: relativePath)
    )
  }

  private func copyRegularFile(
    from sourceURL: URL,
    to destinationURL: URL,
    relativePath: String,
    component: WorkspaceBackupComponent
  ) throws -> WorkspaceBackupFileRecord {
    try validateRelativePath(relativePath)
    let sourceValues = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    let sourceSize = try fileSize(of: sourceURL, relativePath: relativePath)
    guard sourceSize <= limits.maximumSingleFileByteCount else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: limits.maximumSingleFileByteCount
      )
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw WorkspaceBackupError.invalidPath(relativePath)
    }
    do {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      let actualSize = try fileSize(of: destinationURL, relativePath: relativePath)
      let actualDigest = try sha256(of: destinationURL, relativePath: relativePath)
      guard actualSize == sourceSize else {
        throw WorkspaceBackupError.fileSizeMismatch(relativePath)
      }
      return WorkspaceBackupFileRecord(
        relativePath: relativePath,
        component: component,
        byteCount: actualSize,
        sha256: actualDigest
      )
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  private func fileSize(of url: URL, relativePath: String) throws -> Int64 {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    guard let number = attributes[.size] as? NSNumber else {
      throw WorkspaceBackupError.invalidPath(relativePath)
    }
    return number.int64Value
  }

  private func sha256(of url: URL, relativePath: String) throws -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    var totalByteCount: Int64 = 0
    while true {
      let data = handle.readData(ofLength: 1_048_576)
      if data.isEmpty { break }
      totalByteCount += Int64(data.count)
      guard totalByteCount <= limits.maximumSingleFileByteCount else {
        throw WorkspaceBackupError.fileTooLarge(
          path: relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func boundedData(
    at url: URL,
    maximumByteCount: Int,
    relativePath: String
  ) throws -> Data {
    let size = try fileSize(of: url, relativePath: relativePath)
    guard size <= Int64(maximumByteCount) else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: Int64(maximumByteCount)
      )
    }
    do {
      return try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
  }

  private func validateFileLimits(_ records: [WorkspaceBackupFileRecord]) throws -> Int64 {
    guard records.count <= limits.maximumFileCount else {
      throw WorkspaceBackupError.tooManyFiles(maximumCount: limits.maximumFileCount)
    }
    var totalByteCount: Int64 = 0
    for record in records {
      guard record.byteCount >= 0,
            record.byteCount <= limits.maximumSingleFileByteCount else {
        throw WorkspaceBackupError.fileTooLarge(
          path: record.relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      let addition = totalByteCount.addingReportingOverflow(record.byteCount)
      guard !addition.overflow,
            addition.partialValue <= limits.maximumTotalByteCount else {
        throw WorkspaceBackupError.backupTooLarge(
          maximumByteCount: limits.maximumTotalByteCount
        )
      }
      totalByteCount = addition.partialValue
    }
    return totalByteCount
  }

  private func encodeManifest(
    _ manifest: WorkspaceBackupManifest,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: url, options: .atomic)
  }

  private func encodedWorkbenchSnapshot(_ snapshot: WorkbenchSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }

  private func normalizedPackageURL(_ url: URL) -> URL {
    guard url.pathExtension.lowercased() == "psworkspacebackup" else {
      return url.appendingPathExtension("psworkspacebackup")
    }
    return url
  }

  private func safeFilename(_ raw: String, fallback: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
      .union(.controlCharacters)
    let sanitized = raw
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((sanitized.nilIfEmpty ?? fallback).prefix(160))
  }

  private func installDirectory(
    _ stagedURL: URL,
    at destinationURL: URL
  ) throws {
    guard fileManager.fileExists(atPath: stagedURL.path) else { return }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.moveItem(at: stagedURL, to: destinationURL)
  }

  private func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      let displacedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
        ".\(destinationURL.lastPathComponent).replaced-\(UUID().uuidString)",
        isDirectory: true
      )
      try fileManager.moveItem(at: destinationURL, to: displacedURL)
      do {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try? fileManager.removeItem(at: displacedURL)
      } catch {
        if !fileManager.fileExists(atPath: destinationURL.path) {
          try? fileManager.moveItem(at: displacedURL, to: destinationURL)
        }
        throw error
      }
      return
    }
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
}
