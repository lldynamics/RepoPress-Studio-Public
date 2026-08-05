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

  func testSemanticVectorCacheEvictsLeastRecentlyUsedEntry() {
    let cache = KnowledgeSemanticVectorLRUCache(capacity: 2)
    let first = KnowledgeSemanticVectorCacheKey(
      modelIdentifier: "model",
      chunkID: UUID(),
      revisionID: UUID(),
      dimension: 2
    )
    let second = KnowledgeSemanticVectorCacheKey(
      modelIdentifier: "model",
      chunkID: UUID(),
      revisionID: UUID(),
      dimension: 2
    )
    let third = KnowledgeSemanticVectorCacheKey(
      modelIdentifier: "model",
      chunkID: UUID(),
      revisionID: UUID(),
      dimension: 2
    )

    cache.insert([1, 0], for: first)
    cache.insert([0, 1], for: second)
    _ = cache.value(for: first)
    cache.insert([1, 1], for: third)

    XCTAssertNotNil(cache.value(for: first))
    XCTAssertNil(cache.value(for: second))
    XCTAssertEqual(cache.value(for: third), [Float(1), Float(1)])
  }
}
