import Foundation
import PublishingCoreSupport

private struct KnowledgeNoteWritePlan: Sendable {
  var note: KnowledgeNote
  var record: KnowledgeDatabaseNoteRecord
  var artifacts: [String: Data]
}

private enum KnowledgeNoteWriteMode {
  case localEdit(expectedContentRevision: String?)
  case exactImport
}

extension KnowledgeLibraryService {
  /// Lists native user notes. Imported webpages, PDFs and annotations are not
  /// returned here, even though they share the knowledge-library database.
  public func notes(includeArchived: Bool = true) throws -> [KnowledgeNote] {
    try database().noteDocumentIDs(includeArchived: includeArchived).compactMap { id in
      try note(documentID: id)
    }
  }

  public func notesAsync(includeArchived: Bool = true) async throws -> [KnowledgeNote] {
    let service = self
    return try await performKnowledgeLibraryIO {
      try service.notes(includeArchived: includeArchived)
    }
  }

  /// Lightweight inventory for streaming consumers that read note attachments
  /// one note at a time instead of materializing the entire library.
  public func noteDocumentIDsAsync(includeArchived: Bool = true) async throws -> [UUID] {
    let service = self
    return try await performKnowledgeLibraryIO {
      try service.database().noteDocumentIDs(includeArchived: includeArchived)
    }
  }

  public func note(documentID: UUID) throws -> KnowledgeNote? {
    guard let document = try database().document(id: documentID), document.kind == .note else {
      return nil
    }
    let attachments = try database().noteAttachments(documentID: documentID).map { attachment in
      guard let url = safeStorageFileURL(for: attachment.storageReference) else {
        throw KnowledgeLibraryError.unreadableSource(attachment.storageReference)
      }
      let data = try BoundedFileReader.data(
        at: url,
        maximumByteCount: KnowledgeLibraryFileReadLimits.binaryDocumentByteCount
      )
      guard KnowledgeChunkingService.contentHash(for: data) == attachment.contentHash else {
        throw KnowledgeLibraryError.databaseIntegrity("笔记附件摘要不匹配：\(attachment.fileName)")
      }
      return KnowledgeNoteAttachment(
        id: attachment.id,
        fileName: attachment.fileName,
        mimeType: attachment.mimeType,
        data: data
      )
    }
    return KnowledgeNote(
      id: document.id,
      title: document.title,
      tags: document.tags,
      createdAt: document.importedAt,
      updatedAt: document.updatedAt,
      isArchived: try database().noteIsArchived(documentID: documentID),
      sourceURL: document.sourceURL,
      markdown: try normalizedText(documentID: documentID),
      attachments: attachments
    )
  }

  public func noteAsync(documentID: UUID) async throws -> KnowledgeNote? {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.note(documentID: documentID)
    }
  }

  public func noteSignatures(includeArchived: Bool = true) throws -> [UUID: KnowledgeNoteSignature] {
    Dictionary(
      uniqueKeysWithValues: try notes(includeArchived: includeArchived).map { note in
        (note.id, noteSignature(note))
      })
  }

  public func noteSignaturesAsync(
    includeArchived: Bool = true
  ) async throws -> [UUID: KnowledgeNoteSignature] {
    let service = self
    return try await performKnowledgeLibraryIO {
      try service.noteSignatures(includeArchived: includeArchived)
    }
  }

  @discardableResult
  public func createNote(_ note: KnowledgeNote) throws -> KnowledgeNote {
    guard try database().document(id: note.id) == nil else {
      throw KnowledgeLibraryError.invalidMetadata("已存在相同标识的资料。")
    }
    return try writeNotes([note], mode: .localEdit(expectedContentRevision: nil)).first ?? note
  }

  public func createNoteAsync(_ note: KnowledgeNote) async throws -> KnowledgeNote {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.createNote(note)
    }
  }

  @discardableResult
  public func updateNote(_ note: KnowledgeNote) throws -> KnowledgeNote {
    try updateNote(note, expectedContentRevision: nil)
  }

  private func updateNote(
    _ note: KnowledgeNote,
    expectedContentRevision: String?
  ) throws -> KnowledgeNote {
    guard let existing = try database().document(id: note.id), existing.kind == .note else {
      throw KnowledgeLibraryError.missingDocument
    }
    var updated = note
    updated.createdAt = existing.importedAt
    updated.updatedAt = Date()
    return try writeNotes([updated], mode: .localEdit(expectedContentRevision: expectedContentRevision)).first ?? updated
  }

  public func updateNoteAsync(_ note: KnowledgeNote) async throws -> KnowledgeNote {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.updateNote(note)
    }
  }

  public func noteEditRevision(_ note: KnowledgeNote) -> String {
    noteSignature(note).contentHash
  }

  /// Saves an editor draft only when its opening revision is still current.
  /// The compare and write run in one `storageMutationLock` critical section.
  public func updateNote(
    _ note: KnowledgeNote,
    expectedContentRevision: String
  ) throws -> KnowledgeNote {
    try updateNote(note, expectedContentRevision: Optional(expectedContentRevision))
  }

  public func updateNoteAsync(
    _ note: KnowledgeNote,
    expectedContentRevision: String
  ) async throws -> KnowledgeNote {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.updateNote(note, expectedContentRevision: expectedContentRevision)
    }
  }

  /// Imports one note with an explicit collision policy. `.rejectConflict` is
  /// the default so a package cannot silently replace a local note.
  @discardableResult
  public func importNote(
    _ note: KnowledgeNote,
    mode: KnowledgeNoteImportMode = .rejectConflict
  ) throws -> KnowledgeNoteImportDisposition {
    try importNotes([note], mode: mode).first ?? .skippedIdentical(note.id)
  }

  /// Resolves every conflict before any files or database rows are changed.
  /// If validation or collision resolution fails, the package writes nothing.
  /// This validation is public so an import preview can stop before showing a
  /// misleading “ready to import” state for metadata the library cannot
  /// preserve exactly.
  public func validateNotesForImport(_ notes: [KnowledgeNote]) throws {
    var seen = Set<UUID>()
    guard notes.allSatisfy({ seen.insert($0.id).inserted }) else {
      throw KnowledgeLibraryError.invalidMetadata("导入包中包含重复的笔记标识。")
    }
    try notes.forEach(validateExactImportMetadata)

    let database = try database()
    for note in notes {
      if let existing = try database.document(id: note.id), existing.kind != .note {
        throw KnowledgeLibraryError.invalidMetadata("相同标识已被非笔记资料使用。")
      }
    }
  }

  public func validateNotesForImportAsync(_ notes: [KnowledgeNote]) async throws {
    let service = self
    try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.validateNotesForImport(notes)
    }
  }

  @discardableResult
  public func importNotes(
    _ notes: [KnowledgeNote],
    mode: KnowledgeNoteImportMode = .rejectConflict
  ) throws -> [KnowledgeNoteImportDisposition] {
    guard !notes.isEmpty else { return [] }
    try validateNotesForImport(notes)

    let database = try database()
    var pending: [KnowledgeNote] = []
    var dispositions: [KnowledgeNoteImportDisposition] = []
    for note in notes {
      let existingDocument = try database.document(id: note.id)
      guard let existingDocument else {
        pending.append(note)
        dispositions.append(.inserted(note.id))
        continue
      }
      guard existingDocument.kind == .note,
        let existing = try self.note(documentID: note.id)
      else {
        throw KnowledgeLibraryError.invalidMetadata("相同标识已被非笔记资料使用。")
      }
      if noteSignature(existing) == noteSignature(note) {
        dispositions.append(.skippedIdentical(note.id))
        continue
      }
      switch mode {
      case .rejectConflict:
        throw KnowledgeLibraryError.invalidMetadata("笔记“\(note.title.nilIfEmpty ?? note.id.uuidString)”与本机内容冲突。")
      case .copyWithNewID:
        var copy = note
        copy.id = UUID()
        copy.attachments = copy.attachments.map { attachment in
          var attachment = attachment
          attachment.id = UUID()
          return attachment
        }
        pending.append(copy)
        dispositions.append(.copied(sourceID: note.id, localID: copy.id))
      case .replaceExisting:
        pending.append(note)
        dispositions.append(.replaced(note.id))
      }
    }
    _ = try writeNotes(pending, mode: .exactImport)
    return dispositions
  }

  public func importNotesAsync(
    _ notes: [KnowledgeNote],
    mode: KnowledgeNoteImportMode = .rejectConflict
  ) async throws -> [KnowledgeNoteImportDisposition] {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.importNotes(notes, mode: mode)
    }
  }

  private func writeNotes(
    _ notes: [KnowledgeNote],
    mode: KnowledgeNoteWriteMode
  ) throws -> [KnowledgeNote] {
    guard !notes.isEmpty else { return [] }
    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    if case let .localEdit(expectedContentRevision?) = mode {
      guard notes.count == 1,
            let current = try self.note(documentID: notes[0].id),
            noteSignature(current).contentHash == expectedContentRevision else {
      throw KnowledgeLibraryError.staleNoteRevision
      }
    }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let plans = try notes.map { try makeNoteWritePlan($0, mode: mode) }
    var artifacts: [String: Data] = [:]
    for plan in plans {
      for (reference, data) in plan.artifacts {
        if let existing = artifacts[reference], existing != data {
          throw KnowledgeLibraryError.database("笔记内容地址冲突：\(reference)")
        }
        artifacts[reference] = data
      }
    }

    let stagingRootURL = rootURL.appendingPathComponent(
      ".note-staging-\(UUID().uuidString)", isDirectory: true)
    var installedArtifacts: [KnowledgeImportInstalledArtifact] = []
    defer { try? fileManager.removeItem(at: stagingRootURL) }
    var didCommitDatabase = false
    do {
      try stageImportArtifacts(artifacts, at: stagingRootURL)
      installedArtifacts = try installImportArtifacts(artifacts, from: stagingRootURL)
      let staleReferences = try database().commitNotes(plans.map(\.record))
      didCommitDatabase = true
      // Cleanup is best effort. The database now refers to installed files, so
      // a cleanup failure must leave those files in place for a later retry.
      if let notePostCommitCleanup {
        try? notePostCommitCleanup(staleReferences)
      } else {
        try? removeUnreferencedNoteArtifacts(staleReferences)
      }
    } catch {
      if !didCommitDatabase, !installedArtifacts.isEmpty {
        try throwAfterRollingBackImportArtifacts(installedArtifacts, primaryError: error)
      }
      throw error
    }
    let service = self
    Task.detached(priority: .utility) {
      _ = try? await KnowledgeNoteAutomaticSnapshotBackup.shared.createSnapshotIfDue(service: service)
    }
    return plans.map(\.note)
  }

  private func makeNoteWritePlan(
    _ source: KnowledgeNote,
    mode: KnowledgeNoteWriteMode
  ) throws -> KnowledgeNoteWritePlan {
    let title = source.title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard title.count <= 300 else {
      throw KnowledgeLibraryError.invalidMetadata("笔记标题最多 300 个字符。")
    }
    let markdownData = Data(source.markdown.utf8)
    guard markdownData.count <= KnowledgeLibraryFileReadLimits.textDocumentByteCount else {
      throw KnowledgeLibraryError.sourceLimitExceeded("笔记正文超过 64 MB。")
    }
    let sourceURL = try normalizedNoteSourceURL(source.sourceURL)
    let tags = normalizedMetadataValues(source.tags, maximumCount: 50, maximumLength: 80)
    var seenAttachments = Set<UUID>()
    guard source.attachments.allSatisfy({ seenAttachments.insert($0.id).inserted }) else {
      throw KnowledgeLibraryError.invalidMetadata("一条笔记不能包含重复的附件标识。")
    }
    guard source.attachments.count <= 100 else {
      throw KnowledgeLibraryError.invalidMetadata("一条笔记最多包含 100 个附件。")
    }

    let now = Date()
    let createdAt: Date
    let updatedAt: Date
    switch mode {
    case .localEdit:
      createdAt = min(source.createdAt, now)
      updatedAt = max(source.updatedAt, createdAt)
    case .exactImport:
      createdAt = source.createdAt
      updatedAt = source.updatedAt
    }
    let bodyHash = KnowledgeChunkingService.contentHash(for: markdownData)
    let revisionID = UUID()
    let document = KnowledgeDocument(
      id: source.id,
      kind: .note,
      title: title,
      summary: "",
      tags: tags,
      sourceURL: sourceURL,
      sourceName: "本地笔记",
      sourceByteCount: Int64(markdownData.count),
      allowsLocalSemanticIndex: true,
      allowsRemoteAIUse: false,
      // knowledge_documents.is_archived is exclusively the recycle-bin state.
      // A note's portable archive state lives in knowledge_note_metadata.
      isArchived: false,
      importedAt: createdAt,
      updatedAt: updatedAt,
      currentRevisionID: revisionID
    )
    let revision = KnowledgeDocumentRevision(
      id: revisionID,
      documentID: source.id,
      originalContentHash: bodyHash,
      normalizedContentHash: bodyHash,
      parserVersion: Self.parserVersion,
      importedAt: updatedAt,
      originalStorageReference: "blobs/sha256/\(String(bodyHash.prefix(2)))/\(bodyHash).md",
      normalizedStorageReference: "normalized/sha256/\(String(bodyHash.prefix(2)))/\(bodyHash).md"
    )
    let sections = source.markdown.isEmpty ? [] : [KnowledgeExtractedSection(text: source.markdown)]
    let chunks = chunkingService.chunks(
      documentID: source.id,
      revisionID: revisionID,
      sections: sections
    )
    let attachments = try source.attachments.map { attachment -> KnowledgeStoredNoteAttachment in
      let name = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 255, !name.contains("/"), !name.contains("\\") else {
        throw KnowledgeLibraryError.invalidMetadata("笔记附件文件名无效。")
      }
      guard attachment.data.count <= KnowledgeLibraryFileReadLimits.binaryDocumentByteCount else {
        throw KnowledgeLibraryError.sourceLimitExceeded("笔记附件超过 128 MB：\(name)")
      }
      let hash = KnowledgeChunkingService.contentHash(for: attachment.data)
      return KnowledgeStoredNoteAttachment(
        id: attachment.id,
        documentID: source.id,
        fileName: name,
        mimeType: attachment.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        byteCount: Int64(attachment.data.count),
        contentHash: hash,
        storageReference: "attachments/sha256/\(String(hash.prefix(2)))/\(hash)"
      )
    }
    var artifacts = [
      revision.originalStorageReference!: markdownData,
      revision.normalizedStorageReference: markdownData,
    ]
    for (attachment, stored) in zip(source.attachments, attachments) {
      artifacts[stored.storageReference] = attachment.data
    }
    let normalized = KnowledgeNote(
      id: source.id,
      title: title,
      tags: tags,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isArchived: source.isArchived,
      sourceURL: sourceURL,
      markdown: source.markdown,
      attachments: source.attachments
    )
    return KnowledgeNoteWritePlan(
      note: normalized,
      record: KnowledgeDatabaseNoteRecord(
        document: document,
        revision: revision,
        chunks: chunks,
        embeddings: [],
        attachments: attachments,
        isArchived: source.isArchived
      ),
      artifacts: artifacts
    )
  }

  /// Parses the optional source field used by the note editor with the same
  /// policy enforced during persistence.
  public static func noteSourceURL(from rawValue: String) throws -> URL? {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else { return nil }
    guard let sourceURL = URL(string: trimmedValue) else {
      throw KnowledgeLibraryError.invalidNoteSourceURL
    }
    return try validatedNoteSourceURL(sourceURL)
  }

  private func normalizedNoteSourceURL(_ sourceURL: URL?) throws -> URL? {
    try Self.validatedNoteSourceURL(sourceURL)
  }

  private static func validatedNoteSourceURL(_ sourceURL: URL?) throws -> URL? {
    guard let sourceURL else { return nil }
    guard let scheme = sourceURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
      sourceURL.host?.isEmpty == false,
      sourceURL.user == nil,
      sourceURL.password == nil
    else {
      throw KnowledgeLibraryError.invalidNoteSourceURL
    }
    return sourceURL
  }

  private func validateExactImportMetadata(_ note: KnowledgeNote) throws {
    let normalizedTitle = note.title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard normalizedTitle == note.title, note.title.count <= 300 else {
      throw KnowledgeLibraryError.invalidMetadata("导入笔记标题不能包含会被本机规整的字符，且最多 300 个字符。")
    }

    let normalizedTags = normalizedMetadataValues(note.tags, maximumCount: 50, maximumLength: 80)
    guard normalizedTags == note.tags else {
      throw KnowledgeLibraryError.invalidMetadata("导入笔记标签会被本机规整、去重或截断，已拒绝写入。")
    }

    guard
      note.createdAt.timeIntervalSinceReferenceDate.isFinite,
      note.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      note.updatedAt >= note.createdAt
    else {
      throw KnowledgeLibraryError.invalidMetadata("导入笔记时间必须是有效值，且创建时间不能晚于更新时间。")
    }

    _ = try normalizedNoteSourceURL(note.sourceURL)
    guard note.attachments.count <= 100 else {
      throw KnowledgeLibraryError.invalidMetadata("一条笔记最多包含 100 个附件。")
    }
    var attachmentIDs = Set<UUID>()
    for attachment in note.attachments {
      guard attachmentIDs.insert(attachment.id).inserted else {
        throw KnowledgeLibraryError.invalidMetadata("一条笔记不能包含重复的附件标识。")
      }
      let fileName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      let mimeType = attachment.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      guard fileName == attachment.fileName, mimeType == attachment.mimeType,
        !fileName.isEmpty, fileName.count <= 255,
        !fileName.contains("/"), !fileName.contains("\\")
      else {
        throw KnowledgeLibraryError.invalidMetadata("导入笔记附件元数据会被本机规整或无法安全保存。")
      }
    }
  }

  private func noteSignature(_ note: KnowledgeNote) -> KnowledgeNoteSignature {
    let attachmentHashes = Dictionary(
      uniqueKeysWithValues: note.attachments.map { attachment in
        (attachment.id, KnowledgeChunkingService.contentHash(for: attachment.data))
      })
    let attachmentDescription = note.attachments
      .sorted { $0.id.uuidString < $1.id.uuidString }
      .map { attachment in
        "\(attachment.id.uuidString)|\(attachment.fileName)|\(canonicalMIMEType(attachment.mimeType))|\(attachmentHashes[attachment.id] ?? "")"
      }
      .joined(separator: "\n")
    let content = [
      note.id.uuidString,
      note.title,
      note.tags.joined(separator: "\u{1F}"),
      String(note.createdAt.timeIntervalSince1970),
      String(note.updatedAt.timeIntervalSince1970),
      note.isArchived ? "1" : "0",
      note.sourceURL?.absoluteString ?? "",
      note.markdown,
      attachmentDescription,
    ].joined(separator: "\u{1E}")
    return KnowledgeNoteSignature(
      id: note.id,
      contentHash: KnowledgeChunkingService.contentHash(for: content),
      attachmentHashes: attachmentHashes
    )
  }

  private func canonicalMIMEType(_ mimeType: String?) -> String {
    let value = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return value?.nilIfEmpty ?? "application/octet-stream"
  }

  private func removeUnreferencedNoteArtifacts(_ references: Set<String>) throws {
    let unreferenced = try database().unreferencedStorageReferences(references)
    for reference in unreferenced {
      guard let url = safeStorageFileURL(for: reference), fileManager.fileExists(atPath: url.path) else {
        continue
      }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw KnowledgeLibraryError.database("无法清理笔记附件：\(reference)")
      }
      try fileManager.removeItem(at: url)
    }
  }
}
