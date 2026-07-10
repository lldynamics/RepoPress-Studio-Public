import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchPersistenceTests: XCTestCase {
  func testCorruptPrimaryRecoversLastKnownGoodSnapshot() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let snapshot = makeSnapshot()

    XCTAssertEqual(try persistence.save(snapshot), .saved)
    XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.lastKnownGoodURL.path))
    try "{ not valid JSON".write(to: url, atomically: true, encoding: .utf8)

    let result = try persistence.loadWithRecovery()
    XCTAssertEqual(result.snapshot?.drafts.first?.id, snapshot.drafts.first?.id)
    XCTAssertEqual(result.snapshot?.drafts.first?.title, snapshot.drafts.first?.title)
    XCTAssertNotNil(result.recoveryMessage)
  }

  func testLegacySnapshotWithoutFormatVersionMigratesOnLoad() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let encoded = try JSONEncoder.workbench.encode(makeSnapshot())
    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "formatVersion")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

    XCTAssertEqual(try persistence.load()?.formatVersion, WorkbenchSnapshot.currentFormatVersion)
  }

  func testStoreKeepsDirtyStateAndShowsFailureWhenPrimaryWriteFails() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacPersistenceFailure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let blockingURL = directoryURL.appendingPathComponent("not-a-directory")
    try "blocking file".write(to: blockingURL, atomically: true, encoding: .utf8)
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: blockingURL.appendingPathComponent("workbench.json")))

    store.save()

    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertNotNil(store.lastSaveError)
    XCTAssertTrue(store.lastSaveStatus.hasPrefix("保存失败："))
  }

  func testDraftEditsAutosaveAfterDebounceAndClearDirtyState() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var firstEdit = try XCTUnwrap(store.selectedDraft)
    firstEdit.title = "First edit"
    store.updateDraft(firstEdit)
    var finalEdit = try XCTUnwrap(store.selectedDraft)
    finalEdit.title = "Final debounced edit"
    store.updateDraft(finalEdit)

    XCTAssertTrue(store.hasUnsavedChanges)
    try await Task.sleep(nanoseconds: 900_000_000)

    XCTAssertFalse(store.hasUnsavedChanges)
    XCTAssertEqual(store.lastSaveStatus, "已保存")
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.selectedDraft?.title, "Final debounced edit")
  }

  func testFlushPendingChangesWritesImmediatelyBeforeExit() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var edited = try XCTUnwrap(store.selectedDraft)
    edited.bodyMarkdown = "# Flush before exit"
    store.updateDraft(edited)

    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertTrue(store.flushPendingChanges())
    XCTAssertFalse(store.hasUnsavedChanges)
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.selectedDraft?.bodyMarkdown, "# Flush before exit")
  }

  private func makeSnapshot() -> WorkbenchSnapshot {
    let profile = SiteProfile.defaultProfile
    return WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacPersistenceTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }
}
