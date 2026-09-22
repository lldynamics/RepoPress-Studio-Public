import Foundation
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchRecordPersistenceTests: XCTestCase {
  func testLegacyJSONMigratesAndKeepsMigrationSource() throws {
    let (root, persistence, snapshot) = try fixture(
      title: "legacy", body: "正文", withConversation: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyData = try JSONEncoder.workbench.encode(snapshot)
    try legacyData.write(to: persistence.fileURL)
    try legacyData.write(to: persistence.lastKnownGoodURL)

    _ = try persistence.load()
    XCTAssertEqual(try persistence.save(snapshot), .saved)
    XCTAssertEqual(try persistence.load(), try normalized(snapshot))
    let migration = persistence.recordStoreDirectoryURL
      .appendingPathComponent(try manifestStoreID(from: persistence.fileURL))
      .appendingPathComponent("MigrationSource")
    XCTAssertEqual(
      try Data(contentsOf: migration.appendingPathComponent("workbench.json")), legacyData)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: migration.appendingPathComponent(persistence.lastKnownGoodURL.lastPathComponent)
          .path))
  }

  func testBodyIsMarkdownAndUnchangedRowsAreNotRewritten() throws {
    let (root, persistence, snapshot) = try fixture(title: "body", body: "秘密正文")
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try persistence.save(snapshot), .saved)
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.fileURL))
    let directory = persistence.recordStoreDirectoryURL.appendingPathComponent(
      manifest.storeID.uuidString)
    let recordsURL = directory.appendingPathComponent("records.sqlite")
    let rows = try WorkbenchRecordDatabase(url: recordsURL).records()
    let draftRow = try XCTUnwrap(rows.first { $0.collection == "drafts" })
    XCTAssertFalse(String(decoding: draftRow.data, as: UTF8.self).contains("秘密正文"))
    let document = directory.appendingPathComponent("Documents").appendingPathComponent(
      WorkbenchRecordPayload.digest(Data("秘密正文".utf8)) + ".md")
    XCTAssertEqual(try Data(contentsOf: document), Data("秘密正文".utf8))
    let database = try WorkbenchRecordDatabase(url: recordsURL)
    let payload = try WorkbenchRecordPayload(snapshot: snapshot)
    XCTAssertEqual(try database.replace(with: payload.records), 0)
  }

  func testEmptyMarkdownCanBeReusedAcrossSavesAndIndependentRecovery() throws {
    let (root, persistence, first) = try fixture(title: "empty", body: "")
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try persistence.save(first), .saved)
    XCTAssertEqual(try persistence.save(first), .saved)

    var changedMetadata = first
    changedMetadata.drafts[0].title = "still-empty"
    XCTAssertEqual(try persistence.save(changedMetadata), .saved)
    XCTAssertEqual(try persistence.loadPrimarySnapshot(), try normalized(changedMetadata))

    let generation = persistence.recordStoreDirectoryURL.appendingPathComponent(
      try manifestStoreID(from: persistence.fileURL))
    let emptyObjectName = WorkbenchRecordPayload.digest(Data()) + ".md"
    for directory in ["Documents", "RecoveryDocuments"] {
      let object = generation.appendingPathComponent(directory).appendingPathComponent(
        emptyObjectName)
      XCTAssertEqual(try Data(contentsOf: object), Data())
    }

    // A one-byte replacement must still fail the content-address check.
    let primaryObject = generation.appendingPathComponent("Documents").appendingPathComponent(
      emptyObjectName)
    try Data([0x78]).write(to: primaryObject)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
    let recovery = try persistence.loadWithRecovery()
    XCTAssertEqual(recovery.snapshot, try normalized(first))
    XCTAssertNotNil(recovery.recoveryMessage)
  }

  func testDamagedPrimaryRecoversPreviousGenerationAndDocuments() throws {
    let (root, persistence, first) = try fixture(title: "first", body: "第一代")
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try persistence.save(first), .saved)
    var second = first
    second.drafts[0].title = "second"
    second.drafts[0].bodyMarkdown = "第二代"
    XCTAssertEqual(try persistence.save(second), .saved)
    try Data("damaged".utf8).write(to: persistence.fileURL)
    let result = try persistence.loadWithRecovery()
    XCTAssertEqual(result.snapshot, try normalized(first))
    XCTAssertTrue(result.recoveryMessage?.contains("恢复") == true)
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.lastKnownGoodURL))
    XCTAssertTrue(manifest.recovery)
    let recoveryDocument = persistence.recordStoreDirectoryURL.appendingPathComponent(
      manifest.storeID.uuidString
    ).appendingPathComponent("RecoveryDocuments")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recoveryDocument.appendingPathComponent(
          WorkbenchRecordPayload.digest(Data("第一代".utf8)) + ".md"
        ).path))
  }

  func testFailureBeforeManifestInstallLeavesLegacyReadable() throws {
    let (root, persistence, snapshot) = try fixture(title: "legacy", body: "old")
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONEncoder.workbench.encode(snapshot).write(to: persistence.fileURL)
    _ = try persistence.load()
    var reachedCheckpoint = false
    XCTAssertThrowsError(
      try persistence.commitRecords(
        try WorkbenchRecordPayload(snapshot: snapshot), retiredArchives: []
      ) { checkpoint in
        if case .beforeManifestInstall = checkpoint {
          reachedCheckpoint = true
          throw TestFailure.injected
        }
      })
    XCTAssertTrue(reachedCheckpoint, "注入点必须实际到达")
    XCTAssertEqual(
      try JSONDecoder.workbench.decode(
        WorkbenchSnapshot.self, from: Data(contentsOf: persistence.fileURL)),
      try normalized(snapshot))
  }

  func testDatabaseCommittedFailureStillReopensCompleteNewData() throws {
    let (root, persistence, first) = try fixture(title: "first", body: "one")
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try persistence.save(first), .saved)
    var second = first
    second.drafts[0].title = "new"
    let payload = try WorkbenchRecordPayload(snapshot: second)
    _ = try persistence.load()
    XCTAssertThrowsError(
      try persistence.commitRecords(payload, retiredArchives: []) { checkpoint in
        if case .databaseCommitted = checkpoint { throw TestFailure.injected }
      })
    XCTAssertEqual(try persistence.loadPrimarySnapshot(), try normalized(second))
  }

  func testMissingOrCorruptMarkdownIsRejected() throws {
    let (root, persistence, snapshot) = try fixture(title: "body", body: "required")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try persistence.save(snapshot)
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.fileURL))
    let dir = persistence.recordStoreDirectoryURL.appendingPathComponent(
      manifest.storeID.uuidString
    ).appendingPathComponent("Documents")
    let doc = dir.appendingPathComponent(
      WorkbenchRecordPayload.digest(Data("required".utf8)) + ".md")
    try Data("wrong".utf8).write(to: doc)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
    try FileManager.default.removeItem(at: doc)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
  }

  func testDifferentFileURLsInSameDirectoryDoNotMixStores() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = WorkbenchPersistence(fileURL: root.appendingPathComponent("a.json"))
    let b = WorkbenchPersistence(fileURL: root.appendingPathComponent("b.json"))
    let (_, _, first) = try fixture(title: "A", body: "a", root: root)
    var second = first
    second.drafts[0].title = "B"
    _ = try a.save(first)
    _ = try b.save(second)
    XCTAssertEqual(try a.load()?.drafts[0].title, "A")
    XCTAssertEqual(try b.load()?.drafts[0].title, "B")
  }

  func testBadAndSymlinkManifestOrObjectIsRejected() throws {
    let (root, initialPersistence, snapshot) = try fixture(title: "safe", body: "safe")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: initialPersistence.fileURL)
    XCTAssertThrowsError(try initialPersistence.loadPrimarySnapshot())
    try FileManager.default.removeItem(at: initialPersistence.fileURL)
    let persistence = WorkbenchPersistence(fileURL: initialPersistence.fileURL)
    _ = try persistence.save(snapshot)
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.fileURL))
    let doc = persistence.recordStoreDirectoryURL.appendingPathComponent(
      manifest.storeID.uuidString
    ).appendingPathComponent("Documents").appendingPathComponent(
      WorkbenchRecordPayload.digest(Data("safe".utf8)) + ".md")
    try FileManager.default.removeItem(at: doc)
    try FileManager.default.createSymbolicLink(at: doc, withDestinationURL: persistence.fileURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
  }

  func testThreeGenerationsRetainCurrentAndRecoveryDocumentsAndCollectOrphans() throws {
    let (root, persistence, first) = try fixture(title: "first", body: "第一代")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try persistence.save(first)
    var second = first
    second.drafts[0].bodyMarkdown = "第二代"
    _ = try persistence.save(second)
    var third = second
    third.drafts[0].bodyMarkdown = "第三代"
    _ = try persistence.save(third)

    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.fileURL))
    let directory = persistence.recordStoreDirectoryURL.appendingPathComponent(
      manifest.storeID.uuidString)
    let current = directory.appendingPathComponent("Documents")
    let recovery = directory.appendingPathComponent("RecoveryDocuments")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: current.appendingPathComponent(
          WorkbenchRecordPayload.digest(Data("第三代".utf8)) + ".md"
        ).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recovery.appendingPathComponent(
          WorkbenchRecordPayload.digest(Data("第二代".utf8)) + ".md"
        ).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: current.appendingPathComponent(
          WorkbenchRecordPayload.digest(Data("第一代".utf8)) + ".md"
        ).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: recovery.appendingPathComponent(
          WorkbenchRecordPayload.digest(Data("第一代".utf8)) + ".md"
        ).path))
    XCTAssertEqual(try persistence.loadPrimarySnapshot().drafts[0].bodyMarkdown, "第三代")
  }

  func testFutureRecordDatabaseVersionFailsClosedWithoutFallback() throws {
    let (root, persistence, snapshot) = try fixture(title: "future-db", body: "body")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try persistence.save(snapshot)
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self, from: Data(contentsOf: persistence.fileURL))
    let databaseURL = persistence.recordStoreDirectoryURL
      .appendingPathComponent(manifest.storeID.uuidString).appendingPathComponent("records.sqlite")
    let futureVersion = 3
    try executeSQLite("PRAGMA user_version = \(futureVersion);", at: databaseURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot()) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("应拒绝未来记录数据库版本，实际为：\(error)")
      }
    }
    XCTAssertThrowsError(try persistence.save(snapshot)) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("保存不得回退到新存储代，实际为：\(error)")
      }
    }
  }

  func testFutureManifestAndLegacySnapshotAreRejectedWithoutFallbackOrSave() throws {
    let (root, persistence, snapshot) = try fixture(title: "future", body: "body")
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestData = try JSONEncoder().encode(
      WorkbenchRecordManifest(
        storeID: UUID(), directoryName: persistence.recordStoreDirectoryURL.lastPathComponent))
    var manifestObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    manifestObject.removeValue(forKey: "storageVersion")
    try JSONSerialization.data(withJSONObject: manifestObject).write(to: persistence.fileURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot()) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("缺少 marker 版本字段时必须拒绝，实际为：\(error)")
      }
    }
    manifestObject["storage"] = "future-repopress"
    manifestObject["storageVersion"] = 1
    try JSONSerialization.data(withJSONObject: manifestObject).write(to: persistence.fileURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
    XCTAssertThrowsError(try persistence.save(snapshot)) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("Expected unsupported storage format, got \(error)")
      }
    }

    manifestObject["storage"] = WorkbenchRecordManifest.storageName
    manifestObject["storageVersion"] = 2
    let futureSchema = try JSONSerialization.data(withJSONObject: manifestObject)
    try futureSchema.write(to: persistence.fileURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
    XCTAssertThrowsError(try persistence.save(snapshot)) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("Expected unsupported schema version, got \(error)")
      }
    }

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any])
    legacyObject["formatVersion"] = WorkbenchSnapshot.currentFormatVersion + 1
    let futureLegacy = try JSONSerialization.data(withJSONObject: legacyObject)
    try futureLegacy.write(to: persistence.fileURL)
    XCTAssertThrowsError(try persistence.loadPrimarySnapshot())
    XCTAssertThrowsError(try persistence.save(snapshot)) { error in
      guard case WorkbenchRecordStorageError.unsupportedVersion = error else {
        return XCTFail("Expected unsupported legacy version, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: persistence.fileURL), futureLegacy)
  }

  func testStaleWriterCannotOverwriteAnotherInstancesCommit() throws {
    let (root, first, snapshot) = try fixture(title: "base", body: "base body")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try first.save(snapshot)
    let second = WorkbenchPersistence(fileURL: first.fileURL)
    var stale = try XCTUnwrap(second.load())
    var latest = snapshot
    latest.drafts[0].title = "first writer"
    _ = try first.save(latest)
    stale.drafts[0].bodyMarkdown = "second writer body"
    XCTAssertThrowsError(try second.save(stale))
    XCTAssertEqual(try first.load()?.drafts[0].title, "first writer")
    XCTAssertEqual(try first.load()?.drafts[0].bodyMarkdown, "base body")
  }

  func testNewInstanceCannotOverwriteWithoutLoadingExistingRecord() throws {
    let (root, persistence, snapshot) = try fixture(title: "loaded", body: "baseline")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try persistence.save(snapshot)
    let fresh = WorkbenchPersistence(fileURL: persistence.fileURL)
    var replacement = snapshot
    replacement.drafts[0].bodyMarkdown = "untrusted replacement"
    XCTAssertThrowsError(try fresh.save(replacement)) { error in
      guard case WorkbenchRecordStorageError.invalidData(let message) = error else {
        return XCTFail("未载入的实例不得覆盖已有记录，实际为：\(error)")
      }
      XCTAssertTrue(message.contains("载入"))
    }
    XCTAssertEqual(try persistence.loadPrimarySnapshot().drafts[0].bodyMarkdown, "baseline")
  }

  func testRecoveryLoadBaselineStillRejectsStaleWriterAfterAnotherRecoveryInstall() throws {
    let (root, persistence, first) = try fixture(title: "recovery-cas", body: "第一代")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try persistence.save(first)
    let stale = WorkbenchPersistence(fileURL: persistence.fileURL)
    _ = try stale.load()
    try Data("damaged-primary".utf8).write(to: persistence.fileURL)
    let recovered = try stale.loadWithRecovery()
    XCTAssertEqual(recovered.snapshot, try normalized(first))

    let repairingWriter = WorkbenchPersistence(fileURL: persistence.fileURL)
    _ = try repairingWriter.loadWithRecovery()
    var repaired = first
    repaired.drafts[0].bodyMarkdown = "修复后的新一代"
    _ = try repairingWriter.save(repaired)

    var staleEdit = first
    staleEdit.drafts[0].bodyMarkdown = "过期写入"
    XCTAssertThrowsError(try stale.save(staleEdit)) { error in
      guard case WorkbenchRecordStorageError.invalidData(let message) = error else {
        return XCTFail("恢复读取后的旧 writer 必须遵守 CAS，实际为：\(error)")
      }
      XCTAssertTrue(message.contains("另一个写入者"))
    }
    XCTAssertEqual(try persistence.loadPrimarySnapshot().drafts[0].bodyMarkdown, "修复后的新一代")
  }

  private func fixture(
    title: String, body: String, withConversation: Bool = false, root: URL? = nil
  ) throws -> (URL, WorkbenchPersistence, WorkbenchSnapshot) {
    let resolvedRoot: URL
    if let root { resolvedRoot = root } else { resolvedRoot = try makeRoot() }
    let root = resolvedRoot
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      id: UUID(), siteProfileID: profile.id, title: title, slug: title, bodyMarkdown: body)
    let message = AIPublishingChatMessage(role: .user, content: "history")
    let conversation = AIConversation(
      scope: .general, title: "chat", messages: withConversation ? [message] : [])
    let release = ReleaseRecord(
      title: "发布历史", summary: "历史记录", siteProfileID: profile.id, draftID: draft.id)
    let snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [draft], releaseRecords: [release],
      aiConversations: withConversation ? [conversation] : [])
    return (
      root, WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json")), snapshot
    )
  }

  private func manifestStoreID(from fileURL: URL) throws -> String {
    try JSONDecoder().decode(WorkbenchRecordManifest.self, from: Data(contentsOf: fileURL)).storeID
      .uuidString
  }

  private func normalized(_ snapshot: WorkbenchSnapshot) throws -> WorkbenchSnapshot {
    try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self, from: JSONEncoder.workbench.encode(snapshot))
  }

  private func executeSQLite(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
      throw NSError(domain: "WorkbenchRecordPersistenceTests", code: 1)
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "WorkbenchRecordPersistenceTests", code: 2)
    }
  }

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "record-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

private enum TestFailure: Error { case injected }
