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
}
