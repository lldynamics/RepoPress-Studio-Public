import CryptoKit
import Foundation
import PublishingBackupCore
import PublishingDomainContracts

extension WorkspaceBackupService {
  /// A remaining journal owns the live files until rollback completes. Check
  /// attributes rather than fileExists so an unreadable journal fails closed.
  public static func hasUnfinishedRestoreTransaction(persistenceFileURL: URL) throws -> Bool {
    let url = WorkspaceBackupService().restoreTransactionURL(for: persistenceFileURL)
    do {
      _ = try FileManager.default.attributesOfItem(atPath: url.path)
      return true
    } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      return false
    }
  }

  /// Stages a merged archive tree before a restore transaction can replace the
  /// live directory. Any live/backup name collision with different bytes
  /// fails while the live directory is still untouched.
  func prepareMergedRetiredFeatureArchives(
    records: [WorkspaceBackupFileRecord],
    backupURL: URL,
    existingDirectoryURL: URL,
    stagingDirectoryURL: URL
  ) throws {
    var recordByRelativePath: [String: WorkspaceBackupFileRecord] = [:]
    for record in records {
      guard recordByRelativePath.updateValue(record, forKey: record.relativePath) == nil else {
        throw WorkspaceBackupError.invalidManifest(CoreL10n.text("退役归档路径重复"))
      }
    }

    var mergedRecords = [WorkspaceBackupFileRecord]()
    for existingURL in try regularFileURLs(in: existingDirectoryURL) {
      try Task.checkCancellation()
      let relativePath = try relativePath(of: existingURL, under: existingDirectoryURL)
      let archiveRelativePath = Self.retiredFeatureArchivesRelativePrefix + "/" + relativePath
      let existingRecord = WorkspaceBackupFileRecord(
        relativePath: archiveRelativePath,
        component: .workbenchState,
        byteCount: try fileSize(of: existingURL, relativePath: archiveRelativePath),
        sha256: try sha256(of: existingURL, relativePath: archiveRelativePath)
      )
      if let backupRecord = recordByRelativePath[archiveRelativePath],
        backupRecord != existingRecord
      {
        throw WorkspaceBackupError.restoreFailed(
          CoreL10n.format("退役归档文件冲突，已保留原文件：%@", archiveRelativePath)
        )
      }
      let copied = try copyRegularFile(
        from: existingURL,
        to: stagingDirectoryURL.appendingPathComponent(relativePath),
        relativePath: archiveRelativePath,
        component: .workbenchState
      )
      guard copied == existingRecord else {
        throw WorkspaceBackupError.checksumMismatch(archiveRelativePath)
      }
      mergedRecords.append(existingRecord)
    }

    for record in records
    where !fileManager.fileExists(
      atPath: stagingDirectoryURL.appendingPathComponent(
        String(record.relativePath.dropFirst(Self.retiredFeatureArchivesRelativePrefix.count + 1))
      ).path
    ) {
      try Task.checkCancellation()
      let relativePath = String(
        record.relativePath.dropFirst(
          Self.retiredFeatureArchivesRelativePrefix.count + 1
        ))
      let copied = try copyRegularFile(
        from: backupURL.appendingPathComponent(record.relativePath),
        to: stagingDirectoryURL.appendingPathComponent(relativePath),
        relativePath: record.relativePath,
        component: .workbenchState
      )
      guard copied == record else {
        throw WorkspaceBackupError.checksumMismatch(record.relativePath)
      }
      mergedRecords.append(record)
    }
    _ = try validateFileLimits(mergedRecords)
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
    var snapshot: WorkbenchSnapshot?
    var preview: WorkspaceBackupPreview
  }

  func prepareAttachmentSnapshot(
    _ originalSnapshot: WorkbenchSnapshot
  ) throws -> PreparedAttachmentSnapshot {
    var sourceURLsByPath: [String: URL] = [:]
    var unresolvedAttachmentCount = 0
    for attachment in allAttachments(in: originalSnapshot) {
      guard
        let sourcePath = attachment.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
        !sourcePath.isEmpty
      else {
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
      guard
        let sourcePath = copy.attachments[index].sourceFilePath?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !sourcePath.isEmpty
      else {
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
      try restoredDraft(
        $0, referencesByMarker: referencesByMarker, attachmentRootURL: attachmentRootURL)
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
        !sourcePath.isEmpty
      else {
        continue
      }
      guard let reference = referencesByMarker[sourcePath] else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
      copy.attachments[index].sourceFilePath =
        attachmentRootURL
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

}
