import Foundation
import XCTest

@testable import PublishingAICore

final class AILocalFeedbackServiceTests: XCTestCase {
  func testFeedbackRecordsAreContentFreeBoundedAndRankedDeterministically() throws {
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let records = [
      feedback(.accepted, action: "polish", model: "model-a", offset: 1, baseDate: baseDate),
      feedback(.accepted, action: "polish", model: "model-a", offset: 2, baseDate: baseDate),
      feedback(.rejected, action: "polish", model: "model-a", offset: 3, baseDate: baseDate),
      feedback(.accepted, action: "translate", model: "model-b", offset: 4, baseDate: baseDate),
      feedback(.rejected, action: "old", model: "model-c", offset: 0, baseDate: baseDate),
    ]
    let service = AILocalEditFeedbackService(
      maximumRecordCount: 4,
      maximumAggregateCount: 2
    )

    let bounded = service.boundedRecords(records)
    let ranking = service.rankedAggregates(from: records)

    XCTAssertEqual(bounded.count, 4)
    XCTAssertFalse(bounded.contains(where: { $0.actionIdentifier == "old" }))
    XCTAssertEqual(ranking.count, 2)
    XCTAssertEqual(ranking.first?.key.actionIdentifier, "polish")
    XCTAssertEqual(ranking.first?.acceptedCount, 2)
    XCTAssertEqual(ranking.first?.rejectedCount, 1)
    XCTAssertEqual(try XCTUnwrap(ranking.first).rankingScore, 0.36, accuracy: 0.0001)

    let encoded = String(
      decoding: try JSONEncoder().encode(records[0]),
      as: UTF8.self
    )
    XCTAssertFalse(encoded.contains("originalText"))
    XCTAssertFalse(encoded.contains("replacementText"))
    XCTAssertFalse(encoded.contains("bodyMarkdown"))
    XCTAssertFalse(encoded.contains("prompt"))
  }

  private func feedback(
    _ decision: AILocalEditFeedbackDecision,
    action: String,
    model: String,
    offset: TimeInterval,
    baseDate: Date
  ) -> AILocalEditFeedbackRecord {
    AILocalEditFeedbackRecord(
      recordedAt: baseDate.addingTimeInterval(offset),
      decision: decision,
      actionIdentifier: action,
      modelIdentifier: model
    )
  }
}
