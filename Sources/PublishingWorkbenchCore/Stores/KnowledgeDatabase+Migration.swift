import Foundation

extension KnowledgeDatabase {
  func migrate(from existingUserVersion: Int) throws {
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
      if try !columnExists("captured_text_storage_ref", in: "knowledge_revisions") {
        try execute("""
      ALTER TABLE knowledge_revisions
      ADD COLUMN captured_text_storage_ref TEXT;
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
}
