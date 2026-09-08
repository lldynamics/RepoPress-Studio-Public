import Foundation
import PublishingKnowledgeCore
import XCTest
@testable import PersonalSitePublisherMac

final class KnowledgeBrowserImportLedgerStoreTests: XCTestCase {
  func testPersistWritesAtomicFileAndRemovesLegacyDefaults() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(Data("legacy".utf8), forKey: fixture.legacyKey)
    let fileURL = fixture.rootURL.appendingPathComponent("ledger.plist")
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )
    let record = makeRecord(seed: 1)

    try await store.persist([record])

    let restored = try PropertyListDecoder().decode(
      [KnowledgeBrowserImportOperationRecord].self,
      from: Data(contentsOf: fileURL)
    )
    XCTAssertEqual(restored, [record])
    XCTAssertNil(fixture.defaults.object(forKey: fixture.legacyKey))
  }

  func testPersistFallsBackToDefaultsWhenFileURLIsUnavailable() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: nil,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )
    let record = makeRecord(seed: 2)

    try await store.persist([record])

    let data = try XCTUnwrap(fixture.defaults.data(forKey: fixture.legacyKey))
    let restored = try PropertyListDecoder().decode(
      [KnowledgeBrowserImportOperationRecord].self,
      from: data
    )
    XCTAssertEqual(restored, [record])
  }

  func testConcurrentPersistsNeverLeavePartialLedger() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let fileURL = fixture.rootURL.appendingPathComponent("ledger.plist")
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )
    let records = (0..<12).map { makeRecord(seed: $0) }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for record in records {
        group.addTask {
          try await store.persist([record])
        }
      }
      try await group.waitForAll()
    }

    let restored = try PropertyListDecoder().decode(
      [KnowledgeBrowserImportOperationRecord].self,
      from: Data(contentsOf: fileURL)
    )
    XCTAssertEqual(restored.count, 1)
    XCTAssertTrue(records.contains(restored[0]))
  }

  func testArchiveUnreadableLedgerMovesBytesAndClearsLegacyDefaults() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let fileURL = fixture.rootURL.appendingPathComponent("ledger.plist")
    let corruptData = Data("not a property list".utf8)
    try corruptData.write(to: fileURL)
    fixture.defaults.set(Data("legacy".utf8), forKey: fixture.legacyKey)
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )

    let archivedURL = try await store.archiveUnreadableLedger()
    let archiveURL = try XCTUnwrap(archivedURL)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(try Data(contentsOf: archiveURL), corruptData)
    XCTAssertNil(fixture.defaults.object(forKey: fixture.legacyKey))
  }

  func testLoadPrunedDecodesAndMigratesLedgerOffTheCaller() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let fileURL = fixture.rootURL.appendingPathComponent("ledger.plist")
    let record = makeRecord(seed: 4)
    try PropertyListEncoder().encode([record]).write(to: fileURL)
    fixture.defaults.set(Data("legacy".utf8), forKey: fixture.legacyKey)
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )

    let result = await store.loadPruned(
      at: record.completedAt.addingTimeInterval(60)
    )

    XCTAssertEqual(result.ledger.records, [record])
    XCTAssertNil(result.persistenceIssue)
    XCTAssertNil(result.issueKind)
    XCTAssertNil(fixture.defaults.object(forKey: fixture.legacyKey))
  }

  func testLoadPrunedReportsUnreadableLedgerWithoutOverwritingIt() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let fileURL = fixture.rootURL.appendingPathComponent("ledger.plist")
    let corruptData = Data("not a property list".utf8)
    try corruptData.write(to: fileURL)
    let store = KnowledgeBrowserImportLedgerStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
    )

    let result = await store.loadPruned(at: Date())

    XCTAssertTrue(result.ledger.records.isEmpty)
    XCTAssertNotNil(result.persistenceIssue)
    guard case .unreadable? = result.issueKind else {
      return XCTFail("Expected an unreadable ledger issue")
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
  }

  private func makeRecord(seed: Int) -> KnowledgeBrowserImportOperationRecord {
    let operationID = UUID()
    var ledger = KnowledgeBrowserImportOperationLedger()
    ledger.record(
      operationID: operationID,
      requestFingerprint: "capture-\(seed)",
      receipt: KnowledgeBrowserImportReceipt(
        operationID: operationID,
        insertedCount: 1,
        updatedCount: 0,
        skippedCount: 0,
        action: KnowledgeBrowserImportAction.inserted.rawValue,
        documentID: UUID(),
        title: "Ledger \(seed)",
        sourceURL: URL(string: "https://example.com/\(seed)"),
        folder: KnowledgeBrowserReceiptFolder(id: UUID(), name: "Reference"),
        fileSizeBytes: Int64(seed + 1),
        archiveType: "html",
        indexStatus: "ready",
        allowsAIUse: true,
        savedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seed))
      ),
      completedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seed))
    )
    return ledger.records[0]
  }

  private func makeFixture() throws -> LedgerFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "browser-ledger-store-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let suiteName = "KnowledgeBrowserImportLedgerStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return LedgerFixture(
      rootURL: rootURL,
      defaults: defaults,
      suiteName: suiteName,
      legacyKey: "legacy-ledger"
    )
  }
}

private struct LedgerFixture {
  let rootURL: URL
  let defaults: UserDefaults
  let suiteName: String
  let legacyKey: String

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: rootURL)
  }
}
