import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeSemanticEmbeddingServiceTests: XCTestCase {
  func testDoesNotSynchronouslyLoadUnpreparedContextualModel() {
    let vectors = KnowledgeSemanticEmbeddingService().vectors(
      for: "本地资料库通过混合检索找到相关章节"
    )

    XCTAssertTrue(vectors.contains { $0.modelIdentifier == "local-semantic-hash-v2" })
    XCTAssertFalse(vectors.contains { $0.modelIdentifier.hasPrefix("apple-contextual-") })
    XCTAssertFalse(vectors.contains { $0.modelIdentifier.hasPrefix("apple-sentence-zh") })
  }

  func testFallbackVectorIsFiniteNormalizedAndStableDimension() throws {
    let vector = try XCTUnwrap(
      KnowledgeSemanticEmbeddingService()
        .vector(for: "本地知识检索与写作工作流", modelIdentifier: "local-semantic-hash-v2")
    )

    XCTAssertEqual(vector.values.count, 384)
    XCTAssertTrue(vector.values.allSatisfy(\.isFinite))
    let squaredMagnitude = vector.values.reduce(Double.zero) {
      $0 + Double($1) * Double($1)
    }
    XCTAssertEqual(squaredMagnitude, 1, accuracy: 0.000_1)
    XCTAssertEqual(vector.minimumSimilarity, 0.16)
  }

  func testFallbackVectorDoesNotInjectHandwrittenConceptAliases() throws {
    let service = KnowledgeSemanticEmbeddingService()
    let cost = try XCTUnwrap(
      service.vector(for: "成本", modelIdentifier: "local-semantic-hash-v2")
    )
    let budget = try XCTUnwrap(
      service.vector(for: "预算", modelIdentifier: "local-semantic-hash-v2")
    )

    let similarity = zip(cost.values, budget.values).reduce(Float.zero) {
      $0 + ($1.0 * $1.1)
    }
    XCTAssertLessThan(
      abs(similarity),
      0.5,
      "Lexically unrelated aliases must not receive a shared handcrafted concept feature."
    )
  }

  func testBlankInputProducesNoVectorsAndHealthProbeUsesFallbackModel() {
    let service = KnowledgeSemanticEmbeddingService()

    XCTAssertTrue(service.vectors(for: " \n\t ").isEmpty)
    XCTAssertEqual(
      service.availableModelDimensions(for: ["", " \n "])["local-semantic-hash-v2"],
      384
    )
  }
}
