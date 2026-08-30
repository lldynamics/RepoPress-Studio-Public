import Foundation

/// The role is part of the embedding contract.  A provider may apply a query
/// instruction, but must never silently apply it to indexed passages.
package enum KnowledgeSemanticEmbeddingRole: Sendable {
  case query
  case passage
}

package enum KnowledgeSemanticProviderAvailability: Sendable, Equatable {
  case available
  /// The provider is known, but its local asset is not presently usable.
  /// Stored vectors remain valid and must not be pruned by maintenance.
  case temporarilyUnavailable
  /// The provider contract was intentionally removed.  Its vectors may be
  /// removed by a full repair.
  case retired
}

package struct KnowledgeSemanticEmbeddingInput: Sendable {
  package let text: String
  package let role: KnowledgeSemanticEmbeddingRole

  package init(text: String, role: KnowledgeSemanticEmbeddingRole) {
    self.text = text
    self.role = role
  }
}

/// Stable identity for persisted vectors.  `encodingVersion` deliberately
/// includes preprocessing and weights so a model-id/dimension collision never
/// reuses vectors produced by a different tokenizer or checkpoint.
package struct KnowledgeSemanticEmbeddingDescriptor: Sendable, Hashable {
  package let modelIdentifier: String
  package let dimension: Int
  package let minimumSimilarity: Double
  package let maximumTokenCount: Int
  package let weightsVersion: String
  /// Stable digest/version of the actual compiled model artifact or weights.
  package let artifactDigest: String
  package let preprocessingVersion: String
  package let poolingVersion: String
  package let normalizationVersion: String
  package let precisionVersion: String
  package let availability: KnowledgeSemanticProviderAvailability
  package let queryInstruction: String?

  package init(
    modelIdentifier: String,
    dimension: Int,
    minimumSimilarity: Double,
    maximumTokenCount: Int,
    weightsVersion: String,
    artifactDigest: String = "unspecified-artifact",
    preprocessingVersion: String,
    poolingVersion: String = "mean-v1",
    normalizationVersion: String = "l2-v1",
    precisionVersion: String = "float32-v1",
    availability: KnowledgeSemanticProviderAvailability = .available,
    queryInstruction: String? = nil
  ) {
    self.modelIdentifier = modelIdentifier
    self.dimension = dimension
    self.minimumSimilarity = minimumSimilarity
    self.maximumTokenCount = maximumTokenCount
    self.weightsVersion = weightsVersion
    self.artifactDigest = artifactDigest
    self.preprocessingVersion = preprocessingVersion
    self.poolingVersion = poolingVersion
    self.normalizationVersion = normalizationVersion
    self.precisionVersion = precisionVersion
    self.availability = availability
    self.queryInstruction = queryInstruction
  }

  package var encodingVersion: String {
    [
      "weights=\(weightsVersion)",
      "artifact=\(artifactDigest)",
      "preprocess=\(preprocessingVersion)",
      "pooling=\(poolingVersion)",
      "normalization=\(normalizationVersion)",
      "precision=\(precisionVersion)",
      "maxTokens=\(maximumTokenCount)",
      // This is intentionally part of the persisted identity: changing a BGE
      // query instruction changes query geometry even if passages are stable.
      "queryInstruction=\(queryInstruction ?? "")",
    ].joined(separator: ";")
  }

  package func replacingAvailability(
    _ availability: KnowledgeSemanticProviderAvailability
  ) -> KnowledgeSemanticEmbeddingDescriptor {
    KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: modelIdentifier,
      dimension: dimension,
      minimumSimilarity: minimumSimilarity,
      maximumTokenCount: maximumTokenCount,
      weightsVersion: weightsVersion,
      artifactDigest: artifactDigest,
      preprocessingVersion: preprocessingVersion,
      poolingVersion: poolingVersion,
      normalizationVersion: normalizationVersion,
      precisionVersion: precisionVersion,
      availability: availability,
      queryInstruction: queryInstruction
    )
  }
}

/// A narrow local-only boundary.  Providers return nil for an unavailable
/// asset or malformed inference result; the composer retains the hash vector.
package protocol KnowledgeSemanticEmbeddingProvider: Sendable {
  var descriptor: KnowledgeSemanticEmbeddingDescriptor { get }
  func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector?
}
