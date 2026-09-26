import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeNoteRestoreBoundaryTests: XCTestCase {
  func testLibraryRestoreFetchesBeforeDerivingDeletionsAndMergesRemoteNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-restore-boundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library")
    let backup = root.appendingPathComponent("old.pslibrarybackup")
    let remoteChanges = try await makeRestoreFixture(library: library, backup: backup)

    let result = KnowledgeLibraryService.applyPendingRestoreIfNeeded(rootURL: library)
    guard case .restored = result else { return XCTFail("Restore failed: \(result)") }
    let restoreID = try XCTUnwrap(KnowledgeNoteCloudRestoreBoundary.restoreID(at: library))
    let service = KnowledgeLibraryService(rootURL: library)
    let adapter = KnowledgeNoteCloudSyncAdapter(service: service)
    var state = try await adapter.loadPersistentState()
    XCTAssertNil(state.engineState)
    XCTAssertFalse(state.initialFetchComplete)
    XCTAssertEqual(state.boundAccountID, "original-account")
    XCTAssertTrue(state.zoneEstablished)
    XCTAssertTrue(state.attachmentBaselines.isEmpty)
    let beforeFetch = try await adapter.localChanges()
    XCTAssertTrue(beforeFetch.isEmpty)

    for change in remoteChanges {
      guard case .upsert(let note, let revision, _) = change else {
        return XCTFail("Expected note fixture")
      }
      _ = try await adapter.applyRemote(.note(note, sha256: revision, systemFields: Data([2])))
    }
    state.initialFetchComplete = true
    state.engineState = Data([9])
    try await adapter.savePersistentState(state)
    let afterFetch = try await adapter.localChanges()
    XCTAssertTrue(afterFetch.isEmpty)
    XCTAssertEqual(Set(try service.notes().map(\.title)), ["Before backup", "After backup"])

    // Loading the same restored generation again must not reset a completed fetch.
    let reopened = KnowledgeNoteCloudSyncAdapter(service: service)
    let reopenedState = try await reopened.loadPersistentState()
    XCTAssertTrue(reopenedState.initialFetchComplete)
    XCTAssertEqual(reopenedState.engineState, Data([9]))

    let nextBackup = root.appendingPathComponent("next.pslibrarybackup")
    _ = try await service.createBackup(at: nextBackup)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: nextBackup.appendingPathComponent(KnowledgeNoteCloudRestoreBoundary.fileName).path))
    _ = try await service.stageRestore(from: backup)
    guard case .restored = KnowledgeLibraryService.applyPendingRestoreIfNeeded(rootURL: library)
    else { return XCTFail("Second restore failed") }
    XCTAssertNotEqual(try KnowledgeNoteCloudRestoreBoundary.restoreID(at: library), restoreID)
  }

  func testRestoreKeepsAccountAndDeletedZoneRecoveryLock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-restore-locked-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library")
    let service = KnowledgeLibraryService(rootURL: library)
    _ = try service.createNote(KnowledgeNote(title: "Local", markdown: "retained"))
    let adapter = KnowledgeNoteCloudSyncAdapter(service: service)
    try await adapter.savePersistentState(
      .init(
        engineState: Data([1]), boundAccountID: "old-account", initialFetchComplete: true,
        zoneRecoveryRequired: true, zoneEstablished: true))
    try KnowledgeNoteCloudRestoreBoundary.markRestoredLibrary(at: library)
    let reopened = KnowledgeNoteCloudSyncAdapter(service: service)
    let state = try await reopened.loadPersistentState()
    XCTAssertEqual(state.boundAccountID, "old-account")
    XCTAssertTrue(state.zoneRecoveryRequired)
    XCTAssertTrue(state.zoneEstablished)
    XCTAssertFalse(state.initialFetchComplete)
    XCTAssertTrue(RPNoteCloudBootstrapPolicy.accountChanged("another-account", saved: state))
    let changes = try await reopened.localChanges()
    XCTAssertTrue(changes.isEmpty)
  }

  func testCorruptRestoreMarkerDoesNotConsumeExistingSyncState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-restore-corrupt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library")
    let service = KnowledgeLibraryService(rootURL: library)
    _ = try service.createNote(KnowledgeNote(title: "Local", markdown: "retained"))
    let stateDirectory = root.appendingPathComponent("sidecar")
    let stateFile = stateDirectory.appendingPathComponent("adapter-state.json")
    let adapter = KnowledgeNoteCloudSyncAdapter(service: service, stateDirectoryURL: stateDirectory)
    try await adapter.savePersistentState(
      .init(
        engineState: Data([1]), boundAccountID: "account", initialFetchComplete: true))
    let before = try Data(contentsOf: stateFile)
    try Data("invalid".utf8).write(
      to: library.appendingPathComponent(KnowledgeNoteCloudRestoreBoundary.fileName))
    let reopened = KnowledgeNoteCloudSyncAdapter(
      service: service, stateDirectoryURL: stateDirectory)
    do {
      _ = try await reopened.loadPersistentState()
      XCTFail("Corrupt restore identity must block sync")
    } catch {
      XCTAssertEqual(try Data(contentsOf: stateFile), before)
    }
  }

  func testRestoreResetFailureRetriesWithoutAcceptingStaleBaseline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-restore-persist-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library")
    let service = KnowledgeLibraryService(rootURL: library)
    _ = try service.createNote(KnowledgeNote(title: "Local", markdown: "retained"))
    try KnowledgeNoteCloudRestoreBoundary.markRestoredLibrary(at: library)
    let blockedDirectory = root.appendingPathComponent("blocked-sidecar")
    try Data("not a directory".utf8).write(to: blockedDirectory)
    let adapter = KnowledgeNoteCloudSyncAdapter(
      service: service, stateDirectoryURL: blockedDirectory)
    do {
      _ = try await adapter.loadPersistentState()
      XCTFail("A failed reset must not enable sync")
    } catch {
      XCTAssertNotNil(try KnowledgeNoteCloudRestoreBoundary.restoreID(at: library))
    }
    try FileManager.default.removeItem(at: blockedDirectory)
    let state = try await adapter.loadPersistentState()
    XCTAssertFalse(state.initialFetchComplete)
    let changes = try await adapter.localChanges()
    XCTAssertTrue(changes.isEmpty)
  }

  func testPreviouslyAcceptedRestoreMarkerCannotDisappearSilently() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-restore-missing-id-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root.appendingPathComponent("library"))
    _ = try service.createNote(KnowledgeNote(title: "Local", markdown: "retained"))
    try KnowledgeNoteCloudRestoreBoundary.markRestoredLibrary(at: service.rootURL)
    let first = KnowledgeNoteCloudSyncAdapter(service: service)
    _ = try await first.loadPersistentState()
    try FileManager.default.removeItem(
      at: service.rootURL.appendingPathComponent(KnowledgeNoteCloudRestoreBoundary.fileName))
    let reopened = KnowledgeNoteCloudSyncAdapter(service: service)
    do {
      _ = try await reopened.loadPersistentState()
      XCTFail("Removing an accepted restore marker must pause sync")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("恢复标识缺失"))
    }
  }

  private func makeRestoreFixture(library: URL, backup: URL) async throws
    -> [RPNoteCloudLocalChange]
  {
    let service = KnowledgeLibraryService(rootURL: library)
    _ = try service.createNote(KnowledgeNote(title: "Before backup", markdown: "old"))
    _ = try await service.createBackup(at: backup)
    _ = try service.createNote(KnowledgeNote(title: "After backup", markdown: "new"))
    let adapter = KnowledgeNoteCloudSyncAdapter(service: service)
    try await adapter.savePersistentState(
      .init(
        engineState: Data([1]), boundAccountID: "original-account", initialFetchComplete: true,
        zoneEstablished: true,
        attachmentBaselines: ["old": .init(noteID: "old", sha256: "old", systemFields: nil)]))
    let changes = try await adapter.localChanges()
    for change in changes {
      await adapter.prepareForSend(change)
      try await adapter.markSent(id: change.id, revision: change.revision, systemFields: Data([1]))
    }
    _ = try await service.stageRestore(from: backup)
    return changes
  }
}
