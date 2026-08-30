import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeSemanticEmbeddingServiceTests: XCTestCase {
  private struct RoleAwareProvider: KnowledgeSemanticEmbeddingProvider {
    let descriptor = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "test-role-aware",
      dimension: 2,
      minimumSimilarity: 0,
      maximumTokenCount: 16,
      weightsVersion: "test",
      artifactDigest: "fixture",
      preprocessingVersion: "fixture",
      queryInstruction: "query only"
    )

    func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? {
      KnowledgeSemanticVector(
        modelIdentifier: descriptor.modelIdentifier,
        values: input.role == .query ? [1, 0] : [0, 1],
        minimumSimilarity: 0,
        encodingVersion: descriptor.encodingVersion
      )
    }
  }

  private struct FailingProvider: KnowledgeSemanticEmbeddingProvider {
    let descriptor = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "test-unavailable",
      dimension: 2,
      minimumSimilarity: 0,
      maximumTokenCount: 16,
      weightsVersion: "test",
      preprocessingVersion: "fixture"
    )

    func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? { nil }
  }

  func testProviderReceivesDistinctQueryAndPassageRolesWhileFallbackRemainsAvailable() throws {
    let service = KnowledgeSemanticEmbeddingService(providers: [RoleAwareProvider()])
    let query = try XCTUnwrap(
      service.vector(
        for: "same text", modelIdentifier: "test-role-aware", role: .query
      ))
    let passage = try XCTUnwrap(
      service.vector(
        for: "same text", modelIdentifier: "test-role-aware", role: .passage
      ))
    XCTAssertEqual(query.values, [1, 0])
    XCTAssertEqual(passage.values, [0, 1])
    XCTAssertNotNil(service.vector(for: "same text", modelIdentifier: "local-semantic-hash-v2"))
  }

  func testProviderFailureFallsBackAndDescriptorFingerprintIncludesInferenceContract() {
    let first = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "same", dimension: 2, minimumSimilarity: 0,
      maximumTokenCount: 8, weightsVersion: "w", artifactDigest: "one",
      preprocessingVersion: "p", poolingVersion: "mean", normalizationVersion: "l2",
      precisionVersion: "f32", queryInstruction: "question"
    )
    let changed = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "same", dimension: 2, minimumSimilarity: 0,
      maximumTokenCount: 8, weightsVersion: "w", artifactDigest: "two",
      preprocessingVersion: "p", poolingVersion: "cls", normalizationVersion: "l2",
      precisionVersion: "f32", queryInstruction: "question v2"
    )
    let service = KnowledgeSemanticEmbeddingService(providers: [FailingProvider()])
    XCTAssertEqual(service.vectors(for: "本地回退").map(\.modelIdentifier), ["local-semantic-hash-v2"])
    XCTAssertNotEqual(first.encodingVersion, changed.encodingVersion)
  }
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
