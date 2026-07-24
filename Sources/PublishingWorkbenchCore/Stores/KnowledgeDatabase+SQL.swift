import Foundation
import SQLite3

extension KnowledgeDatabase {
  func upsertDocument(_ document: KnowledgeDocument) throws {
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

  func documentUnlocked(id: UUID) throws -> KnowledgeDocument? {
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

  func insertRevision(_ revision: KnowledgeDocumentRevision) throws {
    let sql = """
    INSERT INTO knowledge_revisions (
      id, document_id, original_hash, normalized_hash, parser_version,
      imported_at, source_modified_at, original_storage_ref,
      captured_text_storage_ref, normalized_storage_ref
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
    bindOptional(revision.capturedTextStorageReference, at: 9, to: statement)
    bind(revision.normalizedStorageReference, at: 10, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  func decodeDocument(_ statement: OpaquePointer?, offset: Int32) -> KnowledgeDocument {
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

  func decodeFolder(_ statement: OpaquePointer?) -> KnowledgeFolder {
    KnowledgeFolder(
      id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
      name: text(statement, 1) ?? "未命名文件夹",
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
    )
  }

  func validatedFolderName(_ name: String) throws -> String {
    let normalized = name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard !normalized.isEmpty, normalized.count <= 80 else {
      throw KnowledgeLibraryError.invalidFolderName
    }
    return normalized
  }

  func folderNameExists(_ name: String, excluding folderID: UUID?) throws -> Bool {
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

  func folderExists(_ folderID: UUID) throws -> Bool {
    let statement = try prepare("SELECT 1 FROM knowledge_folders WHERE id = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(folderID.uuidString, at: 1, to: statement)
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  func rowExistsUnlocked(_ sql: String, values: [String]) throws -> Bool {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      bind(value, at: Int32(offset + 1), to: statement)
    }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
    return result == SQLITE_ROW
  }

  func decodeRevision(_ statement: OpaquePointer?) -> KnowledgeDocumentRevision {
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
      capturedTextStorageReference: text(statement, 8),
      normalizedStorageReference: text(statement, 9) ?? ""
    )
  }

  func decodeAnnotation(_ statement: OpaquePointer?) -> KnowledgeAnnotation {
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

  func decodeBacklink(_ statement: OpaquePointer?) -> KnowledgeBacklink {
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

  func decodeChunk(_ statement: OpaquePointer?, offset: Int32) -> KnowledgeChunk {
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

  func ftsQuery(_ query: String) -> String {
    let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
    let terms = query
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
    let quotedTerms = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    return (["\"\(escaped)\""] + quotedTerms).joined(separator: " OR ")
  }

  func escapedLike(_ query: String) -> String {
    query
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  func json(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  func decodeJSON(_ value: String?) -> [String] {
    guard let value,
          let data = value.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return decoded
  }

  func columnExists(_ column: String, in table: String) throws -> Bool {
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

  func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  func executeUnlocked(_ sql: String) throws {
    guard let handle else { throw KnowledgeLibraryError.database("数据库尚未打开") }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw KnowledgeLibraryError.database(message)
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer? {
    guard let handle else { throw KnowledgeLibraryError.database("数据库尚未打开") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw databaseError()
    }
    return statement
  }

  func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
    sqlite3_bind_text(statement, index, value, -1, knowledgeSQLiteTransient)
  }

  func bind(_ value: Data, at index: Int32, to statement: OpaquePointer?) {
    _ = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), knowledgeSQLiteTransient)
    }
  }

  func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
    if let value {
      bind(value, at: index, to: statement)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func bindOptional(_ value: Double?, at index: Int32, to statement: OpaquePointer?) {
    if let value {
      sqlite3_bind_double(statement, index, value)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }

  func checkStatementCompletion(_ statement: OpaquePointer?) throws {
    let result = sqlite3_errcode(handle)
    guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
      throw databaseError()
    }
    _ = statement
  }

  func databaseError() -> KnowledgeLibraryError {
    guard let handle else { return .database("数据库尚未打开") }
    return .database(String(cString: sqlite3_errmsg(handle)))
  }

  func withCancellationProgressHandler<T>(
    _ body: () throws -> T
  ) throws -> T {
    try Task.checkCancellation()
    guard let handle else { throw databaseError() }
    // Let SQLite abort a long scan or ORDER BY before sqlite3_step returns a row.
    sqlite3_progress_handler(
      handle,
      1_000,
      knowledgeSQLiteCancellationProgressHandler,
      nil
    )
    defer { sqlite3_progress_handler(handle, 0, nil, nil) }

    do {
      let result = try body()
      try Task.checkCancellation()
      return result
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw error
    }
  }

  func withCancellableLock<T>(_ body: () throws -> T) throws -> T {
    try Task.checkCancellation()
    // NSLock.lock() cannot observe task cancellation while another query owns it.
    while !lock.lock(before: Date(timeIntervalSinceNow: 0.02)) {
      try Task.checkCancellation()
    }
    defer { lock.unlock() }
    try Task.checkCancellation()
    return try body()
  }

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
