import Foundation
import SQLite3

extension KnowledgeDatabase {
  func documents() throws -> [KnowledgeDocument] {
    try withLock {
      let sql = """
        SELECT id, kind, title, authors_json, language, summary, tags_json,
               source_url, source_name, folder_id, source_byte_count,
               allows_ai_use, allows_local_semantic_index, is_archived,
               imported_at, updated_at, current_revision_id
        FROM knowledge_documents
        WHERE is_archived = 0
        ORDER BY imported_at DESC, title COLLATE NOCASE ASC;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        var output: [KnowledgeDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeDocument(statement, offset: 0))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func recycledDocuments() throws -> [KnowledgeRecycledDocument] {
    try withLock {
      let sql = """
        SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
               d.tags_json, d.source_url, d.source_name, d.folder_id,
               d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
               d.is_archived,
               d.imported_at, d.updated_at, d.current_revision_id,
               r.deleted_at
        FROM knowledge_recycle_bin r
        JOIN knowledge_documents d ON d.id = r.document_id
        WHERE d.is_archived = 1
        ORDER BY r.deleted_at DESC, d.title COLLATE NOCASE ASC;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        var output: [KnowledgeRecycledDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(
            KnowledgeRecycledDocument(
              document: try decodeDocument(statement, offset: 0),
              deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
            ))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func document(id: UUID) throws -> KnowledgeDocument? {
    try withLock {
      let sql = """
        SELECT id, kind, title, authors_json, language, summary, tags_json,
               source_url, source_name, folder_id, source_byte_count,
               allows_ai_use, allows_local_semantic_index, is_archived,
               imported_at, updated_at, current_revision_id
        FROM knowledge_documents WHERE id = ? LIMIT 1;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(id.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
          return try decodeDocument(statement, offset: 0)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return nil
      }
    }
  }

  func folders() throws -> [KnowledgeFolder] {
    try withLock {
      return try withCachedStatementUnlocked(
        """
          SELECT id, name, created_at, updated_at
          FROM knowledge_folders
          ORDER BY name COLLATE NOCASE ASC, created_at ASC;
        """) { statement in
        var output: [KnowledgeFolder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeFolder(statement))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func createFolder(name: String) throws -> KnowledgeFolder {
    try withLock {
      let normalizedName = try validatedFolderName(name)
      guard try !folderNameExistsUnlocked(normalizedName, excluding: nil) else {
        throw KnowledgeLibraryError.duplicateFolderName(normalizedName)
      }
      let now = Date()
      let folder = KnowledgeFolder(name: normalizedName, createdAt: now, updatedAt: now)
      return try withCachedStatementUnlocked(
        """
        INSERT INTO knowledge_folders (id, name, created_at, updated_at)
        VALUES (?, ?, ?, ?);
        """) { statement in
        bind(folder.id.uuidString, at: 1, to: statement)
        bind(folder.name, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, folder.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, folder.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return folder
      }
    }
  }

  func renameFolder(id: UUID, name: String) throws -> KnowledgeFolder {
    try withLock {
      let normalizedName = try validatedFolderName(name)
      let createdAt = try withCachedStatementUnlocked(
        "SELECT created_at FROM knowledge_folders WHERE id = ? LIMIT 1;") { statement in
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
          throw KnowledgeLibraryError.missingFolder
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
      }
      guard try !folderNameExistsUnlocked(normalizedName, excluding: id) else {
        throw KnowledgeLibraryError.duplicateFolderName(normalizedName)
      }
      let now = Date()
      return try withCachedStatementUnlocked(
        """
        UPDATE knowledge_folders SET name = ?, updated_at = ? WHERE id = ?;
        """) { statement in
        bind(normalizedName, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        bind(id.uuidString, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingFolder }
        return KnowledgeFolder(id: id, name: normalizedName, createdAt: createdAt, updatedAt: now)
      }
    }
  }

  func deleteFolder(id: UUID) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try withCachedStatementUnlocked(
          "UPDATE knowledge_documents SET folder_id = NULL WHERE folder_id = ?;") { statement in
          bind(id.uuidString, at: 1, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
          }
        }

        let deletedCount = try withCachedStatementUnlocked(
          "DELETE FROM knowledge_folders WHERE id = ?;") { statement in
          bind(id.uuidString, at: 1, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
          }
          return sqlite3_changes(handle)
        }
        guard deletedCount == 1 else { throw KnowledgeLibraryError.missingFolder }
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func setFolder(_ folderID: UUID?, documentID: UUID) throws {
    try withLock {
      if let folderID, try !folderExistsUnlocked(folderID) {
        throw KnowledgeLibraryError.missingFolder
      }
      try withCachedStatementUnlocked(
        """
        UPDATE knowledge_documents SET folder_id = ?, updated_at = ? WHERE id = ?;
        """) { statement in
        bindOptional(folderID?.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bind(documentID.uuidString, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
      }
    }
  }

  func setFolder(_ folderID: UUID?, documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      if let folderID, try !folderExistsUnlocked(folderID) {
        throw KnowledgeLibraryError.missingFolder
      }
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try withCachedStatementUnlocked(
          """
          UPDATE knowledge_documents
          SET folder_id = ?, updated_at = ?
          WHERE id = ? AND is_archived = 0;
          """) { statement in
          let now = Date().timeIntervalSince1970
          for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindOptional(folderID?.uuidString, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, now)
            bind(documentID.uuidString, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
          }
        }
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func updateMetadata(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try withCachedStatementUnlocked(
          """
          UPDATE knowledge_documents
          SET kind = ?, title = ?, authors_json = ?, language = ?, summary = ?,
              tags_json = ?, updated_at = ?
          WHERE id = ? AND is_archived = 0;
          """) { statement in
          bind(metadata.kind.rawValue, at: 1, to: statement)
          bind(metadata.title, at: 2, to: statement)
          bind(json(metadata.authors), at: 3, to: statement)
          bindOptional(metadata.language, at: 4, to: statement)
          bind(metadata.summary, at: 5, to: statement)
          bind(json(metadata.tags), at: 6, to: statement)
          sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
          bind(documentID.uuidString, at: 8, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
          let updatedCount = sqlite3_changes(handle)
          guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }
        }

        try withCachedStatementUnlocked(
          """
          UPDATE knowledge_chunks_fts SET title = ?, authors = ? WHERE document_id = ?;
          """) { statement in
          bind(metadata.title, at: 1, to: statement)
          bind(metadata.authors.joined(separator: " "), at: 2, to: statement)
          bind(documentID.uuidString, at: 3, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
        try deleteSemanticEmbeddingsUnlocked(documentIDs: Set([documentID]))
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func addTags(_ tags: [String], documentIDs: Set<UUID>) throws {
    guard !tags.isEmpty, !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let selectSQL = """
          SELECT tags_json FROM knowledge_documents
          WHERE id = ? AND is_archived = 0 LIMIT 1;
          """
        let updateSQL = """
          UPDATE knowledge_documents SET tags_json = ?, updated_at = ? WHERE id = ?;
          """
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          let merged = try withCachedStatementUnlocked(selectSQL) { selectStatement in
            bind(documentID.uuidString, at: 1, to: selectStatement)
            guard sqlite3_step(selectStatement) == SQLITE_ROW else {
              throw KnowledgeLibraryError.missingDocument
            }
            var merged = try decodeStringArrayJSON(
              text(selectStatement, 0),
              field: "knowledge_documents.tags_json"
            )
            for tag in tags
            where !merged.contains(where: {
              $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
              merged.append(tag)
            }
            return merged
          }
          try withCachedStatementUnlocked(updateSQL) { updateStatement in
            bind(json(merged), at: 1, to: updateStatement)
            sqlite3_bind_double(updateStatement, 2, now)
            bind(documentID.uuidString, at: 3, to: updateStatement)
            guard sqlite3_step(updateStatement) == SQLITE_DONE else { throw databaseError() }
          }
        }
        try deleteSemanticEmbeddingsUnlocked(documentIDs: documentIDs)
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func setSourceByteCount(_ sourceByteCount: Int64, documentID: UUID) throws {
    try withLock {
      try withCachedStatementUnlocked(
        "UPDATE knowledge_documents SET source_byte_count = ? WHERE id = ?;") { statement in
        sqlite3_bind_int64(statement, 1, sqlite3_int64(max(0, sourceByteCount)))
        bind(documentID.uuidString, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      }
    }
  }

  func currentRevision(documentID: UUID) throws -> KnowledgeDocumentRevision? {
    try withLock {
      let sql = """
        SELECT r.id, r.document_id, r.original_hash, r.normalized_hash,
               r.parser_version, r.imported_at, r.source_modified_at,
               r.original_storage_ref, r.captured_text_storage_ref,
               r.normalized_storage_ref
        FROM knowledge_revisions r
        JOIN knowledge_documents d ON d.current_revision_id = r.id
        WHERE d.id = ? LIMIT 1;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
          return try decodeRevision(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return nil
      }
    }
  }

  func revisions(documentID: UUID) throws -> [KnowledgeDocumentRevision] {
    try withLock {
      return try withCachedStatementUnlocked(
        """
        SELECT id, document_id, original_hash, normalized_hash,
               parser_version, imported_at, source_modified_at,
               original_storage_ref, captured_text_storage_ref,
               normalized_storage_ref
        FROM knowledge_revisions
        WHERE document_id = ?
        ORDER BY imported_at DESC, id ASC;
        """) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        var output: [KnowledgeDocumentRevision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeRevision(statement))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func revision(id: UUID) throws -> KnowledgeDocumentRevision? {
    try withLock {
      return try withCachedStatementUnlocked(
        """
        SELECT id, document_id, original_hash, normalized_hash,
               parser_version, imported_at, source_modified_at,
               original_storage_ref, captured_text_storage_ref,
               normalized_storage_ref
        FROM knowledge_revisions WHERE id = ? LIMIT 1;
        """) { statement in
        bind(id.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return try decodeRevision(statement) }
        guard result == SQLITE_DONE else { throw databaseError() }
        return nil
      }
    }
  }

  func existingDocument(
    sourceURL: URL?,
    originalHash: String,
    normalizedHash: String,
    parserVersion: Int,
    kind: KnowledgeDocumentKind? = nil
  ) throws -> (document: KnowledgeDocument, identical: Bool)? {
    try withLock {
      let source = sourceURL?.absoluteString.nilIfEmpty
      let isImage = kind == .image
      let sql = """
        SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
               d.tags_json, d.source_url, d.source_name, d.folder_id,
               d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
               d.is_archived,
               d.imported_at, d.updated_at, d.current_revision_id,
               r.original_hash, r.normalized_hash, r.parser_version
        FROM knowledge_documents d
        JOIN knowledge_revisions r ON r.id = d.current_revision_id
        WHERE r.original_hash = ?
           OR (? = 0 AND (
             (? IS NOT NULL AND d.source_url = ?)
             OR r.normalized_hash = ?
           ))
        ORDER BY CASE WHEN (? IS NOT NULL AND d.source_url = ?) THEN 0 ELSE 1 END,
                 d.updated_at DESC
        LIMIT 1;
        """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(originalHash, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, isImage ? 1 : 0)
        bindOptional(source, at: 3, to: statement)
        bindOptional(source, at: 4, to: statement)
        bind(normalizedHash, at: 5, to: statement)
        bindOptional(source, at: 6, to: statement)
        bindOptional(source, at: 7, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
          let document = try decodeDocument(statement, offset: 0)
          let storedOriginalHash = text(statement, 17) ?? ""
          let storedNormalizedHash = text(statement, 18) ?? ""
          let storedParserVersion = Int(sqlite3_column_int64(statement, 19))
          return (
            document,
            storedParserVersion == parserVersion
              && (storedOriginalHash == originalHash
                || (!isImage && storedNormalizedHash == normalizedHash))
          )
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return nil
      }
    }
  }
}
