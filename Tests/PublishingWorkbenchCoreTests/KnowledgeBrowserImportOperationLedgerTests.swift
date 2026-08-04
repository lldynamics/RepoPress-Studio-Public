import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeBrowserImportOperationLedgerTests: XCTestCase {
  func testCompletedOperationReplaysSameReceiptAfterPersistenceRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let operationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let documentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    var ledger = KnowledgeBrowserImportOperationLedger()
    ledger.record(
      operationID: operationID,
      requestFingerprint: "capture-a",
      receipt: receipt(operationID: operationID, documentID: documentID),
      completedAt: now
    )

    let data = try PropertyListEncoder().encode(ledger.records)
    let restoredRecords = try PropertyListDecoder().decode(
      [KnowledgeBrowserImportOperationRecord].self,
      from: data
    )
    var restored = KnowledgeBrowserImportOperationLedger(records: restoredRecords)

    guard case .replay(let replayed) = restored.lookup(
      operationID: operationID,
      requestFingerprint: "capture-a",
      now: now.addingTimeInterval(30),
      documentExists: { $0 == documentID }
    ) else {
      return XCTFail("Expected a persisted completed operation to replay")
    }
    XCTAssertEqual(replayed.documentID, documentID)
    XCTAssertTrue(replayed.replayed)
    XCTAssertEqual(restored.records.count, 1)
  }

  func testOperationIDRejectsDifferentRequestAndDoesNotReplayDeletedDocument() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let operationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let documentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    var ledger = KnowledgeBrowserImportOperationLedger()
    ledger.record(
      operationID: operationID,
      requestFingerprint: "capture-a",
      receipt: receipt(operationID: operationID, documentID: documentID),
      completedAt: now
    )

    XCTAssertEqual(
      ledger.lookup(
        operationID: operationID,
        requestFingerprint: "capture-b",
        now: now,
        documentExists: { _ in true }
      ),
      .conflictingRequest
    )
    XCTAssertEqual(
      ledger.lookup(
        operationID: operationID,
        requestFingerprint: "capture-a",
        now: now,
        documentExists: { _ in false }
      ),
      .missingDocument
    )
    XCTAssertTrue(ledger.records.isEmpty)
  }

  func testLedgerPrunesExpiredAndOldestOverflowRecords() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let ids = [
      UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
      UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    ]
    var ledger = KnowledgeBrowserImportOperationLedger(
      maximumRecordCount: 2,
      retentionInterval: 120
    )
    for (index, operationID) in ids.enumerated() {
      ledger.record(
        operationID: operationID,
        requestFingerprint: "capture-\(index)",
        receipt: receipt(operationID: operationID, documentID: UUID()),
        completedAt: now.addingTimeInterval(Double(index * 10))
      )
    }
    XCTAssertEqual(Set(ledger.records.map(\.operationID)), Set(ids.suffix(2)))

    ledger.prune(at: now.addingTimeInterval(140))
    XCTAssertEqual(ledger.records.map(\.operationID), [ids[2]])
  }

  private func receipt(
    operationID: UUID,
    documentID: UUID
  ) -> KnowledgeBrowserImportReceipt {
    KnowledgeBrowserImportReceipt(
      operationID: operationID,
      insertedCount: 1,
      updatedCount: 0,
      skippedCount: 0,
      action: KnowledgeBrowserImportAction.inserted.rawValue,
      documentID: documentID,
      title: "幂等保存资料",
      sourceURL: URL(string: "https://example.com/idempotent-receipt"),
      folder: KnowledgeBrowserReceiptFolder(id: UUID(), name: "长期参考"),
      fileSizeBytes: 2_048,
      archiveType: "html",
      indexStatus: "ready",
      allowsAIUse: true,
      savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}
