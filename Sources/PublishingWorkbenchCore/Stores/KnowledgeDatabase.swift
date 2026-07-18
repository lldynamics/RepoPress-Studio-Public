import Foundation
import SQLite3

private let knowledgeSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct KnowledgeDatabaseBackupInspection: Hashable, Sendable {
  var userVersion: Int
  var documentCount: Int
  var folderCount: Int
  var revisionCount: Int
  var chunkCount: Int
  var storageReferences: Set<String>
  var sampleTitles: [String]
}

struct KnowledgeDatabaseDeletionOutcome: Hashable, Sendable {
  var unreferencedStorageReferences: Set<String>
}

final class KnowledgeDatabase: @unchecked Sendable {
  static let currentSchemaVersion = 5

  private let fileURL: URL
  private let lock = NSLock()
  private var handle: OpaquePointer?

  init(fileURL: URL) throws {
    self.fileURL = fileURL
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "无法打开数据库"
      if let database { sqlite3_close(database) }
      throw KnowledgeLibraryError.database(message)
    }
    handle = database

    do {
      try execute("PRAGMA foreign_keys = ON;")
      let existingUserVersion = try withLock {
        try scalarIntUnlocked("PRAGMA user_version;")
      }
      guard existingUserVersion <= Self.currentSchemaVersion else {
        throw KnowledgeLibraryError.unsupportedDatabaseVersion(
          found: existingUserVersion,
          supported: Self.currentSchemaVersion
        )
      }
      try execute("PRAGMA journal_mode = WAL;")
      try execute("PRAGMA synchronous = NORMAL;")
      try migrate(from: existingUserVersion)
    } catch {
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  deinit {
    if let handle {
      sqlite3_close(handle)
    }
  }

  private init(readOnlyBackupURL fileURL: URL) throws {
    self.fileURL = fileURL
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "无法打开备份数据库"
      if let database { sqlite3_close(database) }
      throw KnowledgeLibraryBackupError.databaseIntegrity(message)
    }
    handle = database
  }

  func createBackupSnapshot(at destinationURL: URL) throws -> KnowledgeDatabaseBackupInspection {
    try withLock {
      guard let handle else {
        throw KnowledgeLibraryBackupError.databaseIntegrity("资料库数据库尚未打开")
      }
      try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }

      var destinationHandle: OpaquePointer?
      let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
      guard sqlite3_open_v2(destinationURL.path, &destinationHandle, flags, nil) == SQLITE_OK,
            let destinationHandle else {
        let message = destinationHandle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
          ?? "无法创建 SQLite 快照"
        if let destinationHandle { sqlite3_close(destinationHandle) }
        throw KnowledgeLibraryBackupError.databaseIntegrity(message)
      }
      defer { sqlite3_close(destinationHandle) }

      guard let backup = sqlite3_backup_init(destinationHandle, "main", handle, "main") else {
        throw KnowledgeLibraryBackupError.databaseIntegrity(
          String(cString: sqlite3_errmsg(destinationHandle))
        )
      }

      var stepResult: Int32 = SQLITE_OK
      repeat {
        stepResult = sqlite3_backup_step(backup, -1)
        if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
          sqlite3_sleep(10)
        }
      } while stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED
      let finishResult = sqlite3_backup_finish(backup)
      guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
        throw KnowledgeLibraryBackupError.databaseIntegrity(
          String(cString: sqlite3_errmsg(destinationHandle))
        )
      }

      var journalError: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(
        destinationHandle,
        "PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL;",
        nil,
        nil,
        &journalError
      ) == SQLITE_OK else {
        let message = journalError.map { String(cString: $0) }
          ?? String(cString: sqlite3_errmsg(destinationHandle))
        sqlite3_free(journalError)
        throw KnowledgeLibraryBackupError.databaseIntegrity(message)
      }

      return try backupInspectionUnlocked(validateIntegrity: false)
    }
  }

  static func inspectBackup(at fileURL: URL) throws -> KnowledgeDatabaseBackupInspection {
    do {
      let database = try KnowledgeDatabase(readOnlyBackupURL: fileURL)
      return try database.withLock {
        let userVersion = try database.scalarIntUnlocked("PRAGMA user_version;")
        guard userVersion <= Self.currentSchemaVersion else {
          throw KnowledgeLibraryBackupError.unsupportedDatabaseVersion(
            found: userVersion,
            supported: Self.currentSchemaVersion
          )
        }
        return try database.backupInspectionUnlocked(validateIntegrity: true)
      }
    } catch let error as KnowledgeLibraryBackupError {
      throw error
    } catch {
      throw KnowledgeLibraryBackupError.databaseIntegrity(error.localizedDescription)
    }
  }

  func documents() throws -> [KnowledgeDocument] {
    try withLock {
      let sql = """
      SELECT id, kind, title, authors_json, language, summary, tags_json,
             source_url, source_name, folder_id, source_byte_count,
             allows_ai_use, is_archived,
             imported_at, updated_at, current_revision_id
      FROM knowledge_documents
      WHERE is_archived = 0
      ORDER BY imported_at DESC, title COLLATE NOCASE ASC;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      var output: [KnowledgeDocument] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(decodeDocument(statement, offset: 0))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func recycledDocuments() throws -> [KnowledgeRecycledDocument] {
    try withLock {
      let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             r.deleted_at
      FROM knowledge_recycle_bin r
      JOIN knowledge_documents d ON d.id = r.document_id
      WHERE d.is_archived = 1
      ORDER BY r.deleted_at DESC, d.title COLLATE NOCASE ASC;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      var output: [KnowledgeRecycledDocument] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(KnowledgeRecycledDocument(
          document: decodeDocument(statement, offset: 0),
          deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16))
        ))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func document(id: UUID) throws -> KnowledgeDocument? {
    try withLock {
      let sql = """
      SELECT id, kind, title, authors_json, language, summary, tags_json,
             source_url, source_name, folder_id, source_byte_count,
             allows_ai_use, is_archived,
             imported_at, updated_at, current_revision_id
      FROM knowledge_documents WHERE id = ? LIMIT 1;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      bind(id.uuidString, at: 1, to: statement)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        return decodeDocument(statement, offset: 0)
      }
      guard result == SQLITE_DONE else { throw databaseError() }
      return nil
    }
  }

  func folders() throws -> [KnowledgeFolder] {
    try withLock {
      let statement = try prepare("""
      SELECT id, name, created_at, updated_at
      FROM knowledge_folders
      ORDER BY name COLLATE NOCASE ASC, created_at ASC;
    """)
      defer { sqlite3_finalize(statement) }
      var output: [KnowledgeFolder] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(decodeFolder(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func createFolder(name: String) throws -> KnowledgeFolder {
    try withLock {
      let normalizedName = try validatedFolderName(name)
      guard try !folderNameExists(normalizedName, excluding: nil) else {
        throw KnowledgeLibraryError.duplicateFolderName(normalizedName)
      }
      let now = Date()
      let folder = KnowledgeFolder(name: normalizedName, createdAt: now, updatedAt: now)
      let statement = try prepare("""
      INSERT INTO knowledge_folders (id, name, created_at, updated_at)
      VALUES (?, ?, ?, ?);
      """)
      defer { sqlite3_finalize(statement) }
      bind(folder.id.uuidString, at: 1, to: statement)
      bind(folder.name, at: 2, to: statement)
      sqlite3_bind_double(statement, 3, folder.createdAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, folder.updatedAt.timeIntervalSince1970)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      return folder
    }
  }

  func renameFolder(id: UUID, name: String) throws -> KnowledgeFolder {
    try withLock {
      let normalizedName = try validatedFolderName(name)
      let lookupStatement = try prepare("SELECT created_at FROM knowledge_folders WHERE id = ? LIMIT 1;")
      bind(id.uuidString, at: 1, to: lookupStatement)
      guard sqlite3_step(lookupStatement) == SQLITE_ROW else {
        sqlite3_finalize(lookupStatement)
        throw KnowledgeLibraryError.missingFolder
      }
      let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(lookupStatement, 0))
      sqlite3_finalize(lookupStatement)
      guard try !folderNameExists(normalizedName, excluding: id) else {
        throw KnowledgeLibraryError.duplicateFolderName(normalizedName)
      }
      let now = Date()
      let statement = try prepare("""
      UPDATE knowledge_folders SET name = ?, updated_at = ? WHERE id = ?;
      """)
      defer { sqlite3_finalize(statement) }
      bind(normalizedName, at: 1, to: statement)
      sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
      bind(id.uuidString, at: 3, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingFolder }
      return KnowledgeFolder(id: id, name: normalizedName, createdAt: createdAt, updatedAt: now)
    }
  }

  func deleteFolder(id: UUID) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let clearStatement = try prepare("UPDATE knowledge_documents SET folder_id = NULL WHERE folder_id = ?;")
        bind(id.uuidString, at: 1, to: clearStatement)
        guard sqlite3_step(clearStatement) == SQLITE_DONE else {
          sqlite3_finalize(clearStatement)
          throw databaseError()
        }
        sqlite3_finalize(clearStatement)

        let deleteStatement = try prepare("DELETE FROM knowledge_folders WHERE id = ?;")
        bind(id.uuidString, at: 1, to: deleteStatement)
        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
          sqlite3_finalize(deleteStatement)
          throw databaseError()
        }
        let deletedCount = sqlite3_changes(handle)
        sqlite3_finalize(deleteStatement)
        guard deletedCount == 1 else { throw KnowledgeLibraryError.missingFolder }
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func setFolder(_ folderID: UUID?, documentID: UUID) throws {
    try withLock {
      if let folderID, try !folderExists(folderID) {
        throw KnowledgeLibraryError.missingFolder
      }
      let statement = try prepare("""
      UPDATE knowledge_documents SET folder_id = ?, updated_at = ? WHERE id = ?;
      """)
      defer { sqlite3_finalize(statement) }
      bindOptional(folderID?.uuidString, at: 1, to: statement)
      sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
      bind(documentID.uuidString, at: 3, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
    }
  }

  func setFolder(_ folderID: UUID?, documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      if let folderID, try !folderExists(folderID) {
        throw KnowledgeLibraryError.missingFolder
      }
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let statement = try prepare("""
        UPDATE knowledge_documents
        SET folder_id = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """)
        defer { sqlite3_finalize(statement) }
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
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
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
        let updateStatement = try prepare("""
        UPDATE knowledge_documents
        SET kind = ?, title = ?, authors_json = ?, language = ?, summary = ?,
            tags_json = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """)
        bind(metadata.kind.rawValue, at: 1, to: updateStatement)
        bind(metadata.title, at: 2, to: updateStatement)
        bind(json(metadata.authors), at: 3, to: updateStatement)
        bindOptional(metadata.language, at: 4, to: updateStatement)
        bind(metadata.summary, at: 5, to: updateStatement)
        bind(json(metadata.tags), at: 6, to: updateStatement)
        sqlite3_bind_double(updateStatement, 7, Date().timeIntervalSince1970)
        bind(documentID.uuidString, at: 8, to: updateStatement)
        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
          sqlite3_finalize(updateStatement)
          throw databaseError()
        }
        let updatedCount = sqlite3_changes(handle)
        sqlite3_finalize(updateStatement)
        guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }

        let ftsStatement = try prepare("""
        UPDATE knowledge_chunks_fts SET title = ?, authors = ? WHERE document_id = ?;
        """)
        bind(metadata.title, at: 1, to: ftsStatement)
        bind(metadata.authors.joined(separator: " "), at: 2, to: ftsStatement)
        bind(documentID.uuidString, at: 3, to: ftsStatement)
        guard sqlite3_step(ftsStatement) == SQLITE_DONE else {
          sqlite3_finalize(ftsStatement)
          throw databaseError()
        }
        sqlite3_finalize(ftsStatement)
        try deleteSemanticEmbeddingsUnlocked(documentIDs: Set([documentID]))
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func addTags(_ tags: [String], documentIDs: Set<UUID>) throws {
    guard !tags.isEmpty, !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let selectStatement = try prepare("""
        SELECT tags_json FROM knowledge_documents
        WHERE id = ? AND is_archived = 0 LIMIT 1;
        """)
        let updateStatement = try prepare("""
        UPDATE knowledge_documents SET tags_json = ?, updated_at = ? WHERE id = ?;
        """)
        defer {
          sqlite3_finalize(selectStatement)
          sqlite3_finalize(updateStatement)
        }
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          sqlite3_reset(selectStatement)
          sqlite3_clear_bindings(selectStatement)
          bind(documentID.uuidString, at: 1, to: selectStatement)
          guard sqlite3_step(selectStatement) == SQLITE_ROW else {
            throw KnowledgeLibraryError.missingDocument
          }
          var merged = decodeJSON(text(selectStatement, 0))
          for tag in tags where !merged.contains(where: {
            $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
          }) {
            merged.append(tag)
          }
          sqlite3_reset(updateStatement)
          sqlite3_clear_bindings(updateStatement)
          bind(json(merged), at: 1, to: updateStatement)
          sqlite3_bind_double(updateStatement, 2, now)
          bind(documentID.uuidString, at: 3, to: updateStatement)
          guard sqlite3_step(updateStatement) == SQLITE_DONE else { throw databaseError() }
        }
        try deleteSemanticEmbeddingsUnlocked(documentIDs: documentIDs)
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func setSourceByteCount(_ sourceByteCount: Int64, documentID: UUID) throws {
    try withLock {
      let statement = try prepare("UPDATE knowledge_documents SET source_byte_count = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, sqlite3_int64(max(0, sourceByteCount)))
      bind(documentID.uuidString, at: 2, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func currentRevision(documentID: UUID) throws -> KnowledgeDocumentRevision? {
    try withLock {
      let sql = """
      SELECT r.id, r.document_id, r.original_hash, r.normalized_hash,
             r.parser_version, r.imported_at, r.source_modified_at,
             r.original_storage_ref, r.normalized_storage_ref
      FROM knowledge_revisions r
      JOIN knowledge_documents d ON d.current_revision_id = r.id
      WHERE d.id = ? LIMIT 1;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      bind(documentID.uuidString, at: 1, to: statement)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        return decodeRevision(statement)
      }
      guard result == SQLITE_DONE else { throw databaseError() }
      return nil
    }
  }

  func revisions(documentID: UUID) throws -> [KnowledgeDocumentRevision] {
    try withLock {
      let statement = try prepare("""
      SELECT id, document_id, original_hash, normalized_hash,
             parser_version, imported_at, source_modified_at,
             original_storage_ref, normalized_storage_ref
      FROM knowledge_revisions
      WHERE document_id = ?
      ORDER BY imported_at DESC, id ASC;
      """)
      defer { sqlite3_finalize(statement) }
      bind(documentID.uuidString, at: 1, to: statement)
      var output: [KnowledgeDocumentRevision] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(decodeRevision(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func revision(id: UUID) throws -> KnowledgeDocumentRevision? {
    try withLock {
      let statement = try prepare("""
      SELECT id, document_id, original_hash, normalized_hash,
             parser_version, imported_at, source_modified_at,
             original_storage_ref, normalized_storage_ref
      FROM knowledge_revisions WHERE id = ? LIMIT 1;
      """)
      defer { sqlite3_finalize(statement) }
      bind(id.uuidString, at: 1, to: statement)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW { return decodeRevision(statement) }
      guard result == SQLITE_DONE else { throw databaseError() }
      return nil
    }
  }

  func existingDocument(
    sourceURL: URL?,
    originalHash: String,
    normalizedHash: String,
    parserVersion: Int
  ) throws -> (document: KnowledgeDocument, identical: Bool)? {
    try withLock {
      let source = sourceURL?.absoluteString.nilIfEmpty
      let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             r.original_hash, r.normalized_hash, r.parser_version
      FROM knowledge_documents d
      JOIN knowledge_revisions r ON r.id = d.current_revision_id
      WHERE (? IS NOT NULL AND d.source_url = ?)
         OR r.original_hash = ?
         OR r.normalized_hash = ?
      ORDER BY CASE WHEN (? IS NOT NULL AND d.source_url = ?) THEN 0 ELSE 1 END
      LIMIT 1;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      bindOptional(source, at: 1, to: statement)
      bindOptional(source, at: 2, to: statement)
      bind(originalHash, at: 3, to: statement)
      bind(normalizedHash, at: 4, to: statement)
      bindOptional(source, at: 5, to: statement)
      bindOptional(source, at: 6, to: statement)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        let document = decodeDocument(statement, offset: 0)
        let storedOriginalHash = text(statement, 16) ?? ""
        let storedNormalizedHash = text(statement, 17) ?? ""
        let storedParserVersion = Int(sqlite3_column_int64(statement, 18))
        return (
          document,
          storedParserVersion == parserVersion
            && (storedOriginalHash == originalHash || storedNormalizedHash == normalizedHash)
        )
      }
      guard result == SQLITE_DONE else { throw databaseError() }
      return nil
    }
  }

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
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  @discardableResult
  func restoreRevision(documentID: UUID, revisionID: UUID) throws -> KnowledgeDocument {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let revisionStatement = try prepare("""
        SELECT 1 FROM knowledge_revisions
        WHERE id = ? AND document_id = ? LIMIT 1;
        """)
        bind(revisionID.uuidString, at: 1, to: revisionStatement)
        bind(documentID.uuidString, at: 2, to: revisionStatement)
        let revisionResult = sqlite3_step(revisionStatement)
        sqlite3_finalize(revisionStatement)
        guard revisionResult == SQLITE_ROW else {
          if revisionResult != SQLITE_DONE { throw databaseError() }
          throw KnowledgeLibraryError.missingRevision
        }

        let updateStatement = try prepare("""
        UPDATE knowledge_documents
        SET current_revision_id = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """)
        bind(revisionID.uuidString, at: 1, to: updateStatement)
        sqlite3_bind_double(updateStatement, 2, Date().timeIntervalSince1970)
        bind(documentID.uuidString, at: 3, to: updateStatement)
        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
          sqlite3_finalize(updateStatement)
          throw databaseError()
        }
        let updatedCount = sqlite3_changes(handle)
        sqlite3_finalize(updateStatement)
        guard updatedCount == 1 else { throw KnowledgeLibraryError.missingDocument }

        guard let document = try documentUnlocked(id: documentID) else {
          throw KnowledgeLibraryError.missingDocument
        }
        try deleteSearchRows(documentID: documentID)
        try insertSearchRows(revisionID: revisionID, document: document)
        try executeUnlocked("COMMIT;")
        return document
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) throws {
    try withLock {
      let statement = try prepare("UPDATE knowledge_documents SET allows_ai_use = ?, updated_at = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int(statement, 1, allowsAIUse ? 1 : 0)
      sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
      bind(documentID.uuidString, at: 3, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let statement = try prepare("""
        UPDATE knowledge_documents
        SET allows_ai_use = ?, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          sqlite3_bind_int(statement, 1, allowsAIUse ? 1 : 0)
          sqlite3_bind_double(statement, 2, now)
          bind(documentID.uuidString, at: 3, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
          guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
        }
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func moveToRecycleBin(documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let archiveStatement = try prepare("""
        UPDATE knowledge_documents
        SET is_archived = 1, updated_at = ?
        WHERE id = ? AND is_archived = 0;
        """)
        let recycleStatement = try prepare("""
        INSERT INTO knowledge_recycle_bin (document_id, deleted_at)
        VALUES (?, ?)
        ON CONFLICT(document_id) DO UPDATE SET deleted_at = excluded.deleted_at;
        """)
        defer {
          sqlite3_finalize(archiveStatement)
          sqlite3_finalize(recycleStatement)
        }
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          sqlite3_reset(archiveStatement)
          sqlite3_clear_bindings(archiveStatement)
          sqlite3_bind_double(archiveStatement, 1, now)
          bind(documentID.uuidString, at: 2, to: archiveStatement)
          guard sqlite3_step(archiveStatement) == SQLITE_DONE else { throw databaseError() }
          guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }

          sqlite3_reset(recycleStatement)
          sqlite3_clear_bindings(recycleStatement)
          bind(documentID.uuidString, at: 1, to: recycleStatement)
          sqlite3_bind_double(recycleStatement, 2, now)
          guard sqlite3_step(recycleStatement) == SQLITE_DONE else { throw databaseError() }
        }
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func restoreFromRecycleBin(documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let restoreStatement = try prepare("""
        UPDATE knowledge_documents
        SET is_archived = 0, updated_at = ?
        WHERE id = ? AND is_archived = 1;
        """)
        let clearStatement = try prepare("DELETE FROM knowledge_recycle_bin WHERE document_id = ?;")
        defer {
          sqlite3_finalize(restoreStatement)
          sqlite3_finalize(clearStatement)
        }
        let now = Date().timeIntervalSince1970
        for documentID in documentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          sqlite3_reset(restoreStatement)
          sqlite3_clear_bindings(restoreStatement)
          sqlite3_bind_double(restoreStatement, 1, now)
          bind(documentID.uuidString, at: 2, to: restoreStatement)
          guard sqlite3_step(restoreStatement) == SQLITE_DONE else { throw databaseError() }
          guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }

          sqlite3_reset(clearStatement)
          sqlite3_clear_bindings(clearStatement)
          bind(documentID.uuidString, at: 1, to: clearStatement)
          guard sqlite3_step(clearStatement) == SQLITE_DONE else { throw databaseError() }
        }
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func pinnedDocumentIDs() throws -> Set<UUID> {
    try withLock {
      let statement = try prepare("SELECT document_id FROM knowledge_pinned_documents;")
      defer { sqlite3_finalize(statement) }
      var output = Set<UUID>()
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let value = text(statement, 0), let id = UUID(uuidString: value) else { continue }
        output.insert(id)
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func setPinned(_ pinned: Bool, documentID: UUID) throws {
    try withLock {
      let sql = pinned
        ? "INSERT OR IGNORE INTO knowledge_pinned_documents (document_id) VALUES (?);"
        : "DELETE FROM knowledge_pinned_documents WHERE document_id = ?;"
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      bind(documentID.uuidString, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      if pinned, sqlite3_changes(handle) == 0 {
        let documentStatement = try prepare("SELECT 1 FROM knowledge_documents WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(documentStatement) }
        bind(documentID.uuidString, at: 1, to: documentStatement)
        guard sqlite3_step(documentStatement) == SQLITE_ROW else {
          throw KnowledgeLibraryError.missingDocument
        }
      }
    }
  }

  func annotations(documentID: UUID) throws -> [KnowledgeAnnotation] {
    try withLock {
      let statement = try prepare("""
      SELECT id, document_id, revision_id, chunk_id, locator,
             highlighted_text, note, created_at, updated_at
      FROM knowledge_annotations
      WHERE document_id = ?
      ORDER BY updated_at DESC, created_at DESC;
      """)
      defer { sqlite3_finalize(statement) }
      bind(documentID.uuidString, at: 1, to: statement)
      var output: [KnowledgeAnnotation] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(decodeAnnotation(statement))
      }
      try checkStatementCompletion(statement)
      return output
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
      let statement = try prepare("""
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
      """)
      defer { sqlite3_finalize(statement) }
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

  func deleteAnnotation(id: UUID) throws {
    try withLock {
      let statement = try prepare("DELETE FROM knowledge_annotations WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      bind(id.uuidString, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      guard sqlite3_changes(handle) == 1 else { throw KnowledgeLibraryError.missingDocument }
    }
  }

  func backlinks(documentID: UUID) throws -> [KnowledgeBacklink] {
    try withLock {
      let statement = try prepare("""
      SELECT b.id, b.cited_document_id, b.chunk_id, b.target_kind, b.target_id,
             b.target_title, b.target_location, b.created_at,
             COALESCE(c.locator, c.heading_path), c.content
      FROM knowledge_backlinks b
      JOIN knowledge_chunks c ON c.id = b.chunk_id
      WHERE b.cited_document_id = ?
      ORDER BY b.created_at DESC, b.target_title COLLATE NOCASE ASC, c.ordinal ASC;
      """)
      defer { sqlite3_finalize(statement) }
      bind(documentID.uuidString, at: 1, to: statement)
      var output: [KnowledgeBacklink] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(decodeBacklink(statement))
      }
      try checkStatementCompletion(statement)
      return output
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
        let statement = try prepare("""
        INSERT INTO knowledge_backlinks (
          id, cited_document_id, chunk_id, target_kind, target_id,
          target_title, target_location, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cited_document_id, chunk_id, target_kind, target_id)
        DO UPDATE SET
          target_title = excluded.target_title,
          target_location = excluded.target_location,
          created_at = excluded.created_at;
        """)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
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
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func deleteDocument(id: UUID) throws -> KnowledgeDatabaseDeletionOutcome {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let storageReferences = try storageReferencesUnlocked(documentID: id)
        try deleteSearchRows(documentID: id)
        let statement = try prepare("DELETE FROM knowledge_documents WHERE id = ?;")
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
          sqlite3_finalize(statement)
          throw databaseError()
        }
        sqlite3_finalize(statement)
        guard sqlite3_changes(handle) == 1 else {
          throw KnowledgeLibraryError.missingDocument
        }
        let unreferencedStorageReferences = try Set(storageReferences.filter { reference in
          try !storageReferenceIsInUseUnlocked(reference)
        })
        try executeUnlocked("COMMIT;")
        return KnowledgeDatabaseDeletionOutcome(
          unreferencedStorageReferences: unreferencedStorageReferences
        )
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  private func storageReferencesUnlocked(documentID: UUID) throws -> Set<String> {
    let statement = try prepare("""
    SELECT original_storage_ref, normalized_storage_ref
    FROM knowledge_revisions
    WHERE document_id = ?;
    """)
    defer { sqlite3_finalize(statement) }
    bind(documentID.uuidString, at: 1, to: statement)
    var references = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      if let originalReference = text(statement, 0)?.nilIfEmpty {
        references.insert(originalReference)
      }
      if let normalizedReference = text(statement, 1)?.nilIfEmpty {
        references.insert(normalizedReference)
      }
    }
    try checkStatementCompletion(statement)
    return references
  }

  private func storageReferenceIsInUseUnlocked(_ reference: String) throws -> Bool {
    let statement = try prepare("""
    SELECT 1
    FROM knowledge_revisions
    WHERE original_storage_ref = ? OR normalized_storage_ref = ?
    LIMIT 1;
    """)
    defer { sqlite3_finalize(statement) }
    bind(reference, at: 1, to: statement)
    bind(reference, at: 2, to: statement)
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  func search(
    query: String,
    limit: Int,
    onlyAIAllowed: Bool,
    documentIDs: Set<UUID>? = nil
  ) throws -> [KnowledgeSearchResult] {
    let trimmed = query.trimmedForPublishing
    guard !trimmed.isEmpty, limit > 0 else { return [] }

    return try withLock {
      let ftsResults = try searchFTS(
        query: trimmed,
        limit: limit,
        onlyAIAllowed: onlyAIAllowed,
        documentIDs: documentIDs
      )
      if !ftsResults.isEmpty {
        return ftsResults
      }
      return try searchLike(
        query: trimmed,
        limit: limit,
        onlyAIAllowed: onlyAIAllowed,
        documentIDs: documentIDs
      )
    }
  }

  func semanticIndexRecords() throws -> [KnowledgeSemanticIndexRecord] {
    try withLock {
      let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
             c.locator, c.content, c.token_estimate, c.content_hash
      FROM knowledge_chunks c
      JOIN knowledge_documents d ON d.id = c.document_id
      WHERE c.revision_id = d.current_revision_id
        AND d.is_archived = 0
      ORDER BY d.updated_at DESC, c.ordinal ASC;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      var output: [KnowledgeSemanticIndexRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(KnowledgeSemanticIndexRecord(
          document: decodeDocument(statement, offset: 0),
          chunk: decodeChunk(statement, offset: 16)
        ))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func semanticIndexRecordsNeedingRepair(
    modelIdentifier: String,
    expectedDimension: Int
  ) throws -> [KnowledgeSemanticIndexRecord] {
    guard expectedDimension > 0 else { return [] }
    return try withLock {
      let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
             c.locator, c.content, c.token_estimate, c.content_hash,
             e.revision_id, e.dimension, e.vector
      FROM knowledge_chunks c
      JOIN knowledge_documents d ON d.id = c.document_id
      LEFT JOIN knowledge_chunk_embeddings e
        ON e.chunk_id = c.id AND e.model_id = ?
      WHERE c.revision_id = d.current_revision_id
        AND d.is_archived = 0
      ORDER BY d.updated_at DESC, c.ordinal ASC;
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      bind(modelIdentifier, at: 1, to: statement)
      var output: [KnowledgeSemanticIndexRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let chunk = decodeChunk(statement, offset: 16)
        let storedRevisionID = text(statement, 25).flatMap(UUID.init(uuidString:))
        let storedDimension = Int(sqlite3_column_int64(statement, 26))
        let storedVector = decodeVector(statement, index: 27, dimension: expectedDimension)
        let needsRepair = storedRevisionID != chunk.revisionID
          || storedDimension != expectedDimension
          || !isValidStoredSemanticVector(storedVector, expectedDimension: expectedDimension)
        guard needsRepair else { continue }
        output.append(KnowledgeSemanticIndexRecord(
          document: decodeDocument(statement, offset: 0),
          chunk: chunk
        ))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func upsertSemanticEmbeddings(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    guard !embeddings.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func replaceSemanticEmbeddings(
    documentIDs: Set<UUID>,
    embeddings: [KnowledgeChunkEmbedding]
  ) throws {
    guard !documentIDs.isEmpty else { return }
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try deleteSemanticEmbeddingsUnlocked(documentIDs: documentIDs)
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func semanticSearch(
    queryVector: KnowledgeSemanticVector,
    limit: Int,
    onlyAIAllowed: Bool,
    documentIDs: Set<UUID>? = nil
  ) throws -> [KnowledgeSearchResult] {
    guard !queryVector.isEmpty, limit > 0 else { return [] }
    return try withLock {
      let idClause = documentIDClause(documentIDs)
      let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
             c.locator, c.content, c.token_estimate, c.content_hash,
             e.vector
      FROM knowledge_chunk_embeddings e
      JOIN knowledge_chunks c ON c.id = e.chunk_id
      JOIN knowledge_documents d ON d.id = c.document_id
      WHERE e.model_id = ?
        AND e.dimension = ?
        AND e.revision_id = c.revision_id
        AND c.revision_id = d.current_revision_id
        AND d.is_archived = 0
        AND (? = 0 OR d.allows_ai_use = 1)
        \(idClause.sql)
      """
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      var index: Int32 = 1
      bind(queryVector.modelIdentifier, at: index, to: statement)
      index += 1
      sqlite3_bind_int64(statement, index, sqlite3_int64(queryVector.values.count))
      index += 1
      sqlite3_bind_int(statement, index, onlyAIAllowed ? 1 : 0)
      index += 1
      for id in idClause.ids {
        bind(id.uuidString, at: index, to: statement)
        index += 1
      }

      var output: [KnowledgeSearchResult] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let storedVector = decodeVector(statement, index: 25, dimension: queryVector.values.count)
        guard isValidStoredSemanticVector(
          storedVector,
          expectedDimension: queryVector.values.count
        ) else { continue }
        let similarity = cosineSimilarity(queryVector.values, storedVector)
        guard similarity >= queryVector.minimumSimilarity else { continue }
        output.append(KnowledgeSearchResult(
          document: decodeDocument(statement, offset: 0),
          chunk: decodeChunk(statement, offset: 16),
          score: similarity,
          signals: [.semantic]
        ))
      }
      try checkStatementCompletion(statement)
      return output
        .sorted {
          if $0.score != $1.score { return $0.score > $1.score }
          if $0.document.updatedAt != $1.document.updatedAt {
            return $0.document.updatedAt > $1.document.updatedAt
          }
          return $0.chunk.ordinal < $1.chunk.ordinal
        }
        .prefix(limit)
        .map { $0 }
    }
  }

  private func migrate(from existingUserVersion: Int) throws {
    guard existingUserVersion <= Self.currentSchemaVersion else {
      throw KnowledgeLibraryError.unsupportedDatabaseVersion(
        found: existingUserVersion,
        supported: Self.currentSchemaVersion
      )
    }

    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      try execute("""
    CREATE TABLE IF NOT EXISTS knowledge_folders (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL COLLATE NOCASE UNIQUE,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS knowledge_documents (
      id TEXT PRIMARY KEY NOT NULL,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      authors_json TEXT NOT NULL,
      language TEXT,
      summary TEXT NOT NULL,
      tags_json TEXT NOT NULL,
      source_url TEXT,
      source_name TEXT NOT NULL,
      folder_id TEXT REFERENCES knowledge_folders(id) ON DELETE SET NULL,
      source_byte_count INTEGER NOT NULL DEFAULT 0,
      allows_ai_use INTEGER NOT NULL DEFAULT 1,
      is_archived INTEGER NOT NULL DEFAULT 0,
      imported_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      current_revision_id TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS knowledge_revisions (
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      original_hash TEXT NOT NULL,
      normalized_hash TEXT NOT NULL,
      parser_version INTEGER NOT NULL,
      imported_at REAL NOT NULL,
      source_modified_at REAL,
      original_storage_ref TEXT,
      normalized_storage_ref TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS knowledge_revisions_document_idx
      ON knowledge_revisions(document_id, imported_at DESC);
    CREATE INDEX IF NOT EXISTS knowledge_revisions_hash_idx
      ON knowledge_revisions(original_hash, normalized_hash);
    CREATE UNIQUE INDEX IF NOT EXISTS knowledge_documents_source_url_idx
      ON knowledge_documents(source_url) WHERE source_url IS NOT NULL;

    CREATE TABLE IF NOT EXISTS knowledge_chunks (
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      revision_id TEXT NOT NULL REFERENCES knowledge_revisions(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL,
      heading_path TEXT,
      locator TEXT,
      content TEXT NOT NULL,
      token_estimate INTEGER NOT NULL,
      content_hash TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS knowledge_chunks_document_idx
      ON knowledge_chunks(document_id, revision_id, ordinal);

    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_chunks_fts USING fts5(
      chunk_id UNINDEXED,
      document_id UNINDEXED,
      title,
      authors,
      heading,
      content,
      tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE TABLE IF NOT EXISTS knowledge_chunk_embeddings (
      chunk_id TEXT NOT NULL REFERENCES knowledge_chunks(id) ON DELETE CASCADE,
      revision_id TEXT NOT NULL REFERENCES knowledge_revisions(id) ON DELETE CASCADE,
      model_id TEXT NOT NULL,
      dimension INTEGER NOT NULL,
      vector BLOB NOT NULL,
      created_at REAL NOT NULL,
      PRIMARY KEY (chunk_id, model_id)
    );

    CREATE INDEX IF NOT EXISTS knowledge_chunk_embeddings_model_idx
      ON knowledge_chunk_embeddings(model_id, revision_id);

    CREATE TABLE IF NOT EXISTS knowledge_pinned_documents (
      document_id TEXT PRIMARY KEY NOT NULL
        REFERENCES knowledge_documents(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS knowledge_recycle_bin (
      document_id TEXT PRIMARY KEY NOT NULL
        REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      deleted_at REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS knowledge_recycle_bin_deleted_idx
      ON knowledge_recycle_bin(deleted_at DESC);

    CREATE TABLE IF NOT EXISTS knowledge_annotations (
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL
        REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      revision_id TEXT
        REFERENCES knowledge_revisions(id) ON DELETE SET NULL,
      chunk_id TEXT
        REFERENCES knowledge_chunks(id) ON DELETE SET NULL,
      locator TEXT,
      highlighted_text TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS knowledge_annotations_document_idx
      ON knowledge_annotations(document_id, updated_at DESC);

    CREATE TABLE IF NOT EXISTS knowledge_backlinks (
      id TEXT PRIMARY KEY NOT NULL,
      cited_document_id TEXT NOT NULL
        REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      chunk_id TEXT NOT NULL
        REFERENCES knowledge_chunks(id) ON DELETE CASCADE,
      target_kind TEXT NOT NULL,
      target_id TEXT NOT NULL,
      target_title TEXT NOT NULL,
      target_location TEXT,
      created_at REAL NOT NULL,
      UNIQUE(cited_document_id, chunk_id, target_kind, target_id)
    );

    CREATE INDEX IF NOT EXISTS knowledge_backlinks_document_idx
      ON knowledge_backlinks(cited_document_id, created_at DESC);
    """)

      if try !columnExists("folder_id", in: "knowledge_documents") {
        try execute("""
      ALTER TABLE knowledge_documents
      ADD COLUMN folder_id TEXT REFERENCES knowledge_folders(id) ON DELETE SET NULL;
      """)
      }
      if try !columnExists("source_byte_count", in: "knowledge_documents") {
        try execute("""
      ALTER TABLE knowledge_documents
      ADD COLUMN source_byte_count INTEGER NOT NULL DEFAULT 0;
      """)
      }
      try execute("""
      CREATE INDEX IF NOT EXISTS knowledge_documents_folder_idx
        ON knowledge_documents(folder_id, imported_at DESC);
      INSERT OR IGNORE INTO knowledge_recycle_bin (document_id, deleted_at)
        SELECT id, updated_at FROM knowledge_documents WHERE is_archived = 1;
      PRAGMA user_version = \(Self.currentSchemaVersion);
      """)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func backupInspectionUnlocked(
    validateIntegrity: Bool
  ) throws -> KnowledgeDatabaseBackupInspection {
    if validateIntegrity {
      let quickCheck = try prepare("PRAGMA quick_check;")
      defer { sqlite3_finalize(quickCheck) }
      guard sqlite3_step(quickCheck) == SQLITE_ROW,
            text(quickCheck, 0)?.lowercased() == "ok" else {
        throw KnowledgeLibraryBackupError.databaseIntegrity(
          text(quickCheck, 0) ?? "PRAGMA quick_check 未通过"
        )
      }

      let foreignKeyCheck = try prepare("PRAGMA foreign_key_check;")
      defer { sqlite3_finalize(foreignKeyCheck) }
      let foreignKeyResult = sqlite3_step(foreignKeyCheck)
      guard foreignKeyResult == SQLITE_DONE else {
        let table = text(foreignKeyCheck, 0) ?? "未知数据表"
        throw KnowledgeLibraryBackupError.databaseIntegrity("外键约束无效：\(table)")
      }
    }

    let referenceStatement = try prepare("""
    SELECT original_storage_ref
    FROM knowledge_revisions
    WHERE original_storage_ref IS NOT NULL AND original_storage_ref <> ''
    UNION
    SELECT normalized_storage_ref
    FROM knowledge_revisions
    WHERE normalized_storage_ref <> '';
    """)
    defer { sqlite3_finalize(referenceStatement) }
    var references = Set<String>()
    while sqlite3_step(referenceStatement) == SQLITE_ROW {
      if let reference = text(referenceStatement, 0) {
        references.insert(reference)
      }
    }
    try checkStatementCompletion(referenceStatement)

    let titleStatement = try prepare("""
    SELECT title FROM knowledge_documents
    ORDER BY updated_at DESC, title COLLATE NOCASE ASC
    LIMIT 5;
    """)
    defer { sqlite3_finalize(titleStatement) }
    var titles: [String] = []
    while sqlite3_step(titleStatement) == SQLITE_ROW {
      if let title = text(titleStatement, 0) { titles.append(title) }
    }
    try checkStatementCompletion(titleStatement)

    return KnowledgeDatabaseBackupInspection(
      userVersion: try scalarIntUnlocked("PRAGMA user_version;"),
      documentCount: try scalarIntUnlocked("SELECT COUNT(*) FROM knowledge_documents;"),
      folderCount: try scalarIntUnlocked("SELECT COUNT(*) FROM knowledge_folders;"),
      revisionCount: try scalarIntUnlocked("SELECT COUNT(*) FROM knowledge_revisions;"),
      chunkCount: try scalarIntUnlocked("SELECT COUNT(*) FROM knowledge_chunks;"),
      storageReferences: references,
      sampleTitles: titles
    )
  }

  private func scalarIntUnlocked(_ sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func upsertDocument(_ document: KnowledgeDocument) throws {
    let sql = """
    INSERT INTO knowledge_documents (
      id, kind, title, authors_json, language, summary, tags_json,
      source_url, source_name, folder_id, source_byte_count,
      allows_ai_use, is_archived, imported_at, updated_at, current_revision_id
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      kind = excluded.kind,
      title = excluded.title,
      authors_json = excluded.authors_json,
      language = excluded.language,
      summary = excluded.summary,
      tags_json = excluded.tags_json,
      source_url = excluded.source_url,
      source_name = excluded.source_name,
      folder_id = excluded.folder_id,
      source_byte_count = excluded.source_byte_count,
      allows_ai_use = excluded.allows_ai_use,
      is_archived = excluded.is_archived,
      updated_at = excluded.updated_at,
      current_revision_id = excluded.current_revision_id;
    """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bind(document.id.uuidString, at: 1, to: statement)
    bind(document.kind.rawValue, at: 2, to: statement)
    bind(document.title, at: 3, to: statement)
    bind(json(document.authors), at: 4, to: statement)
    bindOptional(document.language, at: 5, to: statement)
    bind(document.summary, at: 6, to: statement)
    bind(json(document.tags), at: 7, to: statement)
    bindOptional(document.sourceURL?.absoluteString, at: 8, to: statement)
    bind(document.sourceName, at: 9, to: statement)
    bindOptional(document.folderID?.uuidString, at: 10, to: statement)
    sqlite3_bind_int64(statement, 11, sqlite3_int64(document.sourceByteCount))
    sqlite3_bind_int(statement, 12, document.allowsAIUse ? 1 : 0)
    sqlite3_bind_int(statement, 13, document.isArchived ? 1 : 0)
    sqlite3_bind_double(statement, 14, document.importedAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 15, document.updatedAt.timeIntervalSince1970)
    bind(document.currentRevisionID.uuidString, at: 16, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func documentUnlocked(id: UUID) throws -> KnowledgeDocument? {
    let statement = try prepare("""
    SELECT id, kind, title, authors_json, language, summary, tags_json,
           source_url, source_name, folder_id, source_byte_count,
           allows_ai_use, is_archived,
           imported_at, updated_at, current_revision_id
    FROM knowledge_documents WHERE id = ? LIMIT 1;
    """)
    defer { sqlite3_finalize(statement) }
    bind(id.uuidString, at: 1, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return decodeDocument(statement, offset: 0) }
    guard result == SQLITE_DONE else { throw databaseError() }
    return nil
  }

  private func insertRevision(_ revision: KnowledgeDocumentRevision) throws {
    let sql = """
    INSERT INTO knowledge_revisions (
      id, document_id, original_hash, normalized_hash, parser_version,
      imported_at, source_modified_at, original_storage_ref, normalized_storage_ref
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bind(revision.id.uuidString, at: 1, to: statement)
    bind(revision.documentID.uuidString, at: 2, to: statement)
    bind(revision.originalContentHash, at: 3, to: statement)
    bind(revision.normalizedContentHash, at: 4, to: statement)
    sqlite3_bind_int(statement, 5, Int32(revision.parserVersion))
    sqlite3_bind_double(statement, 6, revision.importedAt.timeIntervalSince1970)
    bindOptional(revision.sourceModifiedAt?.timeIntervalSince1970, at: 7, to: statement)
    bindOptional(revision.originalStorageReference, at: 8, to: statement)
    bind(revision.normalizedStorageReference, at: 9, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func insertChunks(_ chunks: [KnowledgeChunk], document: KnowledgeDocument) throws {
    let chunkSQL = """
    INSERT INTO knowledge_chunks (
      id, document_id, revision_id, ordinal, heading_path, locator,
      content, token_estimate, content_hash
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    """
    let ftsSQL = """
    INSERT INTO knowledge_chunks_fts (
      chunk_id, document_id, title, authors, heading, content
    ) VALUES (?, ?, ?, ?, ?, ?);
    """
    let chunkStatement = try prepare(chunkSQL)
    let ftsStatement = try prepare(ftsSQL)
    defer {
      sqlite3_finalize(chunkStatement)
      sqlite3_finalize(ftsStatement)
    }

    for chunk in chunks {
      sqlite3_reset(chunkStatement)
      sqlite3_clear_bindings(chunkStatement)
      bind(chunk.id.uuidString, at: 1, to: chunkStatement)
      bind(chunk.documentID.uuidString, at: 2, to: chunkStatement)
      bind(chunk.revisionID.uuidString, at: 3, to: chunkStatement)
      sqlite3_bind_int64(chunkStatement, 4, sqlite3_int64(chunk.ordinal))
      bindOptional(chunk.headingPath, at: 5, to: chunkStatement)
      bindOptional(chunk.locator, at: 6, to: chunkStatement)
      bind(chunk.content, at: 7, to: chunkStatement)
      sqlite3_bind_int64(chunkStatement, 8, sqlite3_int64(chunk.tokenEstimate))
      bind(chunk.contentHash, at: 9, to: chunkStatement)
      guard sqlite3_step(chunkStatement) == SQLITE_DONE else { throw databaseError() }

      sqlite3_reset(ftsStatement)
      sqlite3_clear_bindings(ftsStatement)
      bind(chunk.id.uuidString, at: 1, to: ftsStatement)
      bind(chunk.documentID.uuidString, at: 2, to: ftsStatement)
      bind(document.title, at: 3, to: ftsStatement)
      bind(document.authors.joined(separator: " "), at: 4, to: ftsStatement)
      bind(chunk.headingPath ?? "", at: 5, to: ftsStatement)
      bind(chunk.content, at: 6, to: ftsStatement)
      guard sqlite3_step(ftsStatement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  private func insertSearchRows(
    revisionID: UUID,
    document: KnowledgeDocument
  ) throws {
    let statement = try prepare("""
    INSERT INTO knowledge_chunks_fts (
      chunk_id, document_id, title, authors, heading, content
    )
    SELECT id, document_id, ?, ?, COALESCE(heading_path, ''), content
    FROM knowledge_chunks
    WHERE document_id = ? AND revision_id = ?
    ORDER BY ordinal ASC;
    """)
    defer { sqlite3_finalize(statement) }
    bind(document.title, at: 1, to: statement)
    bind(document.authors.joined(separator: " "), at: 2, to: statement)
    bind(document.id.uuidString, at: 3, to: statement)
    bind(revisionID.uuidString, at: 4, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func deleteSemanticEmbeddingsUnlocked(documentIDs: Set<UUID>) throws {
    guard !documentIDs.isEmpty else { return }
    let sortedIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }
    let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
    let statement = try prepare("""
    DELETE FROM knowledge_chunk_embeddings
    WHERE chunk_id IN (
      SELECT id FROM knowledge_chunks WHERE document_id IN (\(placeholders))
    );
    """)
    defer { sqlite3_finalize(statement) }
    for (offset, id) in sortedIDs.enumerated() {
      bind(id.uuidString, at: Int32(offset + 1), to: statement)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func upsertSemanticEmbeddingsUnlocked(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    guard !embeddings.isEmpty else { return }
    let statement = try prepare("""
    INSERT INTO knowledge_chunk_embeddings (
      chunk_id, revision_id, model_id, dimension, vector, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(chunk_id, model_id) DO UPDATE SET
      revision_id = excluded.revision_id,
      dimension = excluded.dimension,
      vector = excluded.vector,
      created_at = excluded.created_at;
    """)
    defer { sqlite3_finalize(statement) }
    let now = Date().timeIntervalSince1970
    for embedding in embeddings where !embedding.vector.isEmpty {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(embedding.chunkID.uuidString, at: 1, to: statement)
      bind(embedding.revisionID.uuidString, at: 2, to: statement)
      bind(embedding.vector.modelIdentifier, at: 3, to: statement)
      sqlite3_bind_int64(statement, 4, sqlite3_int64(embedding.vector.values.count))
      bind(vectorData(embedding.vector.values), at: 5, to: statement)
      sqlite3_bind_double(statement, 6, now)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  private func deleteSearchRows(documentID: UUID) throws {
    let statement = try prepare("DELETE FROM knowledge_chunks_fts WHERE document_id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(documentID.uuidString, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func searchFTS(
    query: String,
    limit: Int,
    onlyAIAllowed: Bool,
    documentIDs: Set<UUID>?
  ) throws -> [KnowledgeSearchResult] {
    let idClause = documentIDClause(documentIDs)
    let sql = """
    SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
           d.tags_json, d.source_url, d.source_name, d.folder_id,
           d.source_byte_count, d.allows_ai_use, d.is_archived,
           d.imported_at, d.updated_at, d.current_revision_id,
           c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
           c.locator, c.content, c.token_estimate, c.content_hash,
           bm25(knowledge_chunks_fts, 0.0, 0.0, 5.0, 3.0, 2.0, 1.0)
    FROM knowledge_chunks_fts
    JOIN knowledge_chunks c ON c.id = knowledge_chunks_fts.chunk_id
    JOIN knowledge_documents d ON d.id = c.document_id
    WHERE knowledge_chunks_fts MATCH ?
      AND c.revision_id = d.current_revision_id
      AND d.is_archived = 0
      AND (? = 0 OR d.allows_ai_use = 1)
      \(idClause.sql)
    ORDER BY bm25(knowledge_chunks_fts, 0.0, 0.0, 5.0, 3.0, 2.0, 1.0) ASC
    LIMIT ?;
    """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    var index: Int32 = 1
    bind(ftsQuery(query), at: index, to: statement)
    index += 1
    sqlite3_bind_int(statement, index, onlyAIAllowed ? 1 : 0)
    index += 1
    for id in idClause.ids {
      bind(id.uuidString, at: index, to: statement)
      index += 1
    }
    sqlite3_bind_int64(statement, index, sqlite3_int64(limit))
    return try collectSearchResults(statement)
  }

  private func searchLike(
    query: String,
    limit: Int,
    onlyAIAllowed: Bool,
    documentIDs: Set<UUID>?
  ) throws -> [KnowledgeSearchResult] {
    let idClause = documentIDClause(documentIDs)
    let sql = """
    SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
           d.tags_json, d.source_url, d.source_name, d.folder_id,
           d.source_byte_count, d.allows_ai_use, d.is_archived,
           d.imported_at, d.updated_at, d.current_revision_id,
           c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
           c.locator, c.content, c.token_estimate, c.content_hash,
           CASE
             WHEN d.title LIKE ? ESCAPE '\\' THEN -3.0
             WHEN c.heading_path LIKE ? ESCAPE '\\' THEN -2.0
             ELSE -1.0
           END
    FROM knowledge_chunks c
    JOIN knowledge_documents d ON d.id = c.document_id
    WHERE c.revision_id = d.current_revision_id
      AND d.is_archived = 0
      AND (? = 0 OR d.allows_ai_use = 1)
      AND (d.title LIKE ? ESCAPE '\\'
        OR c.heading_path LIKE ? ESCAPE '\\'
        OR c.content LIKE ? ESCAPE '\\')
      \(idClause.sql)
    ORDER BY 26 ASC, d.updated_at DESC, c.ordinal ASC
    LIMIT ?;
    """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    let like = "%\(escapedLike(query))%"
    var index: Int32 = 1
    bind(like, at: index, to: statement)
    index += 1
    bind(like, at: index, to: statement)
    index += 1
    sqlite3_bind_int(statement, index, onlyAIAllowed ? 1 : 0)
    index += 1
    bind(like, at: index, to: statement)
    index += 1
    bind(like, at: index, to: statement)
    index += 1
    bind(like, at: index, to: statement)
    index += 1
    for id in idClause.ids {
      bind(id.uuidString, at: index, to: statement)
      index += 1
    }
    sqlite3_bind_int64(statement, index, sqlite3_int64(limit))
    return try collectSearchResults(statement)
  }

  private func collectSearchResults(_ statement: OpaquePointer?) throws -> [KnowledgeSearchResult] {
    var output: [KnowledgeSearchResult] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let document = decodeDocument(statement, offset: 0)
      let chunk = decodeChunk(statement, offset: 16)
      output.append(KnowledgeSearchResult(
        document: document,
        chunk: chunk,
        score: sqlite3_column_double(statement, 25),
        signals: [.fullText]
      ))
    }
    try checkStatementCompletion(statement)
    return output
  }

  private func documentIDClause(_ documentIDs: Set<UUID>?) -> (sql: String, ids: [UUID]) {
    guard let documentIDs, !documentIDs.isEmpty else { return ("", []) }
    let ids = documentIDs.sorted { $0.uuidString < $1.uuidString }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
    return ("AND d.id IN (\(placeholders))", ids)
  }

  private func decodeDocument(_ statement: OpaquePointer?, offset: Int32) -> KnowledgeDocument {
    let id = UUID(uuidString: text(statement, offset) ?? "") ?? UUID()
    let kind = KnowledgeDocumentKind(rawValue: text(statement, offset + 1) ?? "") ?? .other
    let title = text(statement, offset + 2) ?? "未命名资料"
    let authors: [String] = decodeJSON(text(statement, offset + 3))
    let language = text(statement, offset + 4)
    let summary = text(statement, offset + 5) ?? ""
    let tags: [String] = decodeJSON(text(statement, offset + 6))
    let sourceURL = text(statement, offset + 7).flatMap(URL.init(string:))
    let sourceName = text(statement, offset + 8) ?? ""
    let folderID = text(statement, offset + 9).flatMap(UUID.init(uuidString:))
    let sourceByteCount = max(0, sqlite3_column_int64(statement, offset + 10))
    let allowsAIUse = sqlite3_column_int(statement, offset + 11) != 0
    let isArchived = sqlite3_column_int(statement, offset + 12) != 0
    let importedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 13))
    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 14))
    let revisionID = UUID(uuidString: text(statement, offset + 15) ?? "") ?? UUID()
    return KnowledgeDocument(
      id: id,
      kind: kind,
      title: title,
      authors: authors,
      language: language,
      summary: summary,
      tags: tags,
      sourceURL: sourceURL,
      sourceName: sourceName,
      folderID: folderID,
      sourceByteCount: sourceByteCount,
      allowsAIUse: allowsAIUse,
      isArchived: isArchived,
      importedAt: importedAt,
      updatedAt: updatedAt,
      currentRevisionID: revisionID
    )
  }

  private func decodeFolder(_ statement: OpaquePointer?) -> KnowledgeFolder {
    KnowledgeFolder(
      id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
      name: text(statement, 1) ?? "未命名文件夹",
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
    )
  }

  private func validatedFolderName(_ name: String) throws -> String {
    let normalized = name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard !normalized.isEmpty, normalized.count <= 80 else {
      throw KnowledgeLibraryError.invalidFolderName
    }
    return normalized
  }

  private func folderNameExists(_ name: String, excluding folderID: UUID?) throws -> Bool {
    let sql: String
    if folderID == nil {
      sql = "SELECT 1 FROM knowledge_folders WHERE name = ? COLLATE NOCASE LIMIT 1;"
    } else {
      sql = "SELECT 1 FROM knowledge_folders WHERE name = ? COLLATE NOCASE AND id != ? LIMIT 1;"
    }
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bind(name, at: 1, to: statement)
    if let folderID {
      bind(folderID.uuidString, at: 2, to: statement)
    }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  private func folderExists(_ folderID: UUID) throws -> Bool {
    let statement = try prepare("SELECT 1 FROM knowledge_folders WHERE id = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(folderID.uuidString, at: 1, to: statement)
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  private func rowExistsUnlocked(_ sql: String, values: [String]) throws -> Bool {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      bind(value, at: Int32(offset + 1), to: statement)
    }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  private func decodeRevision(_ statement: OpaquePointer?) -> KnowledgeDocumentRevision {
    KnowledgeDocumentRevision(
      id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
      documentID: UUID(uuidString: text(statement, 1) ?? "") ?? UUID(),
      originalContentHash: text(statement, 2) ?? "",
      normalizedContentHash: text(statement, 3) ?? "",
      parserVersion: Int(sqlite3_column_int(statement, 4)),
      importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
      sourceModifiedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL
        ? nil
        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
      originalStorageReference: text(statement, 7),
      normalizedStorageReference: text(statement, 8) ?? ""
    )
  }

  private func decodeAnnotation(_ statement: OpaquePointer?) -> KnowledgeAnnotation {
    KnowledgeAnnotation(
      id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
      documentID: UUID(uuidString: text(statement, 1) ?? "") ?? UUID(),
      revisionID: text(statement, 2).flatMap(UUID.init(uuidString:)),
      chunkID: text(statement, 3).flatMap(UUID.init(uuidString:)),
      locator: text(statement, 4),
      highlightedText: text(statement, 5) ?? "",
      note: text(statement, 6) ?? "",
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
    )
  }

  private func decodeBacklink(_ statement: OpaquePointer?) -> KnowledgeBacklink {
    KnowledgeBacklink(
      id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
      documentID: UUID(uuidString: text(statement, 1) ?? "") ?? UUID(),
      chunkID: UUID(uuidString: text(statement, 2) ?? "") ?? UUID(),
      targetKind: KnowledgeBacklinkTargetKind(rawValue: text(statement, 3) ?? "") ?? .articleDraft,
      targetID: text(statement, 4) ?? "",
      targetTitle: text(statement, 5) ?? "未命名目标",
      targetLocation: text(statement, 6),
      chunkLocator: text(statement, 8),
      chunkExcerpt: text(statement, 9).map { String($0.prefix(240)) },
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
    )
  }

  private func decodeChunk(_ statement: OpaquePointer?, offset: Int32) -> KnowledgeChunk {
    KnowledgeChunk(
      id: UUID(uuidString: text(statement, offset) ?? "") ?? UUID(),
      documentID: UUID(uuidString: text(statement, offset + 1) ?? "") ?? UUID(),
      revisionID: UUID(uuidString: text(statement, offset + 2) ?? "") ?? UUID(),
      ordinal: Int(sqlite3_column_int64(statement, offset + 3)),
      headingPath: text(statement, offset + 4),
      locator: text(statement, offset + 5),
      content: text(statement, offset + 6) ?? "",
      tokenEstimate: Int(sqlite3_column_int64(statement, offset + 7)),
      contentHash: text(statement, offset + 8) ?? ""
    )
  }

  private func ftsQuery(_ query: String) -> String {
    let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
    let terms = query
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
    let quotedTerms = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    return (["\"\(escaped)\""] + quotedTerms).joined(separator: " OR ")
  }

  private func escapedLike(_ query: String) -> String {
    query
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private func json(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  private func decodeJSON(_ value: String?) -> [String] {
    guard let value,
          let data = value.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return decoded
  }

  private func columnExists(_ column: String, in table: String) throws -> Bool {
    try withLock {
      let statement = try prepare("PRAGMA table_info(\(table));")
      defer { sqlite3_finalize(statement) }
      while sqlite3_step(statement) == SQLITE_ROW {
        if text(statement, 1) == column { return true }
      }
      try checkStatementCompletion(statement)
      return false
    }
  }

  private func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  private func executeUnlocked(_ sql: String) throws {
    guard let handle else { throw KnowledgeLibraryError.database("数据库尚未打开") }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw KnowledgeLibraryError.database(message)
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer? {
    guard let handle else { throw KnowledgeLibraryError.database("数据库尚未打开") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw databaseError()
    }
    return statement
  }

  private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
    sqlite3_bind_text(statement, index, value, -1, knowledgeSQLiteTransient)
  }

  private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer?) {
    _ = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), knowledgeSQLiteTransient)
    }
  }

  private func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
    if let value {
      bind(value, at: index, to: statement)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func bindOptional(_ value: Double?, at index: Int32, to statement: OpaquePointer?) {
    if let value {
      sqlite3_bind_double(statement, index, value)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }

  private func vectorData(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private func decodeVector(
    _ statement: OpaquePointer?,
    index: Int32,
    dimension: Int
  ) -> [Float] {
    guard dimension > 0,
          sqlite3_column_bytes(statement, index) == dimension * MemoryLayout<Float>.size,
          let pointer = sqlite3_column_blob(statement, index) else {
      return []
    }
    var output = [Float](repeating: 0, count: dimension)
    output.withUnsafeMutableBytes { destination in
      destination.copyMemory(
        from: UnsafeRawBufferPointer(
          start: pointer,
          count: dimension * MemoryLayout<Float>.size
        )
      )
    }
    return output
  }

  private func isValidStoredSemanticVector(
    _ values: [Float],
    expectedDimension: Int
  ) -> Bool {
    guard values.count == expectedDimension, !values.isEmpty else { return false }
    var squaredMagnitude: Double = 0
    for value in values {
      guard value.isFinite else { return false }
      squaredMagnitude += Double(value * value)
    }
    // Every vector written by KnowledgeSemanticVector is normalized. A broad
    // tolerance catches zero/truncated/corrupt blobs without rejecting harmless
    // floating-point drift between OS releases.
    return squaredMagnitude.isFinite && (0.5...1.5).contains(squaredMagnitude)
  }

  private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
    var dot: Float = 0
    var lhsMagnitude: Float = 0
    var rhsMagnitude: Float = 0
    for index in lhs.indices {
      dot += lhs[index] * rhs[index]
      lhsMagnitude += lhs[index] * lhs[index]
      rhsMagnitude += rhs[index] * rhs[index]
    }
    guard lhsMagnitude > 0, rhsMagnitude > 0 else { return -1 }
    return Double(dot / sqrt(lhsMagnitude * rhsMagnitude))
  }

  private func checkStatementCompletion(_ statement: OpaquePointer?) throws {
    let result = sqlite3_errcode(handle)
    guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
      throw databaseError()
    }
    _ = statement
  }

  private func databaseError() -> KnowledgeLibraryError {
    guard let handle else { return .database("数据库尚未打开") }
    return .database(String(cString: sqlite3_errmsg(handle)))
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
