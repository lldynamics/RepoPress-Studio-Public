import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeSemanticVectorTests: XCTestCase {
  func testVectorRejectsNonFiniteAndZeroPayloadsBeforePersistence() {
    XCTAssertTrue(KnowledgeSemanticVector(
      modelIdentifier: "test",
      values: [.nan, 1],
      minimumSimilarity: 0
    ).isEmpty)
    XCTAssertTrue(KnowledgeSemanticVector(
      modelIdentifier: "test",
      values: [0, 0],
      minimumSimilarity: 0
    ).isEmpty)
  }

  func testVectorNormalizesFinitePayload() {
    let vector = KnowledgeSemanticVector(
      modelIdentifier: "test",
      values: [3, 4],
      minimumSimilarity: 0
    )

    XCTAssertEqual(vector.values[0], 0.6, accuracy: 0.0001)
    XCTAssertEqual(vector.values[1], 0.8, accuracy: 0.0001)
  }

  func testNormalizedVectorsUseDotProductSimilarity() {
    XCTAssertEqual(
      KnowledgeSemanticVectorStorage.cosineSimilarity([0.6, 0.8], [0.6, 0.8]),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      KnowledgeSemanticVectorStorage.cosineSimilarity([1, 0], [0, 1]),
      0,
      accuracy: 0.0001
    )
  }

  func testFlatIndexStoresContiguousRowsAndUsesNormalizedDotProduct() throws {
    let firstDocumentID = try uuid("00000000-0000-0000-0000-000000000001")
    let secondDocumentID = try uuid("00000000-0000-0000-0000-000000000002")
    let key = KnowledgeSemanticVectorIndexKey(modelIdentifier: "model", dimension: 2)
    let index = KnowledgeSemanticVectorFlatIndex(
      key: key,
      vectors: [1, 0, 0.6, 0.8],
      entries: [
        KnowledgeSemanticVectorIndexEntry(
          chunkID: try uuid("00000000-0000-0000-0000-000000000011"),
          revisionID: try uuid("00000000-0000-0000-0000-000000000021"),
          documentID: firstDocumentID,
          updatedAt: 1,
          ordinal: 0,
          allowsRemoteAIUse: true,
          allowsLocalSemanticIndex: true,
          isArchived: false
        ),
        KnowledgeSemanticVectorIndexEntry(
          chunkID: try uuid("00000000-0000-0000-0000-000000000012"),
          revisionID: try uuid("00000000-0000-0000-0000-000000000022"),
          documentID: secondDocumentID,
          updatedAt: 1,
          ordinal: 0,
          allowsRemoteAIUse: true,
          allowsLocalSemanticIndex: true,
          isArchived: false
        ),
      ]
    )

    XCTAssertEqual(index.vectors, [1, 0, 0.6, 0.8])
    XCTAssertEqual(index.similarity(to: [1, 0], row: 0), 1, accuracy: 0.0001)
    XCTAssertEqual(index.similarity(to: [1, 0], row: 1), 0.6, accuracy: 0.0001)
  }

  func testFlatIndexCacheEvictsLeastRecentlyUsedSnapshotWithinByteBudget() {
    let first = makeFlatIndex(
      key: KnowledgeSemanticVectorIndexKey(modelIdentifier: "first", dimension: 2),
      vector: [1, 0]
    )
    let second = makeFlatIndex(
      key: KnowledgeSemanticVectorIndexKey(modelIdentifier: "second", dimension: 2),
      vector: [0, 1]
    )
    let third = makeFlatIndex(
      key: KnowledgeSemanticVectorIndexKey(modelIdentifier: "third", dimension: 2),
      vector: [0.6, 0.8]
    )
    let cache = KnowledgeSemanticVectorFlatIndexCache(
      byteBudget: first.estimatedByteCount * 2
    )

    cache.insert(first)
    cache.insert(second)
    _ = cache.value(for: first.key)
    cache.insert(third)

    XCTAssertNotNil(cache.value(for: first.key))
    XCTAssertNil(cache.value(for: second.key))
    XCTAssertNotNil(cache.value(for: third.key))
    XCTAssertLessThanOrEqual(cache.estimatedByteCount, first.estimatedByteCount * 2)
  }

  func testFlatIndexCacheDoesNotRetainSnapshotLargerThanByteBudget() {
    let oversized = makeFlatIndex(
      key: KnowledgeSemanticVectorIndexKey(modelIdentifier: "oversized", dimension: 2),
      vector: [1, 0]
    )
    let cache = KnowledgeSemanticVectorFlatIndexCache(
      byteBudget: oversized.estimatedByteCount - 1
    )

    cache.insert(oversized)

    XCTAssertNil(cache.value(for: oversized.key))
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.estimatedByteCount, 0)
  }

  func testSemanticSearchUsesTopKOrderingAndDeterministicTies() throws {
    let rootURL = try temporaryDirectory(named: "semantic-top-k")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("library.sqlite")
    )
    let first = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000001",
      updatedAt: 100,
      vector: [1, 0]
    )
    let second = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000002",
      updatedAt: 200,
      vector: [1, 0]
    )
    let third = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000003",
      updatedAt: 200,
      vector: [1, 0]
    )
    _ = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000004",
      updatedAt: 50,
      vector: [0, 1]
    )

    let query = KnowledgeSemanticVector(
      modelIdentifier: "test-model",
      values: [1, 0],
      minimumSimilarity: 0.5
    )
    let results = try database.semanticSearch(
      queryVector: query,
      limit: 3,
      onlyRemoteAIAllowed: false
    )

    XCTAssertEqual(
      results.map(\.document.id),
      [second.document.id, third.document.id, first.document.id]
    )
    XCTAssertEqual(results.map(\.score), [1, 1, 1])
    XCTAssertFalse(
      results.contains {
        $0.document.id == UUID(uuidString: "00000000-0000-0000-0000-000000000004")
      }
    )
  }

  func testSemanticSearchAppliesRemoteAndDocumentFilters() throws {
    let rootURL = try temporaryDirectory(named: "semantic-filters")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("library.sqlite")
    )
    let remoteAllowed = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000011",
      updatedAt: 200,
      allowsRemoteAIUse: true,
      vector: [1, 0]
    )
    let remoteDenied = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000012",
      updatedAt: 300,
      allowsRemoteAIUse: false,
      vector: [1, 0]
    )
    _ = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000013",
      updatedAt: 400,
      isArchived: true,
      vector: [1, 0]
    )
    _ = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000014",
      updatedAt: 350,
      allowsLocalSemanticIndex: false,
      vector: [1, 0]
    )

    let query = KnowledgeSemanticVector(
      modelIdentifier: "test-model",
      values: [1, 0],
      minimumSimilarity: 0
    )
    let remoteResults = try database.semanticSearch(
      queryVector: query,
      limit: 10,
      onlyRemoteAIAllowed: true
    )
    XCTAssertEqual(remoteResults.map(\.document.id), [remoteAllowed.document.id])

    let allEligibleResults = try database.semanticSearch(
      queryVector: query,
      limit: 10,
      onlyRemoteAIAllowed: false
    )
    XCTAssertEqual(
      Set(allEligibleResults.map(\.document.id)),
      Set([remoteAllowed.document.id, remoteDenied.document.id])
    )

    let scopedResults = try database.semanticSearch(
      queryVector: query,
      limit: 10,
      onlyRemoteAIAllowed: false,
      documentIDs: Set([remoteDenied.document.id])
    )
    XCTAssertEqual(scopedResults.map(\.document.id), [remoteDenied.document.id])
  }

  func testSemanticIndexInvalidatesAfterEmbeddingAndDocumentMutations() throws {
    let rootURL = try temporaryDirectory(named: "semantic-invalidation")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("library.sqlite")
    )
    let inserted = try insertSemanticDocument(
      into: database,
      documentID: "00000000-0000-0000-0000-000000000021",
      updatedAt: 100,
      vector: [0, 1]
    )
    let query = KnowledgeSemanticVector(
      modelIdentifier: "test-model",
      values: [1, 0],
      minimumSimilarity: 0.5
    )

    XCTAssertTrue(try database.semanticSearch(
      queryVector: query,
      limit: 5,
      onlyRemoteAIAllowed: false
    ).isEmpty)

    try database.upsertSemanticEmbeddings([
      KnowledgeChunkEmbedding(
        chunkID: inserted.chunk.id,
        revisionID: inserted.revision.id,
        vector: KnowledgeSemanticVector(
          modelIdentifier: "test-model",
          values: [1, 0],
          minimumSimilarity: 0
        ),
        inputHash: KnowledgeSemanticIndexRecord(
          document: inserted.document,
          chunk: inserted.chunk
        ).searchableTextHash
      )
    ])
    XCTAssertEqual(try database.semanticSearch(
      queryVector: query,
      limit: 5,
      onlyRemoteAIAllowed: false
    ).map(\.chunk.id), [inserted.chunk.id])

    try database.setAllowsRemoteAIUse(false, documentID: inserted.document.id)
    XCTAssertTrue(try database.semanticSearch(
      queryVector: query,
      limit: 5,
      onlyRemoteAIAllowed: true
    ).isEmpty)
  }

  private struct InsertedSemanticDocument {
    let document: KnowledgeDocument
    let revision: KnowledgeDocumentRevision
    let chunk: KnowledgeChunk
  }

  private func insertSemanticDocument(
    into database: KnowledgeDatabase,
    documentID: String,
    updatedAt: TimeInterval,
    allowsRemoteAIUse: Bool = true,
    allowsLocalSemanticIndex: Bool = true,
    isArchived: Bool = false,
    vector: [Float]
  ) throws -> InsertedSemanticDocument {
    let id = try XCTUnwrap(UUID(uuidString: documentID))
    let revision = KnowledgeDocumentRevision(
      documentID: id,
      originalContentHash: "original-\(documentID)",
      normalizedContentHash: "normalized-\(documentID)",
      parserVersion: 1,
      importedAt: Date(timeIntervalSince1970: updatedAt),
      normalizedStorageReference: "normalized/\(documentID)"
    )
    let document = KnowledgeDocument(
      id: id,
      kind: .article,
      title: "Semantic \(documentID)",
      allowsLocalSemanticIndex: allowsLocalSemanticIndex,
      allowsRemoteAIUse: allowsRemoteAIUse,
      isArchived: isArchived,
      importedAt: Date(timeIntervalSince1970: updatedAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      currentRevisionID: revision.id
    )
    let chunk = KnowledgeChunk(
      documentID: id,
      revisionID: revision.id,
      ordinal: 0,
      content: "semantic content \(documentID)",
      tokenEstimate: 3,
      contentHash: "chunk-\(documentID)"
    )
    try database.commit(
      document: document,
      revision: revision,
      chunks: [chunk],
      embeddings: [
        KnowledgeChunkEmbedding(
          chunkID: chunk.id,
          revisionID: revision.id,
          vector: KnowledgeSemanticVector(
            modelIdentifier: "test-model",
            values: vector,
            minimumSimilarity: 0
          ),
          inputHash: KnowledgeSemanticIndexRecord(
            document: document,
            chunk: chunk
          ).searchableTextHash
        )
      ]
    )
    return InsertedSemanticDocument(
      document: document,
      revision: revision,
      chunk: chunk
    )
  }

  private func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
  }

  private func makeFlatIndex(
    key: KnowledgeSemanticVectorIndexKey,
    vector: [Float]
  ) -> KnowledgeSemanticVectorFlatIndex {
    KnowledgeSemanticVectorFlatIndex(
      key: key,
      vectors: vector,
      entries: [
        KnowledgeSemanticVectorIndexEntry(
          chunkID: UUID(),
          revisionID: UUID(),
          documentID: UUID(),
          updatedAt: 0,
          ordinal: 0,
          allowsRemoteAIUse: true,
          allowsLocalSemanticIndex: true,
          isArchived: false
        )
      ]
    )
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
