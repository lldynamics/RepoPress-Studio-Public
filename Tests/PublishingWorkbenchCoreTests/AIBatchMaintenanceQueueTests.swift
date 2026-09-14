import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIBatchMaintenanceQueueTests: XCTestCase {
  private func makeQueue(_ count: Int = 3) -> AIBatchMaintenanceQueue {
    AIBatchMaintenanceQueue(
      siteProfileID: UUID(), operation: .summary, modelName: "test-model",
      items: (0..<count).map {
        AIBatchMaintenanceItem(draftID: UUID(), draftTitle: "文章\($0)", sourceFingerprint: "fp\($0)")
      }
    )
  }

  func testBeginCompleteAndResumePreserveReadyWork() {
    var queue = makeQueue()
    let first = queue.beginNext()!
    queue.complete(id: first.id, resultText: "摘要")
    queue.pause()
    XCTAssertNil(queue.beginNext())
    queue.resume()
    XCTAssertEqual(queue.items.first?.status, .ready)
    XCTAssertEqual(queue.beginNext()?.draftTitle, "文章1")
  }

  func testMixedModelsIncludeLegacyItemsWithoutPerItemModel() {
    var queue = makeQueue(2)
    queue.items[0].modelName = "new-model"
    XCTAssertNil(queue.items[1].modelName)
    XCTAssertEqual(queue.displayModelName, CoreL10n.text("多个模型"))
    queue.items[0].modelName = "test-model"
    XCTAssertEqual(queue.displayModelName, "test-model")
  }

  func testRetryFailedOnlyRetriesFailedItems() {
    var queue = makeQueue()
    let first = queue.beginNext()!
    queue.complete(id: first.id, resultText: "保留")
    let second = queue.beginNext()!
    queue.fail(id: second.id, message: "超时")
    queue.retryFailed()
    XCTAssertEqual(queue.items[0].status, .ready)
    XCTAssertEqual(queue.items[0].resultText, "保留")
    XCTAssertEqual(queue.items[1].status, .pending)
    XCTAssertNil(queue.items[1].errorMessage)
  }

  func testDuplicateDraftsAndCapPreserveFirstOccurrenceOrder() {
    let duplicateID = UUID()
    let items = (0..<105).map { index in
      AIBatchMaintenanceItem(
        draftID: index == 4 ? duplicateID : (index == 0 ? duplicateID : UUID()),
        draftTitle: "\(index)", sourceFingerprint: "\(index)")
    }
    let queue = AIBatchMaintenanceQueue(
      siteProfileID: UUID(), operation: .tags, modelName: "m", items: items)
    XCTAssertEqual(queue.items.count, 100)
    XCTAssertEqual(queue.items.first?.draftID, duplicateID)
    XCTAssertEqual(queue.items[1].draftTitle, "1")
    XCTAssertFalse(queue.items.dropFirst().contains { $0.draftID == duplicateID })
  }

  func testRecoveryRequeuesRunningAndPausesQueue() {
    var queue = makeQueue()
    let item = queue.beginNext()!
    queue.recoverInterrupted()
    XCTAssertTrue(queue.isPaused)
    XCTAssertEqual(queue.items.first(where: { $0.id == item.id })?.status, .pending)
    XCTAssertNil(queue.beginNext())
  }

  func testLegacyItemWithoutModelNameDecodesAndUsesQueueModel() throws {
    let queue = AIBatchMaintenanceQueue(
      siteProfileID: UUID(), operation: .summary, modelName: "legacy-model",
      items: [
        AIBatchMaintenanceItem(
          draftID: UUID(), draftTitle: "旧文章", sourceFingerprint: "legacy-fingerprint",
          modelName: "old-item-model")
      ]
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(queue)) as? [String: Any]
    )
    var items = try XCTUnwrap(object["items"] as? [[String: Any]])
    items[0].removeValue(forKey: "modelName")
    object["items"] = items
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(AIBatchMaintenanceQueue.self, from: legacyData)

    XCTAssertNil(decoded.items[0].modelName)
    XCTAssertEqual(decoded.displayModelName, "legacy-model")
  }

  func testLateCompletionIsIgnoredAndProgressCountsAreUseful() throws {
    var queue = makeQueue(2)
    let item = try XCTUnwrap(queue.beginNext())
    queue.skip(id: item.id)
    queue.complete(id: item.id, resultText: "late")
    XCTAssertEqual(queue.items[0].status, .skipped)
    XCTAssertEqual(queue.skippedCount, 1)
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertEqual(queue.progressFraction, 0.5)
  }

  func testCodableRoundTripPreservesQueueState() throws {
    var queue = makeQueue()
    let item = queue.beginNext()!
    queue.complete(id: item.id, resultText: "摘要")
    queue.pause()
    let decoded = try JSONDecoder().decode(
      AIBatchMaintenanceQueue.self, from: JSONEncoder().encode(queue))
    XCTAssertEqual(decoded, queue)
  }
}
