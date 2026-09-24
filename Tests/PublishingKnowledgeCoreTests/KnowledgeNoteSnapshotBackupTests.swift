import Foundation
import XCTest
@testable import PublishingKnowledgeCore

final class KnowledgeNoteSnapshotBackupTests: XCTestCase {
  func testCreatesDistinctTimestampedSnapshotsAndReadsNotesAndAttachments() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("note-snapshots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let note = RPNote(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      title: "快照笔记", markdown: "版本一",
      attachments: [RPNoteAttachment(fileName: "附件.bin", mimeType: "application/octet-stream", data: Data([0, 1, 2]))]
    )
    let package = RPNotePackage(createdAt: Date(timeIntervalSince1970: 1_700_000_000), notes: [note])
    let timestamp = Date(timeIntervalSince1970: 1_700_000_100)

    let first = try KnowledgeNoteSnapshotBackupService.createSnapshot(package, in: directory, timestamp: timestamp)
    let second = try KnowledgeNoteSnapshotBackupService.createSnapshot(package, in: directory, timestamp: timestamp)

    XCTAssertNotEqual(first, second)
    XCTAssertTrue(first.lastPathComponent.hasPrefix("RepoPress-Notes-"))
    let restored = try KnowledgeNoteSnapshotBackupService.readSnapshot(at: first)
    XCTAssertEqual(restored.notes.map(\.id), package.notes.map(\.id))
    XCTAssertEqual(restored.notes[0].markdown, package.notes[0].markdown)
    XCTAssertEqual(restored.notes[0].attachments[0].data, package.notes[0].attachments[0].data)
    XCTAssertLessThan(abs(restored.notes[0].updatedAt.timeIntervalSince(package.notes[0].updatedAt)), 0.000_001)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.readSnapshot(at: second).notes[0].id, package.notes[0].id)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 2)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 2)
  }

  func testRejectsMissingDestinationWithoutCreatingSnapshot() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-note-snapshots-\(UUID().uuidString)", isDirectory: true)
    XCTAssertThrowsError(try KnowledgeNoteSnapshotBackupService.createSnapshot(
      RPNotePackage(notes: []), in: missing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testAutomaticBackupIsOptInAndSkipsUnchangedContentButKeepsChangedVersions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-auto-root-\(UUID().uuidString)")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("note-auto-icloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-tests-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = KnowledgeLibraryService(rootURL: root)
    let note = KnowledgeNote(title: "自动快照", createdAt: clock.value, updatedAt: clock.value, markdown: "原文")
    _ = try service.createNote(note)
    let providerCalls = SnapshotTestCounter()
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: {
        providerCalls.increment()
        return directory
      }
    )

    let disabledResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(disabledResult)
    XCTAssertEqual(providerCalls.value, 0)
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let first = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNotNil(first)

    clock.advance(by: 25 * 60 * 60)
    let unchangedResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(unchangedResult)
    var changed = note
    changed.markdown = "新版本"
    _ = try service.updateNote(changed)
    clock.advance(by: 25 * 60 * 60)
    let second = try await backup.createSnapshotIfDue(service: service)

    XCTAssertNotNil(second)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 2)
  }

  func testUnavailableICloudContainerRecordsFailureWithoutSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-auto-failure-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "note-snapshot-unavailable-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let service = KnowledgeLibraryService(rootURL: root)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      directoryProvider: { throw KnowledgeNoteSnapshotBackupService.SnapshotError.iCloudContainerUnavailable }
    )

    do {
      _ = try await backup.createSnapshotIfDue(service: service)
      XCTFail("Expected the unavailable container to be reported")
    } catch {
      XCTAssertEqual(error.localizedDescription, "iCloud 容器不可用。请检查 iCloud 登录状态与应用配置。")
    }
    XCTAssertEqual(preferences.double(forKey: "knowledgeNoteICloudSnapshotLastSuccessAt"), 0)
    XCTAssertFalse((preferences.string(forKey: "knowledgeNoteICloudSnapshotLastError") ?? "").isEmpty)
  }

  func testCorruptedSnapshotCannotBeRead() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("corrupt-\(UUID().uuidString).rpnotes", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try Data("not a valid note package".utf8).write(to: packageURL.appendingPathComponent("unexpected"))

    XCTAssertThrowsError(try KnowledgeNoteSnapshotBackupService.readSnapshot(at: packageURL))
  }
}

private final class SnapshotTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  var value: Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(interval)
    lock.unlock()
  }
}

private final class SnapshotTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
