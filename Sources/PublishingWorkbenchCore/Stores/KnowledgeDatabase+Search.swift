import Foundation
import SQLite3

extension KnowledgeDatabase {
  func search(
    query: String,
    limit: Int,
    onlyRemoteAIAllowed: Bool,
    documentIDs: Set<UUID>? = nil
  ) throws -> [KnowledgeSearchResult] {
    try Task.checkCancellation()
    let trimmed = query.trimmedForPublishing
    guard !trimmed.isEmpty, limit > 0 else { return [] }

    return try withCancellableLock {
      try withCancellationProgressHandler {
        let ftsResults = try searchFTS(
          query: trimmed,
          limit: limit,
          onlyRemoteAIAllowed: onlyRemoteAIAllowed,
          documentIDs: documentIDs
        )
        if !ftsResults.isEmpty {
          return ftsResults
        }
        try Task.checkCancellation()
        return try searchLike(
          query: trimmed,
          limit: limit,
          onlyRemoteAIAllowed: onlyRemoteAIAllowed,
          documentIDs: documentIDs
        )
      }
    }
  }

  func semanticIndexRecords() throws -> [KnowledgeSemanticIndexRecord] {
    try withCancellableLock {
      try withCancellationProgressHandler {
        let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
             d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
             c.locator, c.content, c.token_estimate, c.content_hash
      FROM knowledge_chunks c
      JOIN knowledge_documents d ON d.id = c.document_id
      WHERE c.revision_id = d.current_revision_id
        AND d.is_archived = 0
        AND d.allows_local_semantic_index = 1
      ORDER BY d.updated_at DESC, c.ordinal ASC;
      """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var output: [KnowledgeSemanticIndexRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          try Task.checkCancellation()
          output.append(KnowledgeSemanticIndexRecord(
            document: try decodeDocument(statement, offset: 0),
            chunk: try decodeChunk(statement, offset: 17)
          ))
        }
        try Task.checkCancellation()
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func semanticIndexRecordsNeedingRepair(
    modelIdentifier: String,
    expectedDimension: Int
  ) throws -> [KnowledgeSemanticIndexRecord] {
    guard expectedDimension > 0 else { return [] }
    return try withCancellableLock {
      try withCancellationProgressHandler {
        let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
             d.is_archived,
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
        AND d.allows_local_semantic_index = 1
      ORDER BY d.updated_at DESC, c.ordinal ASC;
      """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(modelIdentifier, at: 1, to: statement)
        var output: [KnowledgeSemanticIndexRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          try Task.checkCancellation()
          let chunk = try decodeChunk(statement, offset: 17)
          let storedRevisionID = try optionalUUID(
            statement,
            26,
            field: "knowledge_chunk_embeddings.revision_id"
          )
          let storedDimension = Int(sqlite3_column_int64(statement, 27))
          let storedVector = KnowledgeSemanticVectorStorage.decodeVector(statement, index: 28, dimension: expectedDimension)
          let needsRepair = storedRevisionID != chunk.revisionID
            || storedDimension != expectedDimension
            || !KnowledgeSemanticVectorStorage.isValidStoredSemanticVector(storedVector, expectedDimension: expectedDimension)
          guard needsRepair else { continue }
          output.append(KnowledgeSemanticIndexRecord(
            document: try decodeDocument(statement, offset: 0),
            chunk: chunk
          ))
        }
        try Task.checkCancellation()
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func semanticEmbeddingChunkIDsByModelIdentifier() throws -> [String: Set<UUID>] {
    try withCancellableLock {
      try withCancellationProgressHandler {
        let statement = try prepare("""
        SELECT model_id, chunk_id
        FROM knowledge_chunk_embeddings
        ORDER BY model_id, chunk_id;
        """)
        defer { sqlite3_finalize(statement) }
        var output: [String: Set<UUID>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
          try Task.checkCancellation()
          guard let modelIdentifier = text(statement, 0)?.nilIfEmpty else {
            throw KnowledgeLibraryError.databaseIntegrity(
              "knowledge_chunk_embeddings.model_id 为空。"
            )
          }
          let chunkID = try requiredUUID(
            statement,
            1,
            field: "knowledge_chunk_embeddings.chunk_id"
          )
          output[modelIdentifier, default: []].insert(chunkID)
        }
        try Task.checkCancellation()
        try checkStatementCompletion(statement)
        return output
      }
    }
  }

  func upsertSemanticEmbeddings(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    guard !embeddings.isEmpty else { return }
    try Task.checkCancellation()
    try withCancellableLock {
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
    try Task.checkCancellation()
    try withCancellableLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try deleteSemanticEmbeddingsUnlocked(documentIDs: documentIDs)
        try Task.checkCancellation()
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try Task.checkCancellation()
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  func replaceAllSemanticEmbeddings(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    try Task.checkCancellation()
    try withCancellableLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try executeUnlocked("DELETE FROM knowledge_chunk_embeddings;")
        try Task.checkCancellation()
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try Task.checkCancellation()
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
    onlyRemoteAIAllowed: Bool,
    documentIDs: Set<UUID>? = nil
  ) throws -> [KnowledgeSearchResult] {
    guard !queryVector.isEmpty, limit > 0 else { return [] }
    try Task.checkCancellation()
    return try withCancellableLock {
      try withCancellationProgressHandler {
        let idClause = documentIDClause(documentIDs)
        let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
             d.is_archived,
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
        AND d.allows_local_semantic_index = 1
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
        sqlite3_bind_int(statement, index, onlyRemoteAIAllowed ? 1 : 0)
        index += 1
        for id in idClause.ids {
          bind(id.uuidString, at: index, to: statement)
          index += 1
        }

        var output: [KnowledgeSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
          try Task.checkCancellation()
          let storedVector = KnowledgeSemanticVectorStorage.decodeVector(statement, index: 26, dimension: queryVector.values.count)
          guard KnowledgeSemanticVectorStorage.isValidStoredSemanticVector(
            storedVector,
            expectedDimension: queryVector.values.count
          ) else { continue }
          let similarity = KnowledgeSemanticVectorStorage.cosineSimilarity(queryVector.values, storedVector)
          guard similarity >= queryVector.minimumSimilarity else { continue }
          output.append(KnowledgeSearchResult(
            document: try decodeDocument(statement, offset: 0),
            chunk: try decodeChunk(statement, offset: 17),
            score: similarity,
            signals: [.semantic]
          ))
        }
        try Task.checkCancellation()
        try checkStatementCompletion(statement)
        output.sort {
          if $0.score != $1.score { return $0.score > $1.score }
          if $0.document.updatedAt != $1.document.updatedAt {
            return $0.document.updatedAt > $1.document.updatedAt
          }
          return $0.chunk.ordinal < $1.chunk.ordinal
        }
        try Task.checkCancellation()
        return Array(output.prefix(limit))
      }
    }
  }

  func insertChunks(_ chunks: [KnowledgeChunk], document: KnowledgeDocument) throws {
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

  func insertSearchRows(
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

  func deleteSemanticEmbeddingsUnlocked(documentIDs: Set<UUID>) throws {
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

  func upsertSemanticEmbeddingsUnlocked(_ embeddings: [KnowledgeChunkEmbedding]) throws {
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
      try Task.checkCancellation()
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(embedding.chunkID.uuidString, at: 1, to: statement)
      bind(embedding.revisionID.uuidString, at: 2, to: statement)
      bind(embedding.vector.modelIdentifier, at: 3, to: statement)
      sqlite3_bind_int64(statement, 4, sqlite3_int64(embedding.vector.values.count))
      bind(KnowledgeSemanticVectorStorage.vectorData(embedding.vector.values), at: 5, to: statement)
      sqlite3_bind_double(statement, 6, now)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func deleteSearchRows(documentID: UUID) throws {
    let statement = try prepare("DELETE FROM knowledge_chunks_fts WHERE document_id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(documentID.uuidString, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  func searchFTS(
    query: String,
    limit: Int,
    onlyRemoteAIAllowed: Bool,
    documentIDs: Set<UUID>?
  ) throws -> [KnowledgeSearchResult] {
    let idClause = documentIDClause(documentIDs)
    let sql = """
    SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
           d.tags_json, d.source_url, d.source_name, d.folder_id,
           d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
           d.is_archived,
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
      sqlite3_bind_int(statement, index, onlyRemoteAIAllowed ? 1 : 0)
    index += 1
    for id in idClause.ids {
      bind(id.uuidString, at: index, to: statement)
      index += 1
    }
    sqlite3_bind_int64(statement, index, sqlite3_int64(limit))
    return try collectSearchResults(statement)
  }

  func searchLike(
    query: String,
    limit: Int,
    onlyRemoteAIAllowed: Bool,
    documentIDs: Set<UUID>?
  ) throws -> [KnowledgeSearchResult] {
    let idClause = documentIDClause(documentIDs)
    let sql = """
    SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
           d.tags_json, d.source_url, d.source_name, d.folder_id,
           d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
           d.is_archived,
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
    ORDER BY 27 ASC, d.updated_at DESC, c.ordinal ASC
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
    sqlite3_bind_int(statement, index, onlyRemoteAIAllowed ? 1 : 0)
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

  func collectSearchResults(_ statement: OpaquePointer?) throws -> [KnowledgeSearchResult] {
    var output: [KnowledgeSearchResult] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      try Task.checkCancellation()
      let document = try decodeDocument(statement, offset: 0)
      let chunk = try decodeChunk(statement, offset: 17)
      output.append(KnowledgeSearchResult(
        document: document,
        chunk: chunk,
        score: sqlite3_column_double(statement, 26),
        signals: [.fullText]
      ))
    }
    try Task.checkCancellation()
    try checkStatementCompletion(statement)
    return output
  }

  func documentIDClause(_ documentIDs: Set<UUID>?) -> (sql: String, ids: [UUID]) {
    guard let documentIDs, !documentIDs.isEmpty else { return ("", []) }
    let ids = documentIDs.sorted { $0.uuidString < $1.uuidString }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
    return ("AND d.id IN (\(placeholders))", ids)
  }
}
