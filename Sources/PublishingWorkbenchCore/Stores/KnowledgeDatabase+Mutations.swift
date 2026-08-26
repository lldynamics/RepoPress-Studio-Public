import Foundation
import SQLite3

extension KnowledgeDatabase {
  func commit(
    document: KnowledgeDocument,
    revision: KnowledgeDocumentRevision,
    chunks: [KnowledgeChunk],
    embeddings: [KnowledgeChunkEmbedding]
  ) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try upsertDocument(document)
        try insertRevision(revision)
        try deleteSearchRows(documentID: document.id)
        try insertChunks(chunks, document: document)
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func commitImportBatch(
    records: [KnowledgeDatabaseImportRecord],
    capturedTextAssignments: [KnowledgeDatabaseCapturedTextAssignment],
    folderAssignments: [KnowledgeDatabaseFolderAssignment]
  ) throws {
    guard !records.isEmpty
            || !capturedTextAssignments.isEmpty
            || !folderAssignments.isEmpty else { return }

    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        for record in records {
          try Task.checkCancellation()
          try upsertDocument(record.document)
          try insertRevision(record.revision)
          try deleteSearchRows(documentID: record.document.id)
          try insertChunks(record.chunks, document: record.document)
          try upsertSemanticEmbeddingsUnlocked(record.embeddings)
        }

        if !capturedTextAssignments.isEmpty {
          let capturedTextSQL = """
            UPDATE knowledge_revisions
            SET captured_text_storage_ref = ?
            WHERE id = ? AND (captured_text_storage_ref IS NULL OR captured_text_storage_ref = '');
            """
          try withCachedStatementUnlocked(capturedTextSQL) { statement in
            for assignment in capturedTextAssignments {
              try Task.checkCancellation()
              sqlite3_reset(statement)
              sqlite3_clear_bindings(statement)
              bind(assignment.storageReference, at: 1, to: statement)
              bind(assignment.revisionID.uuidString, at: 2, to: statement)
              guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError()
              }
              let updatedCount = sqlite3_changes(handle)
              guard updatedCount == 1 else { throw KnowledgeLibraryError.missingRevision }
            }
          }
        }

        if !folderAssignments.isEmpty {
          let folderUpdateTime = Date().timeIntervalSince1970
          let folderUpdateSQL = """
            UPDATE knowledge_documents SET folder_id = ?, updated_at = ? WHERE id = ?;
            """
          for assignment in folderAssignments {
            try Task.checkCancellation()
            if let folderID = assignment.folderID, try !folderExistsUnlocked(folderID) {
              throw KnowledgeLibraryError.missingFolder
            }
          }
          try withCachedStatementUnlocked(folderUpdateSQL) { statement in
            for assignment in folderAssignments {
              try Task.checkCancellation()
              sqlite3_reset(statement)
              sqlite3_clear_bindings(statement)
              bindOptional(assignment.folderID?.uuidString, at: 1, to: statement)
              sqlite3_bind_double(statement, 2, folderUpdateTime)
              bind(assignment.documentID.uuidString, at: 3, to: statement)
              guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError()
              }
              let updatedCount = sqlite3_changes(handle)
              guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }
            }
          }
        }

        if !folderAssignments.isEmpty {
          // Folder-only batches still update document timestamps used by
          // semantic tie-breaking.
          invalidateSemanticFlatVectorIndexesUnlocked()
        }
        try Task.checkCancellation()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  @discardableResult
  func restoreRevision(documentID: UUID, revisionID: UUID) throws -> KnowledgeDocument {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let revisionSQL = """
        SELECT 1 FROM knowledge_revisions
        WHERE id = ? AND document_id = ? LIMIT 1;
        """
        let revisionResult = try withCachedStatementUnlocked(revisionSQL) { statement in
          bind(revisionID.uuidString, at: 1, to: statement)
          bind(documentID.uuidString, at: 2, to: statement)
          return sqlite3_step(statement)
        }
        guard revisionResult == SQLITE_ROW else {
          if revisionResult != SQLITE_DONE { throw databaseError() }
          throw KnowledgeLibraryError.missingRevision
        }

        let updateSQL = """
        UPDATE knowledge_documents
        SET current_revision_id = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """
        let updatedCount = try withCachedStatementUnlocked(updateSQL) { statement in
          bind(revisionID.uuidString, at: 1, to: statement)
          sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
          bind(documentID.uuidString, at: 3, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
          }
          return sqlite3_changes(handle)
        }
        guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }

        guard let document = try documentUnlocked(id: documentID) else {
          throw KnowledgeLibraryError.missingDocument
        }
        try deleteSearchRows(documentID: documentID)
        try insertSearchRows(revisionID: revisionID, document: document)
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
        return document
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentID: UUID) throws {
    try withLock {
      let sql = "UPDATE knowledge_documents SET allows_ai_use = ?, updated_at = ? WHERE id = ?;"
      let updatedCount = try withCachedStatementUnlocked(sql) { statement in
        sqlite3_bind_int(statement, 1, allowsRemoteAIUse ? 1 : 0)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bind(documentID.uuidString, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return sqlite3_changes(handle)
      }
      guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }
      invalidateSemanticFlatVectorIndexesUnlocked()
    }
  }

  func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let sql = """
        UPDATE knowledge_documents
        SET allows_ai_use = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """
        let now = Date().timeIntervalSince1970
        try withCachedStatementUnlocked(sql) { statement in
          for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, allowsRemoteAIUse ? 1 : 0)
            sqlite3_bind_double(statement, 2, now)
            bind(documentID.uuidString, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
          }
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentID: UUID) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let sql = """
        UPDATE knowledge_documents
        SET allows_local_semantic_index = ?, updated_at = ?
        WHERE id = ?;
        """
        let updatedCount = try withCachedStatementUnlocked(sql) { statement in
          sqlite3_bind_int(statement, 1, allowsLocalSemanticIndex ? 1 : 0)
          sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
          bind(documentID.uuidString, at: 3, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
          return sqlite3_changes(handle)
        }
        guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }
        if !allowsLocalSemanticIndex {
          try deleteSemanticEmbeddingsUnlocked(documentIDs: [documentID])
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let sql = """
        UPDATE knowledge_documents
        SET allows_local_semantic_index = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """
        let now = Date().timeIntervalSince1970
        try withCachedStatementUnlocked(sql) { statement in
          for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, allowsLocalSemanticIndex ? 1 : 0)
            sqlite3_bind_double(statement, 2, now)
            bind(documentID.uuidString, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
          }
        }
        if !allowsLocalSemanticIndex {
          try deleteSemanticEmbeddingsUnlocked(documentIDs: documentIDs)
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) throws {
    try setAllowsRemoteAIUse(allowsAIUse, documentID: documentID)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) throws {
    try setAllowsRemoteAIUse(allowsAIUse, documentIDs: documentIDs)
  }

  func moveToRecycleBin(documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let archiveSQL = """
        UPDATE knowledge_documents
        SET is_archived = 1, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """
        let recycleSQL = """
        INSERT INTO knowledge_recycle_bin (document_id, deleted_at)
        VALUES (?, ?)
        ON CONFLICT(document_id) DO UPDATE SET deleted_at = excluded.deleted_at;
        """
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          try withCachedStatementUnlocked(archiveSQL) { archiveStatement in
            sqlite3_bind_double(archiveStatement, 1, now)
            bind(documentID.uuidString, at: 2, to: archiveStatement)
            guard sqlite3_step(archiveStatement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
          }
          try withCachedStatementUnlocked(recycleSQL) { recycleStatement in
            bind(documentID.uuidString, at: 1, to: recycleStatement)
            sqlite3_bind_double(recycleStatement, 2, now)
            guard sqlite3_step(recycleStatement) == SQLITE_DONE else { throw databaseError() }
          }
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func restoreFromRecycleBin(documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let restoreSQL = """
        UPDATE knowledge_documents
        SET is_archived = 0, updated_at = ?
        WHERE id = ? AND is_archived = 1;
        """
        let clearSQL = "DELETE FROM knowledge_recycle_bin WHERE document_id = ?;"
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          try withCachedStatementUnlocked(restoreSQL) { restoreStatement in
            sqlite3_bind_double(restoreStatement, 1, now)
            bind(documentID.uuidString, at: 2, to: restoreStatement)
            guard sqlite3_step(restoreStatement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
          }
          try withCachedStatementUnlocked(clearSQL) { clearStatement in
            bind(documentID.uuidString, at: 1, to: clearStatement)
            guard sqlite3_step(clearStatement) == SQLITE_DONE else { throw databaseError() }
          }
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func pinnedDocumentIDs() throws -> Set<UUID> {
    try withLock {
      let sql = "SELECT document_id FROM knowledge_pinned_documents;"
      return try withCachedStatementUnlocked(sql) { statement in
        var output = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
          output.insert(
            try requiredUUID(
              statement,
              0,
              field: "knowledge_pinned_documents.document_id"
            )
          )
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func setPinned(_ pinned: Bool, documentID: UUID) throws {
    try withLock {
      let sql = pinned
        ? "INSERT OR IGNORE INTO knowledge_pinned_documents (document_id) VALUES (?);"
        : "DELETE FROM knowledge_pinned_documents WHERE document_id = ?;"
      let requiresDocumentExistenceCheck = try withCachedStatementUnlocked(sql) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return pinned && sqlite3_changes(handle) == 0
      }
      if requiresDocumentExistenceCheck {
        let documentSQL = "SELECT 1 FROM knowledge_documents WHERE id = ? LIMIT 1;"
        try withCachedStatementUnlocked(documentSQL) { documentStatement in
          bind(documentID.uuidString, at: 1, to: documentStatement)
          guard sqlite3_step(documentStatement) == SQLITE_ROW else {
            throw KnowledgeLibraryError.missingDocument
          }
        }
      }
    }
  }

  func annotations(documentID: UUID) throws -> [KnowledgeAnnotation] {
    try withLock {
      let sql = """
      SELECT id, document_id, revision_id, chunk_id, locator,
             highlighted_text, note, created_at, updated_at
      FROM knowledge_annotations
      WHERE document_id = ?
      ORDER BY updated_at DESC, created_at DESC;
      """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        var output: [KnowledgeAnnotation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeAnnotation(statement))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func saveAnnotation(_ annotation: KnowledgeAnnotation) throws {
    try withLock {
      guard try rowExistsUnlocked(
        "SELECT 1 FROM knowledge_documents WHERE id = ? LIMIT 1;",
        values: [annotation.documentID.uuidString]
      ) else {
        throw KnowledgeLibraryError.missingDocument
      }
      if let revisionID = annotation.revisionID {
        guard try rowExistsUnlocked(
          "SELECT 1 FROM knowledge_revisions WHERE id = ? AND document_id = ? LIMIT 1;",
          values: [revisionID.uuidString, annotation.documentID.uuidString]
        ) else {
          throw KnowledgeLibraryError.missingRevision
        }
      }
      if let chunkID = annotation.chunkID {
        var sql = "SELECT 1 FROM knowledge_chunks WHERE id = ? AND document_id = ?"
        var values = [chunkID.uuidString, annotation.documentID.uuidString]
        if let revisionID = annotation.revisionID {
          sql += " AND revision_id = ?"
          values.append(revisionID.uuidString)
        }
        sql += " LIMIT 1;"
        guard try rowExistsUnlocked(sql, values: values) else {
          throw KnowledgeLibraryError.invalidMetadata("标注位置不属于这条资料。")
        }
      }
      let sql = """
      INSERT INTO knowledge_annotations (
        id, document_id, revision_id, chunk_id, locator,
        highlighted_text, note, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        revision_id = excluded.revision_id,
        chunk_id = excluded.chunk_id,
        locator = excluded.locator,
        highlighted_text = excluded.highlighted_text,
        note = excluded.note,
        updated_at = excluded.updated_at
      WHERE knowledge_annotations.document_id = excluded.document_id;
      """
      try withCachedStatementUnlocked(sql) { statement in
        bind(annotation.id.uuidString, at: 1, to: statement)
        bind(annotation.documentID.uuidString, at: 2, to: statement)
        bindOptional(annotation.revisionID?.uuidString, at: 3, to: statement)
        bindOptional(annotation.chunkID?.uuidString, at: 4, to: statement)
        bindOptional(annotation.locator, at: 5, to: statement)
        bind(annotation.highlightedText, at: 6, to: statement)
        bind(annotation.note, at: 7, to: statement)
        sqlite3_bind_double(statement, 8, annotation.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, annotation.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(handle) == 1 else {
          throw KnowledgeLibraryError.invalidMetadata("标注标识与资料不匹配。")
        }
      }
    }
  }

  func deleteAnnotation(id: UUID) throws {
    try withLock {
      let sql = "DELETE FROM knowledge_annotations WHERE id = ?;"
      try withCachedStatementUnlocked(sql) { statement in
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
      }
    }
  }

  func backlinks(documentID: UUID) throws -> [KnowledgeBacklink] {
    try withLock {
      let sql = """
      SELECT b.id, b.cited_document_id, b.chunk_id, b.target_kind, b.target_id,
             b.target_title, b.target_location, b.created_at,
             COALESCE(c.locator, c.heading_path), c.content
      FROM knowledge_backlinks b
      JOIN knowledge_chunks c ON c.id = b.chunk_id
      WHERE b.cited_document_id = ?
      ORDER BY b.created_at DESC, b.target_title COLLATE NOCASE ASC, c.ordinal ASC;
      """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(documentID.uuidString, at: 1, to: statement)
        var output: [KnowledgeBacklink] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeBacklink(statement))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func backlinks(
    targetKind: KnowledgeBacklinkTargetKind,
    targetID: String
  ) throws -> [KnowledgeBacklink] {
    try withLock {
      let sql = """
      SELECT b.id, b.cited_document_id, b.chunk_id, b.target_kind, b.target_id,
             b.target_title, b.target_location, b.created_at,
             COALESCE(c.locator, c.heading_path), c.content
      FROM knowledge_backlinks b
      JOIN knowledge_chunks c ON c.id = b.chunk_id
      WHERE b.target_kind = ? AND b.target_id = ?
      ORDER BY b.created_at DESC, b.target_title COLLATE NOCASE ASC, c.ordinal ASC;
      """
      return try withCachedStatementUnlocked(sql) { statement in
        bind(targetKind.rawValue, at: 1, to: statement)
        bind(targetID, at: 2, to: statement)
        var output: [KnowledgeBacklink] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          output.append(try decodeBacklink(statement))
        }
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func recordBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) throws {
    guard !citations.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        for citation in citations {
          guard try rowExistsUnlocked(
            "SELECT 1 FROM knowledge_chunks WHERE id = ? AND document_id = ? LIMIT 1;",
            values: [citation.chunkID.uuidString, citation.documentID.uuidString]
          ) else {
            throw KnowledgeLibraryError.invalidMetadata("引用片段不属于指定资料。")
          }
        }
        let sql = """
        INSERT INTO knowledge_backlinks (
          id, cited_document_id, chunk_id, target_kind, target_id,
          target_title, target_location, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cited_document_id, chunk_id, target_kind, target_id)
        DO UPDATE SET
          target_title = excluded.target_title,
          target_location = excluded.target_location,
          created_at = excluded.created_at;
        """
        let now = Date().timeIntervalSince1970
        try withCachedStatementUnlocked(sql) { statement in
          for citation in citations {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(UUID().uuidString, at: 1, to: statement)
            bind(citation.documentID.uuidString, at: 2, to: statement)
            bind(citation.chunkID.uuidString, at: 3, to: statement)
            bind(target.kind.rawValue, at: 4, to: statement)
            bind(target.id, at: 5, to: statement)
            bind(target.title, at: 6, to: statement)
            bindOptional(target.location, at: 7, to: statement)
            sqlite3_bind_double(statement, 8, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
          }
        }
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func deleteDocument(id: UUID) throws -> KnowledgeDatabaseDeletionOutcome {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let storageReferences = try storageReferencesUnlocked(documentID: id)
        try deleteSearchRows(documentID: id)
        let sql = "DELETE FROM knowledge_documents WHERE id = ?;"
        let deletedCount = try withCachedStatementUnlocked(sql) { statement in
          bind(id.uuidString, at: 1, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
          }
          return sqlite3_changes(handle)
        }
        guard deletedCount == 1 else {
          throw KnowledgeLibraryError.missingDocument
        }
        invalidateSemanticFlatVectorIndexesUnlocked()
        let unreferencedStorageReferences = try Set(storageReferences.filter { reference in
          try !storageReferenceIsInUseUnlocked(reference)
        })
        try executeUnlocked("COMMIT;")
        return KnowledgeDatabaseDeletionOutcome(
          unreferencedStorageReferences: unreferencedStorageReferences
        )
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func storageReferencesUnlocked(documentID: UUID) throws -> Set<String> {
    let sql = """
    SELECT original_storage_ref, captured_text_storage_ref, normalized_storage_ref
    FROM knowledge_revisions
    WHERE document_id = ?;
    """
    return try withCachedStatementUnlocked(sql) { statement in
      bind(documentID.uuidString, at: 1, to: statement)
      var references = Set<String>()
      while sqlite3_step(statement) == SQLITE_ROW {
        if let originalReference = text(statement, 0)?.nilIfEmpty {
          references.insert(originalReference)
        }
        if let capturedTextReference = text(statement, 1)?.nilIfEmpty {
          references.insert(capturedTextReference)
        }
        if let normalizedReference = text(statement, 2)?.nilIfEmpty {
          references.insert(normalizedReference)
        }
      }
      try checkStatementCompletion(statement)
      return references
    }
  }

  func storageReferenceIsInUseUnlocked(_ reference: String) throws -> Bool {
    let sql = """
    SELECT 1
    FROM knowledge_revisions
    WHERE original_storage_ref = ?
       OR captured_text_storage_ref = ?
       OR normalized_storage_ref = ?
    LIMIT 1;
    """
    return try withCachedStatementUnlocked(sql) { statement in
      bind(reference, at: 1, to: statement)
      bind(reference, at: 2, to: statement)
      bind(reference, at: 3, to: statement)
      let result = sqlite3_step(statement)
      guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
      return result == SQLITE_ROW
    }
  }
}
