import Foundation

public enum AILocalEditFeedbackDecision: String, Codable, Hashable, Sendable {
  case accepted
  case rejected
}

/// A deliberately content-free record of a user's decision on an AI edit.
///
/// It stores only routing identifiers and aggregateable metadata. There are no
/// original/replacement text fields, prompts, article titles, or draft IDs.
public struct AILocalEditFeedbackRecord: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let recordedAt: Date
  public let decision: AILocalEditFeedbackDecision
  public let actionIdentifier: String
  public let modelIdentifier: String
  public let category: AIStructuredEditCategory?

  public init(
    id: UUID = UUID(),
    recordedAt: Date = Date(),
    decision: AILocalEditFeedbackDecision,
    actionIdentifier: String,
    modelIdentifier: String,
    category: AIStructuredEditCategory? = nil
  ) {
    self.id = id
    self.recordedAt = recordedAt
    self.decision = decision
    self.actionIdentifier = Self.boundedIdentifier(actionIdentifier)
    self.modelIdentifier = Self.boundedIdentifier(modelIdentifier)
    self.category = category
  }

  private static func boundedIdentifier(_ value: String) -> String {
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return String((normalized.isEmpty ? "unknown" : normalized).prefix(120))
  }
}

public struct AILocalEditFeedbackAggregateKey: Codable, Hashable, Sendable {
  public let actionIdentifier: String
  public let modelIdentifier: String

  public init(actionIdentifier: String, modelIdentifier: String) {
    self.actionIdentifier = actionIdentifier
    self.modelIdentifier = modelIdentifier
  }
}

public struct AILocalEditFeedbackAggregate: Identifiable, Hashable, Sendable {
  public var id: AILocalEditFeedbackAggregateKey { key }

  public let key: AILocalEditFeedbackAggregateKey
  public let acceptedCount: Int
  public let rejectedCount: Int
  public let mostRecentFeedbackAt: Date
  /// Evidence-weighted Bayesian acceptance score.
  public let rankingScore: Double

  public init(
    key: AILocalEditFeedbackAggregateKey,
    acceptedCount: Int,
    rejectedCount: Int,
    mostRecentFeedbackAt: Date,
    rankingScore: Double
  ) {
    self.key = key
    self.acceptedCount = acceptedCount
    self.rejectedCount = rejectedCount
    self.mostRecentFeedbackAt = mostRecentFeedbackAt
    self.rankingScore = rankingScore
  }

  public var sampleCount: Int {
    acceptedCount + rejectedCount
  }

  public var acceptanceRate: Double {
    guard sampleCount > 0 else { return 0 }
    return Double(acceptedCount) / Double(sampleCount)
  }
}

public struct AILocalEditFeedbackService: Sendable {
  public let maximumRecordCount: Int
  public let maximumAggregateCount: Int

  public init(
    maximumRecordCount: Int = 500,
    maximumAggregateCount: Int = 64
  ) {
    self.maximumRecordCount = max(1, maximumRecordCount)
    self.maximumAggregateCount = max(1, maximumAggregateCount)
  }

  /// Keeps the newest records with deterministic UUID tie-breaking.
  public func boundedRecords(
    _ records: [AILocalEditFeedbackRecord]
  ) -> [AILocalEditFeedbackRecord] {
    Array(records.sorted(by: recordOrder).prefix(maximumRecordCount))
  }

  /// Produces a deterministic, bounded ranking by action and model.
  ///
  /// A 1/1 beta prior and a bounded sample-confidence factor prevent one lucky
  /// accepted suggestion from outranking a consistently useful action.
  public func rankedAggregates(
    from records: [AILocalEditFeedbackRecord]
  ) -> [AILocalEditFeedbackAggregate] {
    struct MutableAggregate {
      var acceptedCount = 0
      var rejectedCount = 0
      var mostRecentFeedbackAt = Date.distantPast
    }

    var buckets: [AILocalEditFeedbackAggregateKey: MutableAggregate] = [:]
    for record in boundedRecords(records) {
      let key = AILocalEditFeedbackAggregateKey(
        actionIdentifier: record.actionIdentifier,
        modelIdentifier: record.modelIdentifier
      )
      var bucket = buckets[key, default: MutableAggregate()]
      switch record.decision {
      case .accepted:
        bucket.acceptedCount += 1
      case .rejected:
        bucket.rejectedCount += 1
      }
      bucket.mostRecentFeedbackAt = max(bucket.mostRecentFeedbackAt, record.recordedAt)
      buckets[key] = bucket
    }

    let aggregates = buckets.map { key, bucket in
      let sampleCount = bucket.acceptedCount + bucket.rejectedCount
      let posteriorMean = Double(bucket.acceptedCount + 1) / Double(sampleCount + 2)
      let sampleConfidence = Double(sampleCount) / Double(sampleCount + 2)
      let score = posteriorMean * sampleConfidence
      return AILocalEditFeedbackAggregate(
        key: key,
        acceptedCount: bucket.acceptedCount,
        rejectedCount: bucket.rejectedCount,
        mostRecentFeedbackAt: bucket.mostRecentFeedbackAt,
        rankingScore: score
      )
    }
    return Array(aggregates.sorted(by: aggregateOrder).prefix(maximumAggregateCount))
  }

  private func recordOrder(
    _ lhs: AILocalEditFeedbackRecord,
    _ rhs: AILocalEditFeedbackRecord
  ) -> Bool {
    if lhs.recordedAt == rhs.recordedAt {
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return lhs.recordedAt > rhs.recordedAt
  }

  private func aggregateOrder(
    _ lhs: AILocalEditFeedbackAggregate,
    _ rhs: AILocalEditFeedbackAggregate
  ) -> Bool {
    if lhs.rankingScore != rhs.rankingScore {
      return lhs.rankingScore > rhs.rankingScore
    }
    if lhs.sampleCount != rhs.sampleCount {
      return lhs.sampleCount > rhs.sampleCount
    }
    if lhs.mostRecentFeedbackAt != rhs.mostRecentFeedbackAt {
      return lhs.mostRecentFeedbackAt > rhs.mostRecentFeedbackAt
    }
    if lhs.key.actionIdentifier != rhs.key.actionIdentifier {
      return lhs.key.actionIdentifier < rhs.key.actionIdentifier
    }
    return lhs.key.modelIdentifier < rhs.key.modelIdentifier
  }
}
