import Foundation
import SQLite3

private struct KnowledgeSemanticTopKCandidate {
  let row: Int
  let score: Double
}

/// A bounded min-heap whose root is the worst retained candidate.  This keeps
/// memory and ranking work proportional to the requested limit instead of the
/// number of stored embeddings.
private struct KnowledgeSemanticTopKHeap {
  private var values: [KnowledgeSemanticTopKCandidate] = []
  private let capacity: Int
  private let index: KnowledgeSemanticVectorFlatIndex

  init(capacity: Int, index: KnowledgeSemanticVectorFlatIndex) {
    self.capacity = max(0, capacity)
    self.index = index
    values.reserveCapacity(max(0, capacity))
  }

  mutating func insert(_ candidate: KnowledgeSemanticTopKCandidate) {
    guard capacity > 0 else { return }
    if values.count < capacity {
      values.append(candidate)
      siftUp(from: values.count - 1)
      return
    }

    guard isWorse(values[0], than: candidate) else { return }
    values[0] = candidate
    siftDown(from: 0)
  }

  func sortedCandidates() -> [KnowledgeSemanticTopKCandidate] {
    values.sorted { isBetter($0, than: $1) }
  }

  private mutating func siftUp(from start: Int) {
    var child = start
    while child > 0 {
      let parent = (child - 1) / 2
      guard isWorse(values[child], than: values[parent]) else { break }
      values.swapAt(child, parent)
      child = parent
    }
  }

  private mutating func siftDown(from start: Int) {
    var parent = start
    while true {
      let left = parent * 2 + 1
      guard left < values.count else { return }
      var worst = left
      let right = left + 1
      if right < values.count && isWorse(values[right], than: values[left]) {
        worst = right
      }
      guard isWorse(values[worst], than: values[parent]) else { return }
      values.swapAt(parent, worst)
      parent = worst
    }
  }

  private func isBetter(
    _ lhs: KnowledgeSemanticTopKCandidate,
    than rhs: KnowledgeSemanticTopKCandidate
  ) -> Bool {
    isWorse(rhs, than: lhs)
  }

  private func isWorse(
    _ lhs: KnowledgeSemanticTopKCandidate,
    than rhs: KnowledgeSemanticTopKCandidate
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    let lhsEntry = index.entries[lhs.row]
    let rhsEntry = index.entries[rhs.row]
    if lhsEntry.updatedAt != rhsEntry.updatedAt {
      return lhsEntry.updatedAt < rhsEntry.updatedAt
    }
    if lhsEntry.ordinal != rhsEntry.ordinal {
      return lhsEntry.ordinal > rhsEntry.ordinal
    }
    let lhsDocumentID = lhsEntry.documentID.uuidString
    let rhsDocumentID = rhsEntry.documentID.uuidString
    if lhsDocumentID != rhsDocumentID {
      return lhsDocumentID > rhsDocumentID
    }
    let lhsChunkID = lhsEntry.chunkID.uuidString
    let rhsChunkID = rhsEntry.chunkID.uuidString
    if lhsChunkID != rhsChunkID {
      return lhsChunkID > rhsChunkID
    }
    // A row can only be duplicated by corrupt data. Keep the result
    // deterministic even in that case.
    return lhs.row > rhs.row
  }
}

extension KnowledgeDatabase {
  private func decodeRevision(
    _ statement: OpaquePointer?,
    offset: Int32
  ) throws -> KnowledgeDocumentRevision {
    KnowledgeDocumentRevision(
      id: try requiredUUID(statement, offset, field: "knowledge_revisions.id"),
      documentID: try requiredUUID(
        statement,
        offset + 1,
        field: "knowledge_revisions.document_id"
      ),
      originalContentHash: text(statement, offset + 2) ?? "",
      normalizedContentHash: text(statement, offset + 3) ?? "",
      parserVersion: Int(sqlite3_column_int(statement, offset + 4)),
      importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 5)),
      sourceModifiedAt: sqlite3_column_type(statement, offset + 6) == SQLITE_NULL
        ? nil
        : Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 6)),
      originalStorageReference: text(statement, offset + 7),
      capturedTextStorageReference: text(statement, offset + 8),
      normalizedStorageReference: text(statement, offset + 9) ?? ""
    )
  }

  /// Reads the document and its current revision under one database lock so a
  /// caller can bind explicit context to the exact revision that was read.
  func currentDocumentRevision(
    documentID: UUID
  ) throws -> (document: KnowledgeDocument, revision: KnowledgeDocumentRevision)? {
    try withCancellableLock {
      () throws -> (document: KnowledgeDocument, revision: KnowledgeDocumentRevision)? in
      try withCancellationProgressHandler {
        () throws -> (document: KnowledgeDocument, revision: KnowledgeDocumentRevision)? in
        return try withCachedStatementUnlocked(
          """
          SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
                 d.tags_json, d.source_url, d.source_name, d.folder_id,
                 d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
                 d.is_archived, d.imported_at, d.updated_at, d.current_revision_id,
                 r.id, r.document_id, r.original_hash, r.normalized_hash,
                 r.parser_version, r.imported_at, r.source_modified_at,
                 r.original_storage_ref, r.captured_text_storage_ref,
                 r.normalized_storage_ref
          FROM knowledge_documents d
          JOIN knowledge_revisions r ON r.id = d.current_revision_id
          WHERE d.id = ?
          LIMIT 1;
          """
        ) { statement in
          bind(documentID.uuidString, at: 1, to: statement)
          let result = sqlite3_step(statement)
          guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
          guard result == SQLITE_ROW else { return nil }
          return (
            document: try decodeDocument(statement, offset: 0),
            revision: try decodeRevision(statement, offset: 17)
          )
        }
      }
    }
  }

  /// Returns a chunk only when all three identity components match.  This is
  /// deliberately stricter than looking up by chunk ID alone: a stale
  /// continuation must not bind a chunk from a different revision.
  func chunk(
    id: UUID,
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeChunk? {
    try withCancellableLock {
      try withCancellationProgressHandler {
        return try withCachedStatementUnlocked(
          """
          SELECT id, document_id, revision_id, ordinal, heading_path, locator,
                 content, token_estimate, content_hash, visual_anchor_json
          FROM knowledge_chunks
          WHERE id = ? AND document_id = ? AND revision_id = ?
          LIMIT 1;
          """
        ) { statement in
          bind(id.uuidString, at: 1, to: statement)
          bind(documentID.uuidString, at: 2, to: statement)
          bind(revisionID.uuidString, at: 3, to: statement)
          let result = sqlite3_step(statement)
          guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
          guard result == SQLITE_ROW else { return nil }
          return try decodeChunk(statement, offset: 0)
        }
      }
    }
  }

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
                 c.locator, c.content, c.token_estimate, c.content_hash, c.visual_anchor_json
          FROM knowledge_chunks c
          JOIN knowledge_documents d ON d.id = c.document_id
          WHERE c.revision_id = d.current_revision_id
            AND d.is_archived = 0
            AND d.allows_local_semantic_index = 1
          ORDER BY d.updated_at DESC, c.ordinal ASC;
          """
        return try withCachedStatementUnlocked(sql) { statement in
          var output: [KnowledgeSemanticIndexRecord] = []
          while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            output.append(
              KnowledgeSemanticIndexRecord(
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
                 c.locator, c.content, c.token_estimate, c.content_hash, c.visual_anchor_json,
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
        return try withCachedStatementUnlocked(sql) { statement in
          bind(modelIdentifier, at: 1, to: statement)
          var output: [KnowledgeSemanticIndexRecord] = []
          while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            let chunk = try decodeChunk(statement, offset: 17)
            let storedRevisionID = try optionalUUID(
              statement,
              27,
              field: "knowledge_chunk_embeddings.revision_id"
            )
            let storedDimension = Int(sqlite3_column_int64(statement, 28))
            let storedVector = KnowledgeSemanticVectorStorage.decodeVector(
              statement, index: 29, dimension: expectedDimension)
            let needsRepair =
              storedRevisionID != chunk.revisionID
              || storedDimension != expectedDimension
              || !KnowledgeSemanticVectorStorage.isValidStoredSemanticVector(
                storedVector, expectedDimension: expectedDimension)
            guard needsRepair else { continue }
            output.append(
              KnowledgeSemanticIndexRecord(
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
  }

  func semanticEmbeddingChunkIDsByModelIdentifier() throws -> [String: Set<UUID>] {
    try withCancellableLock {
      try withCancellationProgressHandler {
        return try withCachedStatementUnlocked(
          """
          SELECT model_id, chunk_id
          FROM knowledge_chunk_embeddings
          ORDER BY model_id, chunk_id;
          """
        ) { statement in
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
        try rethrowAfterRollbackUnlocked(error)
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
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func replaceAllSemanticEmbeddings(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    try Task.checkCancellation()
    try withCancellableLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try executeUnlocked("DELETE FROM knowledge_chunk_embeddings;")
        invalidateSemanticFlatVectorIndexesUnlocked()
        try Task.checkCancellation()
        try upsertSemanticEmbeddingsUnlocked(embeddings)
        try Task.checkCancellation()
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
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
        let index = try semanticFlatVectorIndex(
          modelIdentifier: queryVector.modelIdentifier,
          dimension: queryVector.values.count
        )
        var heap = KnowledgeSemanticTopKHeap(capacity: limit, index: index)
        let hasDocumentFilter = documentIDs.map { !$0.isEmpty } ?? false

        for row in index.entries.indices {
          try Task.checkCancellation()
          let entry = index.entries[row]
          guard !entry.isArchived,
                entry.allowsLocalSemanticIndex,
                !onlyRemoteAIAllowed || entry.allowsRemoteAIUse,
                !hasDocumentFilter || documentIDs?.contains(entry.documentID) == true
          else { continue }

          let similarity = index.similarity(to: queryVector.values, row: row)
          guard similarity.isFinite, similarity >= queryVector.minimumSimilarity else {
            continue
          }
          heap.insert(KnowledgeSemanticTopKCandidate(row: row, score: similarity))
        }

        try Task.checkCancellation()
        let winners = heap.sortedCandidates()
        guard !winners.isEmpty else { return [] }
        return try fetchSemanticSearchResults(
          winners: winners,
          index: index,
          onlyRemoteAIAllowed: onlyRemoteAIAllowed,
          documentIDs: documentIDs
        )
      }
    }
  }

  /// Builds one immutable flat vector snapshot on demand.  Only compact
  /// metadata is read here; complete documents/chunks are fetched after Top-K
  /// selection in `fetchSemanticSearchResults`.
  func invalidateSemanticFlatVectorIndexesUnlocked() {
    semanticFlatVectorIndexes.removeAll()
    semanticFlatVectorIndexChangeToken = Int64(sqlite3_total_changes(handle))
  }

  private func semanticFlatVectorIndex(
    modelIdentifier: String,
    dimension: Int
  ) throws -> KnowledgeSemanticVectorFlatIndex {
    let key = KnowledgeSemanticVectorIndexKey(
      modelIdentifier: modelIdentifier,
      dimension: dimension
    )
    let currentChangeToken = Int64(sqlite3_total_changes(handle))
    if currentChangeToken != semanticFlatVectorIndexChangeToken {
      semanticFlatVectorIndexes.removeAll()
      semanticFlatVectorIndexChangeToken = currentChangeToken
    }
    if let cached = semanticFlatVectorIndexes.value(for: key) {
      return cached
    }

    return try withCachedStatementUnlocked(
      """
      SELECT e.chunk_id, e.revision_id, c.document_id, d.updated_at, c.ordinal,
             d.allows_ai_use, d.allows_local_semantic_index, d.is_archived,
             e.vector
      FROM knowledge_chunk_embeddings e
      JOIN knowledge_chunks c ON c.id = e.chunk_id
      JOIN knowledge_documents d ON d.id = c.document_id
      WHERE e.model_id = ?
        AND e.dimension = ?
        AND e.revision_id = c.revision_id
        AND c.revision_id = d.current_revision_id
      ORDER BY d.updated_at DESC, c.ordinal ASC, c.id ASC;
      """
    ) { statement in
      bind(modelIdentifier, at: 1, to: statement)
      sqlite3_bind_int64(statement, 2, sqlite3_int64(dimension))

      var entries: [KnowledgeSemanticVectorIndexEntry] = []
      var vectors: [Float] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        try Task.checkCancellation()
        let vector = KnowledgeSemanticVectorStorage.decodeVector(
          statement,
          index: 8,
          dimension: dimension
        )
        guard KnowledgeSemanticVectorStorage.isValidStoredSemanticVector(
          vector,
          expectedDimension: dimension
        ) else {
          continue
        }

        let chunkID = try requiredUUID(statement, 0, field: "knowledge_chunk_embeddings.chunk_id")
        let revisionID = try requiredUUID(
          statement,
          1,
          field: "knowledge_chunk_embeddings.revision_id"
        )
        let documentID = try requiredUUID(statement, 2, field: "knowledge_documents.id")
        entries.append(
          KnowledgeSemanticVectorIndexEntry(
            chunkID: chunkID,
            revisionID: revisionID,
            documentID: documentID,
            updatedAt: sqlite3_column_double(statement, 3),
            ordinal: Int(sqlite3_column_int64(statement, 4)),
            allowsRemoteAIUse: sqlite3_column_int(statement, 5) != 0,
            allowsLocalSemanticIndex: sqlite3_column_int(statement, 6) != 0,
            isArchived: sqlite3_column_int(statement, 7) != 0
          ))
        vectors.append(contentsOf: vector)
      }
      try Task.checkCancellation()
      try checkStatementCompletion(statement)

      let index = KnowledgeSemanticVectorFlatIndex(
        key: key,
        vectors: vectors,
        entries: entries
      )
      semanticFlatVectorIndexes.insert(index)
      semanticFlatVectorIndexChangeToken = Int64(sqlite3_total_changes(handle))
      return index
    }
  }

  private func fetchSemanticSearchResults(
    winners: [KnowledgeSemanticTopKCandidate],
    index: KnowledgeSemanticVectorFlatIndex,
    onlyRemoteAIAllowed: Bool,
    documentIDs: Set<UUID>?
  ) throws -> [KnowledgeSearchResult] {
    let winnerIDs = winners.map { index.entries[$0.row].chunkID }
    let placeholders = Array(repeating: "?", count: winnerIDs.count).joined(separator: ", ")
    let idClause = documentIDClause(documentIDs)
    let sql = """
      SELECT d.id, d.kind, d.title, d.authors_json, d.language, d.summary,
             d.tags_json, d.source_url, d.source_name, d.folder_id,
             d.source_byte_count, d.allows_ai_use, d.allows_local_semantic_index,
             d.is_archived,
             d.imported_at, d.updated_at, d.current_revision_id,
             c.id, c.document_id, c.revision_id, c.ordinal, c.heading_path,
             c.locator, c.content, c.token_estimate, c.content_hash, c.visual_anchor_json
      FROM knowledge_chunks c
      JOIN knowledge_documents d ON d.id = c.document_id
      WHERE c.id IN (\(placeholders))
        AND c.revision_id = d.current_revision_id
        AND d.is_archived = 0
        AND d.allows_local_semantic_index = 1
        AND (? = 0 OR d.allows_ai_use = 1)
        \(idClause.sql)
      """
    return try withCachedStatementUnlocked(sql) { statement in
      var parameter: Int32 = 1
      for id in winnerIDs {
        bind(id.uuidString, at: parameter, to: statement)
        parameter += 1
      }
      sqlite3_bind_int(statement, parameter, onlyRemoteAIAllowed ? 1 : 0)
      parameter += 1
      for id in idClause.ids {
        bind(id.uuidString, at: parameter, to: statement)
        parameter += 1
      }

      var resultByChunkID: [UUID: KnowledgeSearchResult] = [:]
      while sqlite3_step(statement) == SQLITE_ROW {
        try Task.checkCancellation()
        let chunkID = try requiredUUID(statement, 17, field: "knowledge_chunks.id")
        guard let winner = winners.first(where: {
          index.entries[$0.row].chunkID == chunkID
        }) else {
          continue
        }
        let entry = index.entries[winner.row]
        let revisionID = try requiredUUID(
          statement,
          19,
          field: "knowledge_chunks.revision_id"
        )
        guard revisionID == entry.revisionID else { continue }
        resultByChunkID[chunkID] = KnowledgeSearchResult(
          document: try decodeDocument(statement, offset: 0),
          chunk: try decodeChunk(statement, offset: 17),
          score: winner.score,
          signals: [.semantic]
        )
      }
      try Task.checkCancellation()
      try checkStatementCompletion(statement)

      var output: [KnowledgeSearchResult] = []
      output.reserveCapacity(resultByChunkID.count)
      for winner in winners {
        try Task.checkCancellation()
        let chunkID = index.entries[winner.row].chunkID
        if let result = resultByChunkID[chunkID] {
          output.append(result)
        }
      }
      return output
    }
  }

  func insertChunks(_ chunks: [KnowledgeChunk], document: KnowledgeDocument) throws {
    let chunkSQL = """
      INSERT INTO knowledge_chunks (
        id, document_id, revision_id, ordinal, heading_path, locator,
        content, token_estimate, content_hash, visual_anchor_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    let ftsSQL = """
      INSERT INTO knowledge_chunks_fts (
        chunk_id, document_id, title, authors, heading, content
      ) VALUES (?, ?, ?, ?, ?, ?);
      """
    for chunk in chunks {
      try withCachedStatementUnlocked(chunkSQL) { chunkStatement in
        bind(chunk.id.uuidString, at: 1, to: chunkStatement)
        bind(chunk.documentID.uuidString, at: 2, to: chunkStatement)
        bind(chunk.revisionID.uuidString, at: 3, to: chunkStatement)
        sqlite3_bind_int64(chunkStatement, 4, sqlite3_int64(chunk.ordinal))
        bindOptional(chunk.headingPath, at: 5, to: chunkStatement)
        bindOptional(chunk.locator, at: 6, to: chunkStatement)
        bind(chunk.content, at: 7, to: chunkStatement)
        sqlite3_bind_int64(chunkStatement, 8, sqlite3_int64(chunk.tokenEstimate))
        bind(chunk.contentHash, at: 9, to: chunkStatement)
        bindOptional(visualAnchorJSON(chunk.visualAnchor), at: 10, to: chunkStatement)
        guard sqlite3_step(chunkStatement) == SQLITE_DONE else { throw databaseError() }
      }
      try withCachedStatementUnlocked(ftsSQL) { ftsStatement in
        bind(chunk.id.uuidString, at: 1, to: ftsStatement)
        bind(chunk.documentID.uuidString, at: 2, to: ftsStatement)
        bind(document.title, at: 3, to: ftsStatement)
        bind(document.authors.joined(separator: " "), at: 4, to: ftsStatement)
        bind(chunk.headingPath ?? "", at: 5, to: ftsStatement)
        bind(chunk.content, at: 6, to: ftsStatement)
        guard sqlite3_step(ftsStatement) == SQLITE_DONE else { throw databaseError() }
      }
    }
  }

  func insertSearchRows(
    revisionID: UUID,
    document: KnowledgeDocument
  ) throws {
    try withCachedStatementUnlocked(
      """
      INSERT INTO knowledge_chunks_fts (
        chunk_id, document_id, title, authors, heading, content
      )
      SELECT id, document_id, ?, ?, COALESCE(heading_path, ''), content
      FROM knowledge_chunks
      WHERE document_id = ? AND revision_id = ?
      ORDER BY ordinal ASC;
      """
    ) { statement in
      bind(document.title, at: 1, to: statement)
      bind(document.authors.joined(separator: " "), at: 2, to: statement)
      bind(document.id.uuidString, at: 3, to: statement)
      bind(revisionID.uuidString, at: 4, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func deleteSemanticEmbeddingsUnlocked(documentIDs: Set<UUID>) throws {
    invalidateSemanticFlatVectorIndexesUnlocked()
    guard !documentIDs.isEmpty else { return }
    let sortedIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }
    let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
    try withCachedStatementUnlocked(
      """
      DELETE FROM knowledge_chunk_embeddings
      WHERE chunk_id IN (
        SELECT id FROM knowledge_chunks WHERE document_id IN (\(placeholders))
      );
      """
    ) { statement in
      for (offset, id) in sortedIDs.enumerated() {
        bind(id.uuidString, at: Int32(offset + 1), to: statement)
      }
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
  }

  func upsertSemanticEmbeddingsUnlocked(_ embeddings: [KnowledgeChunkEmbedding]) throws {
    invalidateSemanticFlatVectorIndexesUnlocked()
    guard !embeddings.isEmpty else { return }
    try withCachedStatementUnlocked(
      """
      INSERT INTO knowledge_chunk_embeddings (
        chunk_id, revision_id, model_id, dimension, vector, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(chunk_id, model_id) DO UPDATE SET
        revision_id = excluded.revision_id,
        dimension = excluded.dimension,
        vector = excluded.vector,
        created_at = excluded.created_at;
      """
    ) { statement in
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
  }

  func deleteSearchRows(documentID: UUID) throws {
    try withCachedStatementUnlocked(
      "DELETE FROM knowledge_chunks_fts WHERE document_id = ?;"
    ) { statement in
      bind(documentID.uuidString, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
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
             c.locator, c.content, c.token_estimate, c.content_hash, c.visual_anchor_json,
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
    return try withCachedStatementUnlocked(sql) { statement in
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
             c.locator, c.content, c.token_estimate, c.content_hash, c.visual_anchor_json,
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
      ORDER BY 28 ASC, d.updated_at DESC, c.ordinal ASC
      LIMIT ?;
      """
    return try withCachedStatementUnlocked(sql) { statement in
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
  }

  func collectSearchResults(_ statement: OpaquePointer?) throws -> [KnowledgeSearchResult] {
    var output: [KnowledgeSearchResult] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      try Task.checkCancellation()
      let document = try decodeDocument(statement, offset: 0)
      let chunk = try decodeChunk(statement, offset: 17)
      output.append(
        KnowledgeSearchResult(
          document: document,
          chunk: chunk,
          score: sqlite3_column_double(statement, 27),
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
