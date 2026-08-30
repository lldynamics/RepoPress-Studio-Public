import Foundation
import SQLite3

extension KnowledgeDatabase {
  private static let requiredSchemaTableNames = [
    "knowledge_folders",
    "knowledge_documents",
    "knowledge_revisions",
    "knowledge_chunks",
    "knowledge_chunks_fts",
    "knowledge_chunk_embeddings",
    "knowledge_pinned_documents",
    "knowledge_recycle_bin",
    "knowledge_annotations",
    "knowledge_backlinks",
  ]

  private static let requiredSchemaIndexNames = [
    "knowledge_documents_source_url_idx",
    "knowledge_documents_folder_idx",
    "knowledge_revisions_document_idx",
    "knowledge_revisions_hash_idx",
    "knowledge_chunks_document_idx",
    "knowledge_chunk_embeddings_model_idx",
    "knowledge_recycle_bin_deleted_idx",
    "knowledge_annotations_document_idx",
    "knowledge_backlinks_document_idx",
  ]

  func migrate(from existingUserVersion: Int) throws {
    guard existingUserVersion <= Self.currentSchemaVersion else {
      throw KnowledgeLibraryError.unsupportedDatabaseVersion(
        found: existingUserVersion,
        supported: Self.currentSchemaVersion
      )
    }
    guard existingUserVersion < Self.currentSchemaVersion else {
      try validateSchemaContract()
      return
    }

    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      try execute(
        """
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
          allows_ai_use INTEGER NOT NULL DEFAULT 0,
          allows_local_semantic_index INTEGER NOT NULL DEFAULT 1,
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
          captured_text_storage_ref TEXT,
          normalized_storage_ref TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS knowledge_revisions_document_idx
          ON knowledge_revisions(document_id, imported_at DESC);
        CREATE INDEX IF NOT EXISTS knowledge_revisions_hash_idx
          ON knowledge_revisions(original_hash, normalized_hash);
        DROP INDEX IF EXISTS knowledge_documents_source_url_idx;
        CREATE INDEX IF NOT EXISTS knowledge_documents_source_url_idx
          ON knowledge_documents(source_url, updated_at DESC) WHERE source_url IS NOT NULL;

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
          input_hash TEXT NOT NULL DEFAULT '',
          encoding_version TEXT NOT NULL DEFAULT 'legacy-v1',
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
        try execute(
          """
          ALTER TABLE knowledge_documents
          ADD COLUMN folder_id TEXT REFERENCES knowledge_folders(id) ON DELETE SET NULL;
          """)
      }
      if try !columnExists("source_byte_count", in: "knowledge_documents") {
        try execute(
          """
          ALTER TABLE knowledge_documents
          ADD COLUMN source_byte_count INTEGER NOT NULL DEFAULT 0;
          """)
      }
      if try !columnExists("allows_local_semantic_index", in: "knowledge_documents") {
        try execute(
          """
          ALTER TABLE knowledge_documents
          ADD COLUMN allows_local_semantic_index INTEGER NOT NULL DEFAULT 1;
          """)
      }
      if try !columnExists("captured_text_storage_ref", in: "knowledge_revisions") {
        try execute(
          """
          ALTER TABLE knowledge_revisions
          ADD COLUMN captured_text_storage_ref TEXT;
          """)
      }
      if try !columnExists("visual_anchor_json", in: "knowledge_chunks") {
        try execute("ALTER TABLE knowledge_chunks ADD COLUMN visual_anchor_json TEXT;")
      }
      if try !columnExists("input_hash", in: "knowledge_chunk_embeddings") {
        try execute(
          "ALTER TABLE knowledge_chunk_embeddings ADD COLUMN input_hash TEXT NOT NULL DEFAULT '';")
      }
      if try !columnExists("encoding_version", in: "knowledge_chunk_embeddings") {
        try execute(
          "ALTER TABLE knowledge_chunk_embeddings ADD COLUMN encoding_version TEXT NOT NULL DEFAULT 'legacy-v1';"
        )
      }
      if existingUserVersion < 8 {
        try execute("UPDATE knowledge_documents SET allows_ai_use = 0;")
      }
      try execute(
        """
        CREATE INDEX IF NOT EXISTS knowledge_documents_folder_idx
          ON knowledge_documents(folder_id, imported_at DESC);
        INSERT OR IGNORE INTO knowledge_recycle_bin (document_id, deleted_at)
          SELECT id, updated_at FROM knowledge_documents WHERE is_archived = 1;
        """)
      try validateSchemaContract()
      try validateMigrationIntegrity()
      try execute("PRAGMA user_version = \(Self.currentSchemaVersion);")
      try execute("COMMIT;")
    } catch {
      try rethrowAfterRollback(error)
    }
  }

  func validateSchemaContract() throws {
    let requiredTables = Self.requiredSchemaTableNames
    let tableList = requiredTables.map { "'\($0)'" }.joined(separator: ", ")
    let tableCount = try withLock {
      try scalarIntUnlocked(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN (\(tableList));"
      )
    }
    guard tableCount == requiredTables.count else {
      throw KnowledgeLibraryError.databaseIntegrity("资料库数据库结构不完整：缺少必需数据表。")
    }

    let requiredIndexes = Self.requiredSchemaIndexNames
    let indexList = requiredIndexes.map { "'\($0)'" }.joined(separator: ", ")
    let indexCount = try withLock {
      try scalarIntUnlocked(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN (\(indexList));"
      )
    }
    guard indexCount == requiredIndexes.count else {
      throw KnowledgeLibraryError.databaseIntegrity("资料库数据库结构不完整：缺少必需索引。")
    }

    let requiredColumns = [
      ("knowledge_documents", "folder_id"),
      ("knowledge_documents", "source_byte_count"),
      ("knowledge_documents", "allows_ai_use"),
      ("knowledge_documents", "allows_local_semantic_index"),
      ("knowledge_revisions", "captured_text_storage_ref"),
      ("knowledge_chunks", "visual_anchor_json"),
      ("knowledge_chunk_embeddings", "input_hash"),
      ("knowledge_chunk_embeddings", "encoding_version"),
    ]
    for (table, column) in requiredColumns where try !columnExists(column, in: table) {
      throw KnowledgeLibraryError.databaseIntegrity(
        "资料库数据库结构不完整：\(table) 缺少 \(column) 列。"
      )
    }
  }

  private func validateMigrationIntegrity() throws {
    try withLock {
      try withCachedStatementUnlocked("PRAGMA quick_check;") { statement in
        guard sqlite3_step(statement) == SQLITE_ROW,
          text(statement, 0)?.lowercased() == "ok",
          sqlite3_step(statement) == SQLITE_DONE
        else {
          throw KnowledgeLibraryError.databaseIntegrity(
            text(statement, 0) ?? "资料库迁移后的 quick_check 未通过。"
          )
        }
      }
      try withCachedStatementUnlocked("PRAGMA foreign_key_check;") { statement in
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw KnowledgeLibraryError.databaseIntegrity("资料库迁移后存在外键约束错误。")
        }
      }
    }
  }
}
