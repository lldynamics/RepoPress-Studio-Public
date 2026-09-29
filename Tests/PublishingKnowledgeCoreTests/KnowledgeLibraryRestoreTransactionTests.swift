import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeLibraryRestoreTransactionTests: XCTestCase {
  private struct InjectedFailure: Error {}

  func testInstalledJournalFailureCommitsOnceAndPreservesLaterEditsOnRestart() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let service = KnowledgeLibraryBackupService(
      rootURL: fixture.root,
      restoreTransactionCheckpoint: { if $0 == .installed { throw InjectedFailure() } }
    )
    let result = try XCTUnwrap(service.applyPendingRestoreIfNeeded())
    XCTAssertEqual(result.restoredPreview.backupURL, fixture.root)
    let previous = try XCTUnwrap(result.previousLibraryURL)
    XCTAssertEqual(
      try Data(contentsOf: previous.appendingPathComponent("old.txt")), Data("old".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
    let laterEdit = fixture.root.appendingPathComponent("later-edit.txt")
    try Data("keep this edit".utf8).write(to: laterEdit)

    XCTAssertNil(
      try KnowledgeLibraryBackupService(rootURL: fixture.root).applyPendingRestoreIfNeeded())
    XCTAssertEqual(try Data(contentsOf: laterEdit), Data("keep this edit".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
  }

  func testPreinstallJournalFailuresRollBackAndLeaveRestoreRetryable() throws {
    for phase in [
      KnowledgeLibraryBackupService.RestoreTransactionPhase.pendingMoved, .currentMoved,
    ] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let service = KnowledgeLibraryBackupService(
        rootURL: fixture.root,
        restoreTransactionCheckpoint: { if $0 == phase { throw InjectedFailure() } }
      )
      XCTAssertThrowsError(try service.applyPendingRestoreIfNeeded())
      XCTAssertEqual(
        try Data(contentsOf: fixture.root.appendingPathComponent("old.txt")), Data("old".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.pending.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
      XCTAssertNotNil(
        try KnowledgeLibraryBackupService(rootURL: fixture.root).applyPendingRestoreIfNeeded())
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
    }
  }

  func testLegacyAmbiguousInstallPreservesAllFilesWithoutReplay() throws {
    let fixture = try interruptedInstalledFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var journal = try fixture.journalObject()
    journal.removeValue(forKey: "installedRestoreID")
    try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journal)
    let marker = fixture.root.appendingPathComponent(KnowledgeNoteCloudRestoreBoundary.fileName)
    let markerBefore = try Data(contentsOf: marker)

    XCTAssertThrowsError(
      try KnowledgeLibraryBackupService(rootURL: fixture.root).applyPendingRestoreIfNeeded())
    XCTAssertEqual(try Data(contentsOf: marker), markerBefore)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: try XCTUnwrap(journal["applyingPath"] as? String)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
  }

  func testMismatchedOrCorruptInstalledIdentityPreservesRecoveryArtifacts() throws {
    for identity in [UUID().uuidString.lowercased(), "corrupt"] {
      let fixture = try interruptedInstalledFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let journalBefore = try Data(contentsOf: fixture.journal)
      let applyingPath = try XCTUnwrap(fixture.journalObject()["applyingPath"] as? String)
      try Data(identity.utf8).write(
        to: fixture.root.appendingPathComponent(KnowledgeNoteCloudRestoreBoundary.fileName))
      XCTAssertThrowsError(
        try KnowledgeLibraryBackupService(rootURL: fixture.root).applyPendingRestoreIfNeeded())
      XCTAssertEqual(try Data(contentsOf: fixture.journal), journalBefore)
      XCTAssertTrue(FileManager.default.fileExists(atPath: applyingPath))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
    }
  }

  func testLegacyInstalledJournalStillFinishesCleanup() throws {
    let fixture = try interruptedInstalledFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var journal = try fixture.journalObject()
    journal.removeValue(forKey: "installedRestoreID")
    journal["phase"] = "installed"
    try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journal)
    XCTAssertNil(
      try KnowledgeLibraryBackupService(rootURL: fixture.root).applyPendingRestoreIfNeeded())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
  }

  private struct Fixture {
    let directory: URL
    let root: URL
    var pending: URL { KnowledgeLibraryBackupService.pendingRestoreURL(for: root) }
    var journal: URL {
      directory.appendingPathComponent(".KnowledgeLibraryRestoreTransaction.json")
    }
    func journalObject() throws -> [String: Any] {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    }
  }

  private func interruptedInstalledFixture() throws -> Fixture {
    let fixture = try makeFixture()
    _ = try KnowledgeLibraryBackupService(
      rootURL: fixture.root,
      restoreTransactionCheckpoint: { if $0 == .installed { throw InjectedFailure() } }
    ).applyPendingRestoreIfNeeded()
    return fixture
  }

  private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("restore-transaction-\(UUID().uuidString)", isDirectory: true)
    let source = directory.appendingPathComponent("source", isDirectory: true)
    let root = directory.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: root.appendingPathComponent("old.txt"))
    let database = try KnowledgeDatabase(fileURL: source.appendingPathComponent("library.sqlite"))
    let backup = directory.appendingPathComponent("fixture.pslibrarybackup")
    _ = try KnowledgeLibraryBackupService(rootURL: source).createBackup(
      at: backup, database: database, applicationVersion: "test")
    _ = try KnowledgeLibraryBackupService(rootURL: root).stageRestore(from: backup)
    return Fixture(directory: directory, root: root)
  }
}
