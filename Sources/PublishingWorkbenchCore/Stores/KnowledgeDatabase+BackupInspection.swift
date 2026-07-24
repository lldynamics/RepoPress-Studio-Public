import Foundation
import SQLite3

extension KnowledgeDatabase {
  func backupInspectionUnlocked(
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
    SELECT captured_text_storage_ref
    FROM knowledge_revisions
    WHERE captured_text_storage_ref IS NOT NULL AND captured_text_storage_ref <> ''
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

  func scalarIntUnlocked(_ sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
    return Int(sqlite3_column_int64(statement, 0))
  }
}
