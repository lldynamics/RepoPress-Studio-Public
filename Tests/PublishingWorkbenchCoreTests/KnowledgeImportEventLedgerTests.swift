import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class KnowledgeImportEventLedgerTests: XCTestCase {
  func testLibraryImportPersistsOnlyOutcomeAndCountsThroughWorkbenchComposition() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-ledger-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("private-source.md")
    let privateText = "# Private source\n\nPrivate body canary 927415."
    try privateText.write(to: source, atomically: true, encoding: .utf8)
    let persistence = WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: root.appendingPathComponent("library", isDirectory: true)
      )
    )

    let preview = try await store.knowledge.makeImportPreview(sourceURL: source)
    let result = try await store.knowledge.commit(preview)
    let flushed = await store.operationHistory.flush()
    XCTAssertNotNil(flushed)
    XCTAssertEqual(result.insertedCount, 1)
    let loaded = try WorkbenchOperationLedgerPersistence(
      fileURL: persistence.operationLedgerURL
    ).loadWithRecovery()
    let record = try XCTUnwrap(loaded.document.records.last)
    XCTAssertEqual(record.kind, .knowledgeImport)
    XCTAssertEqual(record.outcome, .succeeded)
    XCTAssertEqual(record.actor, .user)
    XCTAssertEqual(record.createdItemCount, result.insertedCount)
    XCTAssertEqual(record.updatedItemCount, result.updatedCount)
    XCTAssertEqual(record.skippedItemCount, result.skippedCount)
    XCTAssertEqual(record.id, store.operationHistory.records.last?.id)
    let persistedTime = try XCTUnwrap(record.occurredAt)
    let recordedTime = try XCTUnwrap(store.operationHistory.records.last?.occurredAt)
    // The ledger stores seconds since 1970 as a JSON number. Converting Date's
    // reference epoch to that number and back can lose sub-microsecond precision.
    XCTAssertEqual(
      persistedTime.timeIntervalSince1970, recordedTime.timeIntervalSince1970,
      accuracy: 0.000_001)
    XCTAssertNil(record.draftID)
    XCTAssertNil(record.profileID)
    let ledger = try String(contentsOf: persistence.operationLedgerURL, encoding: .utf8)
    XCTAssertFalse(ledger.contains("927415"))
    XCTAssertFalse(ledger.contains(source.path))
  }
}
