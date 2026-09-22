import CryptoKit
import Foundation
import PublishingCoreSupport
import PublishingDomainContracts

extension WorkspaceBackupService {
  public func inspectArticlesForRestore(
    at backupURL: URL, currentApplicationVersion: String? = nil
  ) throws
    -> WorkspaceBackupArticleSelectionPreview
  {
    let validated = try validatedBackup(
      at: backupURL, currentApplicationVersion: currentApplicationVersion
    )
    let snapshot = try articleRestoreSnapshot(at: backupURL, manifest: validated.manifest)
    return WorkspaceBackupArticleSelectionPreview(
      backupURL: backupURL,
      backupPreview: validated.preview,
      articles: snapshot.drafts.map { draft in
        WorkspaceBackupArticleSummary(
          id: draft.id,
          title: draft.title,
          attachmentCount: draft.attachments.count,
          unresolvedAttachmentCount: draft.attachments.filter {
            $0.sourceFilePath?.isEmpty != false
          }.count
        )
      },
      manifest: validated.manifest
    )
  }

  /// Preparation owns only a fresh temporary directory. No workspace or backup
  /// files are mutated. The caller promotes this directory at the commit boundary.
  func prepareArticleRestore(
    preview: WorkspaceBackupArticleSelectionPreview,
    selectedDraftIDs: Set<UUID>,
    editingProfileID: UUID,
    attachmentRootURL: URL
  ) throws -> PreparedWorkspaceArticleRestore {
    guard !selectedDraftIDs.isEmpty,
      selectedDraftIDs.isSubset(of: Set(preview.articles.map(\.id)))
    else { throw WorkspaceBackupArticleRestoreError.invalidSelection }

    let validated = try validatedBackup(at: preview.backupURL)
    guard validated.manifest == preview.manifest else {
      throw WorkspaceBackupArticleRestoreError.backupChanged
    }
    let snapshot = try articleRestoreSnapshot(at: preview.backupURL, manifest: validated.manifest)
    let selected = snapshot.drafts.filter { selectedDraftIDs.contains($0.id) }
    guard selected.count == selectedDraftIDs.count else {
      throw WorkspaceBackupArticleRestoreError.invalidSelection
    }
    let operationID = UUID().uuidString.lowercased()
    // Keep staging on the destination volume so promotion is a directory rename,
    // not a potentially large cross-volume copy on the main actor.
    let stagingParentURL = attachmentRootURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: stagingParentURL, withIntermediateDirectories: true)
    let stagingURL =
      stagingParentURL
      .appendingPathComponent(".article-restore-\(operationID).stage", isDirectory: true)
    let destinationURL =
      attachmentRootURL
      .appendingPathComponent("article-restore-\(operationID)", isDirectory: true)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
    do {
      let references = Dictionary(
        uniqueKeysWithValues: validated.manifest.attachmentReferences.map { ($0.marker, $0) }
      )
      let files = Dictionary(
        uniqueKeysWithValues: validated.manifest.files.map { ($0.relativePath, $0) }
      )
      var copiedNames: [String: String] = [:]
      var restoredDrafts: [ArticleDraft] = []
      for draft in selected {
        try Task.checkCancellation()
        var coverID: UUID?
        var attachments: [DraftAttachment] = []
        for sourceAttachment in draft.attachments {
          try Task.checkCancellation()
          var attachment = sourceAttachment
          attachment.id = UUID()
          attachment.repositorySHA = nil
          attachment.remoteObjectKey = nil
          attachment.remoteURL = nil
          attachment.remoteETag = nil
          attachment.sourceFilePath = nil
          if let marker = sourceAttachment.sourceFilePath, !marker.isEmpty {
            guard let reference = references[marker],
              let expected = files[reference.archiveRelativePath]
            else { throw WorkspaceBackupError.invalidAttachmentReference(marker) }
            let name: String
            if let existing = copiedNames[marker] {
              name = existing
            } else {
              // Bound the generated name even for an archive at NAME_MAX.
              // Original names remain in attachment metadata.
              let suffix = URL(fileURLWithPath: reference.archiveRelativePath).pathExtension
              name =
                UUID().uuidString.lowercased()
                + (suffix.isEmpty ? "" : "." + String(suffix.prefix(16)))
              let copied = try copyRegularFile(
                from: preview.backupURL.appendingPathComponent(reference.archiveRelativePath),
                to: stagingURL.appendingPathComponent(name),
                relativePath: reference.archiveRelativePath,
                component: .draftAttachments
              )
              guard copied.sha256 == expected.sha256.lowercased(),
                copied.byteCount == expected.byteCount
              else { throw WorkspaceBackupError.checksumMismatch(reference.archiveRelativePath) }
              copiedNames[marker] = name
            }
            attachment.sourceFilePath = destinationURL.appendingPathComponent(name).path
            attachment.byteSize = expected.byteCount
          }
          if draft.coverAttachmentID == sourceAttachment.id { coverID = attachment.id }
          attachments.append(attachment)
        }
        // Preserve content and its link paths, but never import publishing identity,
        // repository revisions, route aliases, built-in-guide identity, or history.
        restoredDrafts.append(
          ArticleDraft(
            siteProfileID: editingProfileID,
            scope: .general,
            title: draft.title,
            date: draft.date,
            slug: draft.slug,
            tags: draft.tags,
            categories: draft.categories,
            authors: draft.authors,
            visibility: draft.visibility,
            summary: draft.summary,
            coverAttachmentID: coverID,
            bodyMarkdown: draft.bodyMarkdown,
            attachments: attachments
          )
        )
      }
      try Task.checkCancellation()
      return PreparedWorkspaceArticleRestore(
        drafts: restoredDrafts, stagingURL: stagingURL, destinationURL: destinationURL
      )
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  private func articleRestoreSnapshot(at backupURL: URL, manifest: WorkspaceBackupManifest) throws
    -> WorkbenchSnapshot
  {
    // Hash exactly the bytes decoded, closing the validation/read race for the
    // selected article text. Descriptor-relative reads reject symlink ancestors.
    let data = try SafeFileReader.data(
      relativePath: Self.workbenchRelativePath,
      under: backupURL,
      maximumByteCount: Int(clamping: limits.maximumWorkbenchByteCount)
    )
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard
      let expected = manifest.files.first(where: { $0.relativePath == Self.workbenchRelativePath }),
      expected.sha256.lowercased() == digest, expected.byteCount == Int64(data.count)
    else { throw WorkspaceBackupError.checksumMismatch(Self.workbenchRelativePath) }
    return try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
  }
}

struct PreparedWorkspaceArticleRestore: Sendable {
  let drafts: [ArticleDraft]
  let stagingURL: URL
  let destinationURL: URL
}
