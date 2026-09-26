import Foundation
import SQLite3

struct KnowledgeStoredNoteAttachment: Hashable, Sendable {
  var id: UUID
  var documentID: UUID
  var fileName: String
  var mimeType: String?
  var byteCount: Int64
  var contentHash: String
  var storageReference: String
}

struct KnowledgeDatabaseNoteRecord: Sendable {
  var document: KnowledgeDocument
  var revision: KnowledgeDocumentRevision
  var chunks: [KnowledgeChunk]
  var embeddings: [KnowledgeChunkEmbedding]
  var attachments: [KnowledgeStoredNoteAttachment]
  var isArchived: Bool
}

extension KnowledgeDatabase {
  func noteAttachments(documentID: UUID) throws -> [KnowledgeStoredNoteAttachment] {
    return try withLock {
      let sql = """
        SELECT id, document_id, file_name, mime_type, byte_count, content_hash, storage_ref
        FROM knowledge_note_attachments
        WHERE document_id = ?
        ORDER BY created_at ASC, id ASC;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        var attachments: [KnowledgeStoredNoteAttachment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          attachments.append(
            KnowledgeStoredNoteAttachment(
              id: try requiredUUID(statement, 0, field: "knowledge_note_attachments.id"),
              documentID: try requiredUUID(
                statement,
                1,
                field: "knowledge_note_attachments.document_id"
              ),
              fileName: text(statement, 2) ?? "附件",
              mimeType: text(statement, 3)?.nilIfEmpty,
              byteCount: max(0, Int64(sqlite3_column_int64(statement, 4))),
              contentHash: text(statement, 5) ?? "",
              storageReference: text(statement, 6) ?? ""
            ))
        }
        try checkStatementCompletion(statement)
        return attachments
      }
    }
  }

  func noteDocumentIDs(includeArchived: Bool) throws -> [UUID] {
    try withLock {
      let sql =
        includeArchived
        ? """
        SELECT d.id
        FROM knowledge_documents d
        LEFT JOIN knowledge_note_metadata m ON m.document_id = d.id
        WHERE d.kind = 'note' AND d.is_archived = 0
        ORDER BY d.imported_at DESC, d.id ASC;
        """
        : """
        SELECT d.id
        FROM knowledge_documents d
        LEFT JOIN knowledge_note_metadata m ON m.document_id = d.id
        WHERE d.kind = 'note' AND d.is_archived = 0 AND COALESCE(m.is_archived, 0) = 0
        ORDER BY d.imported_at DESC, d.id ASC;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          ids.append(try requiredUUID(statement, 0, field: "knowledge_documents.id"))
        }
        try checkStatementCompletion(statement)
        return ids
      }
    }
  }

  func noteIsArchived(documentID: UUID) throws -> Bool {
    try withLock {
      try withCachedStatementUnlocked(
        "SELECT is_archived FROM knowledge_note_metadata WHERE document_id = ? LIMIT 1;"
      ) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return sqlite3_column_int(statement, 0) != 0 }
        guard result == SQLITE_DONE else { throw databaseError() }
        return false
      }
    }
  }

  func commitNotes(_ records: [KnowledgeDatabaseNoteRecord]) throws -> Set<String> {
    guard !records.isEmpty else { return [] }
    return try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        var previousReferences = Set<String>()
        var currentReferences = Set<String>()
        for record in records {
          guard record.document.kind == .note else {
            throw KnowledgeLibraryError.invalidMetadata("只能保存用户笔记。")
          }
          previousReferences.formUnion(
            try noteAttachmentReferencesUnlocked(documentID: record.document.id))
          try upsertDocument(record.document)
          try insertRevision(record.revision)
          try deleteSearchRows(documentID: record.document.id)
          try insertChunks(record.chunks, document: record.document)
          try upsertSemanticEmbeddingsUnlocked(record.embeddings)
          try replaceNoteAttachmentsUnlocked(record.attachments, documentID: record.document.id)
          try replaceNoteArchiveStateUnlocked(
            documentID: record.document.id,
            isArchived: record.isArchived
          )
          currentReferences.formUnion(
            try noteAttachmentReferencesUnlocked(documentID: record.document.id))
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
        return previousReferences.subtracting(currentReferences)
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  private func replaceNoteAttachmentsUnlocked(
    _ attachments: [KnowledgeStoredNoteAttachment],
    documentID: UUID
  ) throws {
    let deleteSQL = "DELETE FROM knowledge_note_attachments WHERE document_id = ?;"
    try withCachedStatementUnlocked(deleteSQL) { statement in
      bind(documentID.uuidString, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
    guard !attachments.isEmpty else { return }
    let insertSQL = """
      INSERT INTO knowledge_note_attachments (
        id, document_id, file_name, mime_type, byte_count, content_hash, storage_ref, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
      """
    try withCachedStatementUnlocked(insertSQL) { statement in
      for attachment in attachments {
        guard attachment.documentID == documentID else {
          throw KnowledgeLibraryError.invalidMetadata("笔记附件关联错误。")
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(attachment.id.uuidString, at: 1, to: statement)
        bind(documentID.uuidString, at: 2, to: statement)
        bind(attachment.fileName, at: 3, to: statement)
        bindOptional(attachment.mimeType, at: 4, to: statement)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(attachment.byteCount))
        bind(attachment.contentHash, at: 6, to: statement)
        bind(attachment.storageReference, at: 7, to: statement)
        sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      }
    }
  }

  private func replaceNoteArchiveStateUnlocked(
    documentID: UUID,
    isArchived: Bool
  ) throws {
    try withCachedStatementUnlocked(
      """
      INSERT INTO knowledge_note_metadata (document_id, is_archived) VALUES (?, ?)
      ON CONFLICT(document_id) DO UPDATE SET is_archived = excluded.is_archived;
      """
    ) { statement in
      bind(documentID.uuidString, at: 1, to: statement)
      sqlite3_bind_int(statement, 2, isArchived ? 1 : 0)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func unreferencedStorageReferences(_ references: Set<String>) throws -> Set<String> {
    guard !references.isEmpty else { return [] }
    return try withLock {
      var unreferenced = Set<String>()
      for reference in references where try !storageReferenceIsInUseUnlocked(reference) {
        unreferenced.insert(reference)
      }
      return unreferenced
    }
  }

  func noteAttachmentReferencesUnlocked(documentID: UUID) throws -> Set<String> {
    try withCachedStatementUnlocked(
      "SELECT storage_ref FROM knowledge_note_attachments WHERE document_id = ?;"
    ) { statement in
      bind(documentID.uuidString, at: 1, to: statement)
      var references = Set<String>()
      while sqlite3_step(statement) == SQLITE_ROW {
        if let reference = text(statement, 0)?.nilIfEmpty { references.insert(reference) }
      }
      try checkStatementCompletion(statement)
      return references
    }
  }
}
