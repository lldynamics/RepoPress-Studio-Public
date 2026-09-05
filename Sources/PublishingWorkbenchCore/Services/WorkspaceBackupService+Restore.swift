import CryptoKit
import Foundation

extension WorkspaceBackupService {
  func applyPendingRestore(
    persistenceFileURL: URL,
    knowledgeRootURL: URL,
    rssDatabaseURL: URL,
    attachmentRootURL: URL,
    currentApplicationVersion: String?
  ) throws -> WorkspaceBackupRestoreStartupResult? {
    try Task.checkCancellation()
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
    try Task.checkCancellation()
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

    let restoredOperationHistoryData: Data?
    if validated.manifest.formatVersion >= 3 {
      let data = try boundedData(
        at: pendingURL.appendingPathComponent(Self.operationHistoryRelativePath),
        maximumByteCount: WorkbenchOperationLedgerPersistence.maximumLedgerByteCount,
        relativePath: Self.operationHistoryRelativePath
      )
      _ = try WorkbenchOperationLedgerPersistence.decodedDocument(from: data)
      restoredOperationHistoryData = data
    } else {
      restoredOperationHistoryData = nil
    }

    let stagedKnowledgeURL = stagingURL.appendingPathComponent(
      Self.knowledgePackageName,
      isDirectory: true
    )
    for record in validated.manifest.files where record.relativePath.hasPrefix(
      Self.knowledgePackageName + "/"
    ) {
      try Task.checkCancellation()
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
    let includesRSS = validated.manifest.files.contains {
      $0.relativePath == Self.rssDatabaseRelativePath && $0.component == .rssReader
    }
    if includesRSS {
      try Task.checkCancellation()
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
      for record in validated.manifest.files where record.relativePath.hasPrefix(
        Self.rssMediaRelativePrefix + "/"
      ) {
        try Task.checkCancellation()
        let relativePath = String(
          record.relativePath.dropFirst(Self.rssMediaRelativePrefix.count + 1)
        )
        let destinationURL = stagedRSSDirectoryURL
          .appendingPathComponent("RSSMedia", isDirectory: true)
          .appendingPathComponent(relativePath)
        let copiedRecord = try copyRegularFile(
          from: pendingURL.appendingPathComponent(record.relativePath),
          to: destinationURL,
          relativePath: record.relativePath,
          component: .rssReader
        )
        guard copiedRecord == record else {
          throw WorkspaceBackupError.checksumMismatch(record.relativePath)
        }
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
      try Task.checkCancellation()
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
      includesRSS: includesRSS,
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
      do {
        try fileManager.removeItem(at: recoveryRoot)
      } catch let cleanupError {
        throw WorkspaceBackupError.restoreFailed(
          "恢复事务写入失败：\(error.localizedDescription)；恢复目录清理失败：\(cleanupError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try Task.checkCancellation()
      try restoreMutationHook(.transactionRecorded)
      let pendingRecoveryURL = restorePendingRecoveryURL(recoveryRoot: recoveryRoot)
      try fileManager.moveItem(at: pendingURL, to: pendingRecoveryURL)
      try restoreMutationHook(.pendingRestoreMoved)

      for item in transaction.items where item.existedBefore {
        try Task.checkCancellation()
        let itemPaths = restoreItemPaths(
          for: item.kind,
          runtimePaths: runtimePaths,
          recoveryRoot: recoveryRoot
        )
        try moveRequiredItem(from: itemPaths.currentURL, to: itemPaths.recoveryURL)
      }
      try restoreMutationHook(.existingDataMoved)
      try Task.checkCancellation()

      let lastKnownGoodURL = WorkbenchPersistence(fileURL: persistenceFileURL).lastKnownGoodURL
      try fileManager.createDirectory(
        at: persistenceFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try restoredSnapshotData.write(to: persistenceFileURL, options: .atomic)
      try restoredSnapshotData.write(to: lastKnownGoodURL, options: .atomic)
      if let restoredOperationHistoryData {
        let operationLedger = WorkbenchOperationLedgerPersistence(
          fileURL: WorkbenchPersistence(fileURL: persistenceFileURL).operationLedgerURL
        )
        try restoredOperationHistoryData.write(to: operationLedger.fileURL, options: .atomic)
        try restoredOperationHistoryData.write(
          to: operationLedger.lastKnownGoodURL,
          options: .atomic
        )
      }

      try installDirectory(
        stagedKnowledgeURL,
        at: knowledgeRootURL
      )
      if includesRSS {
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
      try fileManager.removeItem(at: stagingURL)
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

  struct RestoreRuntimePaths: Sendable {
    var persistenceFileURL: URL
    var knowledgeRootURL: URL
    var rssDatabaseURL: URL
    var attachmentRootURL: URL
  }

  enum RestoreItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workbench
    case lastKnownGood
    case draftRecoveryJournal
    case operationLedger
    case operationLedgerLastKnownGood
    case knowledgeLibrary
    case rssReader
    case managedAttachments
    case pendingKnowledgeRestore
  }

  struct RestoreTransactionItem: Codable, Hashable, Sendable {
    var kind: RestoreItemKind
    var existedBefore: Bool
  }

  struct RestoreTransaction: Codable, Hashable, Sendable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var transactionID: UUID
    var includesRSS: Bool
    var items: [RestoreTransactionItem]
  }

  struct RestoreItemPaths {
    var currentURL: URL
    var recoveryURL: URL
  }

  func makeRestoreTransaction(
    transactionID: UUID,
    includesRSS: Bool,
    paths: RestoreRuntimePaths
  ) -> RestoreTransaction {
    var kinds: [RestoreItemKind] = [
      .workbench,
      .lastKnownGood,
      .draftRecoveryJournal,
      .operationLedger,
      .operationLedgerLastKnownGood,
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

  func rollbackInterruptedRestoreIfNeeded(
    paths: RestoreRuntimePaths
  ) throws -> Bool {
    let transactionURL = restoreTransactionURL(for: paths.persistenceFileURL)
    guard fileManager.fileExists(atPath: transactionURL.path) else { return false }
    let transaction = try readRestoreTransaction(at: transactionURL)
    try rollbackRestoreTransaction(transaction, paths: paths)
    return true
  }

  func rollbackRestoreTransaction(
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

  func writeRestoreTransaction(
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

  func readRestoreTransaction(at transactionURL: URL) throws -> RestoreTransaction {
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

  func validateRestoreTransaction(_ transaction: RestoreTransaction) throws {
    guard (1...RestoreTransaction.currentFormatVersion).contains(transaction.formatVersion) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var expectedKinds = Set(RestoreItemKind.allCases)
    if transaction.formatVersion == 1 {
      expectedKinds.remove(.operationLedger)
      expectedKinds.remove(.operationLedgerLastKnownGood)
    }
    if !transaction.includesRSS {
      expectedKinds.remove(.rssReader)
    }
    let actualKinds = transaction.items.map(\.kind)
    guard actualKinds.count == Set(actualKinds).count,
          Set(actualKinds) == expectedKinds else {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  func restoreItemPaths(
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
    case .operationLedger:
      return RestoreItemPaths(
        currentURL: persistence.operationLedgerURL,
        recoveryURL: recoveryRoot.appendingPathComponent("operation-log.json")
      )
    case .operationLedgerLastKnownGood:
      let ledgerPersistence = WorkbenchOperationLedgerPersistence(
        fileURL: persistence.operationLedgerURL
      )
      return RestoreItemPaths(
        currentURL: ledgerPersistence.lastKnownGoodURL,
        recoveryURL: recoveryRoot.appendingPathComponent("operation-log-last-known-good.json")
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

  func restoreTransactionURL(for persistenceFileURL: URL) -> URL {
    persistenceFileURL.deletingLastPathComponent().appendingPathComponent(
      Self.restoreTransactionFileName,
      isDirectory: false
    )
  }

  func restoreStagingURL(transactionID: UUID, parentURL: URL) -> URL {
    parentURL.appendingPathComponent(
      ".WorkspaceBackupApplying-\(transactionID.uuidString.lowercased())",
      isDirectory: true
    )
  }

  func restoreRecoveryRootURL(transactionID: UUID, parentURL: URL) -> URL {
    parentURL
      .appendingPathComponent("WorkspaceBackupRecovery", isDirectory: true)
      .appendingPathComponent(
        "BeforeRestore-\(transactionID.uuidString.lowercased())",
        isDirectory: true
      )
  }

  func restorePendingRecoveryURL(recoveryRoot: URL) -> URL {
    recoveryRoot.appendingPathComponent(
      "source.psworkspacebackup",
      isDirectory: true
    )
  }

  func moveRequiredItem(from currentURL: URL, to recoveryURL: URL) throws {
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

  struct PreparedAttachmentReference {
    var reference: WorkspaceBackupAttachmentReference
    var sourceURL: URL
  }

  struct PreparedAttachmentSnapshot {
    var snapshot: WorkbenchSnapshot
    var references: [PreparedAttachmentReference]
    var unresolvedAttachmentCount: Int
  }

  struct ValidatedBackup {
    var manifest: WorkspaceBackupManifest
    var snapshot: WorkbenchSnapshot
    var preview: WorkspaceBackupPreview
  }

  func prepareAttachmentSnapshot(
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

  func sanitizedDraft(
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

  func restoredSnapshot(
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

  func restoredDraft(
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

  func allAttachments(in snapshot: WorkbenchSnapshot) -> [DraftAttachment] {
    snapshot.drafts.flatMap(\.attachments)
      + snapshot.recycledDrafts.flatMap { $0.draft.attachments }
      + snapshot.draftVersions.flatMap { $0.draft.attachments }
  }
}
