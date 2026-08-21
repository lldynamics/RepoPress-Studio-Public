import Foundation
import os

private let logger = Logger(subsystem: "com.repopress", category: "KnowledgeLibraryService")

extension KnowledgeLibraryService {
  public func documents() throws -> [KnowledgeDocument] {
    let database = try database()
    var documents = try database.documents()
    for index in documents.indices where documents[index].sourceByteCount == 0 {
      guard let revision = try database.currentRevision(documentID: documents[index].id) else {
        continue
      }
      let references = [revision.originalStorageReference, revision.normalizedStorageReference]
        .compactMap { $0?.nilIfEmpty }
      var byteCount: Int64?
      for reference in references {
        guard let url = self.safeStorageFileURL(for: reference) else { continue }
        do {
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          if size > 0 {
            byteCount = Int64(size)
            break
          }
        } catch {
          logger.error(
            "Knowledge source size lookup failed for document \(documents[index].id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      guard let byteCount else { continue }
      documents[index].sourceByteCount = byteCount
      try database.setSourceByteCount(byteCount, documentID: documents[index].id)
    }
    return documents
  }

  public func documentsAsync() async throws -> [KnowledgeDocument] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.documents()
    }.value
  }

  public func document(id: UUID) throws -> KnowledgeDocument? {
    try database().document(id: id)
  }

  public func folders() throws -> [KnowledgeFolder] {
    try database().folders()
  }

  public func foldersAsync() async throws -> [KnowledgeFolder] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.folders()
    }.value
  }

  public func recycledDocuments() throws -> [KnowledgeRecycledDocument] {
    try database().recycledDocuments()
  }

  public func recycledDocumentsAsync() async throws -> [KnowledgeRecycledDocument] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.recycledDocuments()
    }.value
  }

  @discardableResult
  public func createFolder(name: String) throws -> KnowledgeFolder {
    try database().createFolder(name: name)
  }

  @discardableResult
  public func renameFolder(id: UUID, name: String) throws -> KnowledgeFolder {
    try database().renameFolder(id: id, name: name)
  }

  public func deleteFolder(id: UUID) throws {
    try database().deleteFolder(id: id)
  }

  public func setFolder(_ folderID: UUID?, documentID: UUID) throws {
    try database().setFolder(folderID, documentID: documentID)
  }

  public func setFolder(_ folderID: UUID?, documentIDs: Set<UUID>) throws {
    try database().setFolder(folderID, documentIDs: documentIDs)
  }

  public func addTags(_ tags: [String], documentIDs: Set<UUID>) throws {
    let normalizedTags = normalizedMetadataValues(tags, maximumCount: 50, maximumLength: 80)
    guard !normalizedTags.isEmpty else {
      throw KnowledgeLibraryError.invalidMetadata("请至少输入一个有效标签。")
    }
    try database().addTags(normalizedTags, documentIDs: documentIDs)
    invalidateSemanticBackfillCache()
  }

  @discardableResult
  public func updateMetadata(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) throws -> KnowledgeDocument {
    let title = metadata.title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard !title.isEmpty, title.count <= 300 else {
      throw KnowledgeLibraryError.invalidMetadata("标题不能为空，且最多 300 个字符。")
    }
    let normalized = KnowledgeDocumentMetadata(
      kind: metadata.kind,
      title: title,
      authors: normalizedMetadataValues(metadata.authors, maximumCount: 30, maximumLength: 120),
      language: metadata.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      summary: String(
        metadata.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000)),
      tags: normalizedMetadataValues(metadata.tags, maximumCount: 50, maximumLength: 80)
    )
    try database().updateMetadata(documentID: documentID, metadata: normalized)
    invalidateSemanticBackfillCache()
    guard let document = try database().document(id: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    return document
  }

  public func normalizedText(documentID: UUID) throws -> String {
    guard let revision = try database().currentRevision(documentID: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    let url = rootURL.appendingPathComponent(revision.normalizedStorageReference)
    let text: String
    do {
      text = try BoundedFileReader.utf8String(
        at: url,
        maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
      )
    } catch {
      logger.warning(
        "无法读取文件 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw KnowledgeLibraryError.unreadableSource(url.path)
    }
    return text
  }

  public func normalizedTextAsync(documentID: UUID) async throws -> String {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.normalizedText(documentID: documentID)
    }.value
  }

  /// Returns the browser-extracted text before local reading/index cleanup.
  /// The original HTML or MHTML archive remains stored separately.
  public func capturedText(documentID: UUID) throws -> String? {
    guard let revision = try database().currentRevision(documentID: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    if let reference = revision.capturedTextStorageReference?.nilIfEmpty {
      guard let url = safeStorageFileURL(for: reference) else {
        throw KnowledgeLibraryError.unreadableSource(reference)
      }
      let text: String
      do {
        text = try BoundedFileReader.utf8String(
          at: url,
          maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
        )
      } catch {
        logger.warning(
          "无法读取文件 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        throw KnowledgeLibraryError.unreadableSource(reference)
      }
      return text
    }

    // Before schema version 7, plain-text browser captures used the original
    // blob itself. Keep those documents inspectable without rewriting history.
    guard let reference = revision.originalStorageReference?.nilIfEmpty,
      let url = safeStorageFileURL(for: reference)
    else {
      return nil
    }
    let pathExtension = (reference as NSString).pathExtension.lowercased()
    if ["txt", "text"].contains(pathExtension) {
      return try? BoundedFileReader.utf8String(
        at: url,
        maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
      )
    }
    guard ["html", "htm", "mhtml", "mht"].contains(pathExtension),
      let data = try? BoundedFileReader.data(
        at: url,
        maximumByteCount: WorkbenchContentFileReadLimits.binaryDocumentByteCount
      )
    else {
      return nil
    }
    return webContentSanitizer.readableOriginalText(from: data)
  }

  public func capturedTextAsync(documentID: UUID) async throws -> String? {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.capturedText(documentID: documentID)
    }.value
  }

  public func revisions(documentID: UUID) throws -> [KnowledgeDocumentRevision] {
    try database().revisions(documentID: documentID)
  }

  public func normalizedText(revisionID: UUID) throws -> String {
    guard let revision = try database().revision(id: revisionID) else {
      throw KnowledgeLibraryError.missingRevision
    }
    let url = rootURL.appendingPathComponent(revision.normalizedStorageReference)
    let text: String
    do {
      text = try BoundedFileReader.utf8String(
        at: url,
        maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
      )
    } catch {
      logger.warning(
        "无法读取文件 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw KnowledgeLibraryError.unreadableSource(url.path)
    }
    return text
  }

  /// Captures an explicit @ reference from one authoritative document/revision
  /// read. The returned binding is tied to the revision's normalized hash;
  /// callers must validate it again immediately before remote transport.
  public func explicitAIContextSnapshot(
    documentID: UUID
  ) async throws -> KnowledgeExplicitContextSnapshot? {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      guard let record = try service.database().currentDocumentRevision(documentID: documentID)
      else {
        return nil
      }
      guard !record.document.isArchived, record.document.allowsRemoteAIUse else {
        return nil
      }
      let text = try service.normalizedText(revisionID: record.revision.id)
      let readableText =
        record.document.kind == .webpage
        ? service.webContentSanitizer.sanitizeExtractedReadingText(text)
        : text
      guard !readableText.isEmpty else { return nil }
      return KnowledgeExplicitContextSnapshot(
        text: readableText,
        authorizationBinding: KnowledgeAuthorizationBinding(
          documentID: record.document.id,
          revisionID: record.revision.id,
          contentHash: record.revision.normalizedContentHash
        )
      )
    }.value
  }

  /// Validates every captured binding against SQLite and the current remote-AI
  /// policy. Empty bindings are valid because a request may contain no
  /// knowledge context. Any malformed or stale binding fails closed.
  public func validateKnowledgeAuthorizationBindings(
    _ bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy
  ) async throws -> Bool {
    guard !bindings.isEmpty else { return true }
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let database = try service.database()
      let pinnedDocumentIDs: Set<UUID>?
      switch policy {
      case .off:
        // `.off` disables automatic retrieval only. Explicit @ references
        // still carry bindings and must be validated against source state.
        pinnedDocumentIDs = nil
      case .automatic:
        pinnedDocumentIDs = nil
      case .pinnedOnly:
        pinnedDocumentIDs = try database.pinnedDocumentIDs()
      }

      var seen = Set<KnowledgeAuthorizationBinding>()
      for binding in bindings {
        // Duplicate bindings are harmless, but still validate every unique
        // source deterministically.
        guard seen.insert(binding).inserted else { continue }
        guard !binding.contentHash.isEmpty,
          let record = try database.currentDocumentRevision(documentID: binding.documentID),
          record.document.id == binding.documentID,
          !record.document.isArchived,
          record.document.allowsRemoteAIUse,
          record.document.currentRevisionID == binding.revisionID,
          record.revision.id == binding.revisionID,
          pinnedDocumentIDs?.contains(binding.documentID) ?? true
        else {
          return false
        }

        if let chunkID = binding.chunkID {
          guard
            let chunk = try database.chunk(
              id: chunkID,
              documentID: binding.documentID,
              revisionID: binding.revisionID
            ),
            chunk.contentHash == binding.contentHash,
            KnowledgeChunkingService.contentHash(for: chunk.content) == binding.contentHash
          else {
            return false
          }
        } else {
          guard record.revision.normalizedContentHash == binding.contentHash else {
            return false
          }
        }
      }
      return true
    }.value
  }

  @discardableResult
  public func restoreRevision(
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeDocument {
    let database = try database()
    var document = try database.restoreRevision(documentID: documentID, revisionID: revisionID)
    if let revision = try database.revision(id: revisionID),
      let byteCount = storedByteCount(for: revision)
    {
      try database.setSourceByteCount(byteCount, documentID: documentID)
      document.sourceByteCount = byteCount
    }
    invalidateSemanticBackfillCache()
    return document
  }

  public func revisionDifference(
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeRevisionDifference {
    guard let currentRevision = try database().currentRevision(documentID: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    guard let comparedRevision = try database().revision(id: revisionID),
      comparedRevision.documentID == documentID
    else {
      throw KnowledgeLibraryError.missingRevision
    }
    return revisionDifferenceService.difference(
      previousText: try normalizedText(revisionID: revisionID),
      currentText: try normalizedText(revisionID: currentRevision.id)
    )
  }

  public func makeSourceRefreshPreview(
    documentID: UUID
  ) async throws -> KnowledgeSourceRefreshPreview {
    guard let document = try document(id: documentID),
      let currentRevision = try database().currentRevision(documentID: documentID),
      let sourceURL = document.sourceURL
    else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }

    var importPreview: KnowledgeImportPreview
    if sourceURL.isFileURL {
      importPreview = try await makeImportPreview(sourceURL: sourceURL)
    } else if ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") {
      importPreview = try await makeWebImportPreview(url: sourceURL)
    } else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }
    guard importPreview.candidates.count == 1 else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }

    var candidate = importPreview.candidates[0]
    candidate.existingDocumentID = documentID
    candidate.disposition =
      candidate.normalizedContentHash == currentRevision.normalizedContentHash
      ? .duplicate
      : .update
    candidate.kind = document.kind
    candidate.title = document.title
    candidate.authors = document.authors
    candidate.language = document.language
    candidate.summary = document.summary
    candidate.tags = document.tags
    importPreview.candidates = [candidate]
    let previousText = try normalizedText(revisionID: currentRevision.id)
    return KnowledgeSourceRefreshPreview(
      documentID: documentID,
      currentRevision: currentRevision,
      importPreview: importPreview,
      difference: revisionDifferenceService.difference(
        previousText: previousText,
        currentText: candidate.normalizedText
      )
    )
  }

  public func applySourceRefresh(
    _ preview: KnowledgeSourceRefreshPreview
  ) async throws -> KnowledgeImportResult {
    guard
      preview.importPreview.candidates.allSatisfy({ candidate in
        candidate.existingDocumentID == preview.documentID
      })
    else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }
    return try await commit(preview.importPreview, destination: .preserveExisting)
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentID: UUID) throws {
    try database().setAllowsRemoteAIUse(allowsRemoteAIUse, documentID: documentID)
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentIDs: Set<UUID>) throws {
    try database().setAllowsRemoteAIUse(allowsRemoteAIUse, documentIDs: documentIDs)
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentID: UUID) throws
  {
    try database().setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentID: documentID)
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentIDs: Set<UUID>)
    throws
  {
    try database().setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentIDs: documentIDs)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) throws {
    try setAllowsRemoteAIUse(allowsAIUse, documentID: documentID)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) throws {
    try setAllowsRemoteAIUse(allowsAIUse, documentIDs: documentIDs)
  }

  public func moveToRecycleBin(documentIDs: Set<UUID>) throws {
    try database().moveToRecycleBin(documentIDs: documentIDs)
  }

  public func restoreFromRecycleBin(documentIDs: Set<UUID>) throws {
    try database().restoreFromRecycleBin(documentIDs: documentIDs)
  }

  public func annotations(documentID: UUID) throws -> [KnowledgeAnnotation] {
    try database().annotations(documentID: documentID)
  }

  @discardableResult
  public func saveAnnotation(_ annotation: KnowledgeAnnotation) throws -> KnowledgeAnnotation {
    let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty, note.count <= 20_000 else {
      throw KnowledgeLibraryError.invalidMetadata("标注笔记不能为空，且最多 20,000 个字符。")
    }
    var normalized = annotation
    normalized.note = note
    normalized.highlightedText = String(
      annotation.highlightedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000)
    )
    normalized.locator =
      annotation.locator?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    normalized.updatedAt = Date()
    try database().saveAnnotation(normalized)
    return normalized
  }

  public func deleteAnnotation(id: UUID) throws {
    try database().deleteAnnotation(id: id)
  }

  public func backlinks(documentID: UUID) throws -> [KnowledgeBacklink] {
    try database().backlinks(documentID: documentID)
  }

  public func backlinks(
    targetKind: KnowledgeBacklinkTargetKind,
    targetID: String
  ) throws -> [KnowledgeBacklink] {
    let normalizedTargetID = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTargetID.isEmpty else { return [] }
    return try database().backlinks(
      targetKind: targetKind,
      targetID: normalizedTargetID
    )
  }

  public func backlinksAsync(
    targetKind: KnowledgeBacklinkTargetKind,
    targetID: String
  ) async throws -> [KnowledgeBacklink] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.backlinks(targetKind: targetKind, targetID: targetID)
    }.value
  }

  public func recordBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) throws {
    guard !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !target.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw KnowledgeLibraryError.invalidMetadata("反向链接目标缺少标题或标识。")
    }
    try database().recordBacklinks(citations: citations, target: target)
  }

  public func pinnedDocumentIDs() throws -> Set<UUID> {
    try database().pinnedDocumentIDs()
  }

  public func pinnedDocumentIDsAsync() async throws -> Set<UUID> {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.pinnedDocumentIDs()
    }.value
  }

  public func setPinned(_ pinned: Bool, documentID: UUID) throws {
    try database().setPinned(pinned, documentID: documentID)
  }
}
