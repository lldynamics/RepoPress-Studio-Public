import Foundation
import XCTest
import os

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
      attachments: [
        RPNoteAttachment(
          fileName: "附件.bin", mimeType: "application/octet-stream", data: Data([0, 1, 2]))
      ]
    )
    let package = RPNotePackage(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), notes: [note])
    let timestamp = Date(timeIntervalSince1970: 1_700_000_100)

    let first = try KnowledgeNoteSnapshotBackupService.createSnapshot(
      package, in: directory, timestamp: timestamp)
    let second = try KnowledgeNoteSnapshotBackupService.createSnapshot(
      package, in: directory, timestamp: timestamp)

    XCTAssertNotEqual(first, second)
    XCTAssertTrue(first.lastPathComponent.hasPrefix("RepoPress-Notes-"))
    let restored = try KnowledgeNoteSnapshotBackupService.readSnapshot(at: first)
    XCTAssertEqual(restored.notes.map(\.id), package.notes.map(\.id))
    XCTAssertEqual(restored.notes[0].markdown, package.notes[0].markdown)
    XCTAssertEqual(restored.notes[0].attachments[0].data, package.notes[0].attachments[0].data)
    XCTAssertLessThan(
      abs(restored.notes[0].updatedAt.timeIntervalSince(package.notes[0].updatedAt)), 0.000_001)
    XCTAssertEqual(
      try KnowledgeNoteSnapshotBackupService.readSnapshot(at: second).notes[0].id,
      package.notes[0].id)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .count, 2)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 2)
  }

  func testRejectsMissingDestinationWithoutCreatingSnapshot() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-note-snapshots-\(UUID().uuidString)", isDirectory: true)
    XCTAssertThrowsError(
      try KnowledgeNoteSnapshotBackupService.createSnapshot(
        RPNotePackage(notes: []), in: missing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testAutomaticBackupIsOptInAndSkipsUnchangedContentButKeepsChangedVersions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-auto-root-\(UUID().uuidString)")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-auto-icloud-\(UUID().uuidString)")
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
    let note = KnowledgeNote(
      title: "自动快照", createdAt: clock.value, updatedAt: clock.value, markdown: "原文")
    _ = try service.createNote(note)
    let providerCalls = SnapshotTestCounter()
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: {
        providerCalls.increment()
        return directory
      },
      uploadStatusReader: { _ in .uploaded }
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

  func testAutomaticBackupRebuildsDeletedSnapshotAfterRetryInterval() async throws {
    let root = temporaryDirectory(named: "note-auto-deleted-root")
    let directory = temporaryDirectory(named: "note-auto-deleted-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-deleted-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      uploadStatusReader: { _ in .uploaded }
    )

    let firstResult = try await backup.createSnapshotIfDue(service: service)
    let first = try XCTUnwrap(firstResult)
    try FileManager.default.removeItem(at: first)
    clock.advance(by: 25 * 60 * 60)

    let replacementResult = try await backup.createSnapshotIfDue(service: service)
    let replacement = try XCTUnwrap(replacementResult)
    XCTAssertNotEqual(replacement, first)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 1)
  }

  func testAutomaticBackupRebuildsActuallyCorruptedSnapshot() async throws {
    let root = temporaryDirectory(named: "note-auto-corrupt-root")
    let directory = temporaryDirectory(named: "note-auto-corrupt-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-corrupt-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      uploadStatusReader: { _ in .uploaded }
    )

    let firstResult = try await backup.createSnapshotIfDue(service: service)
    let first = try XCTUnwrap(firstResult)
    try Data("unexpected".utf8).write(to: first.appendingPathComponent("tampered"))
    clock.advance(by: 25 * 60 * 60)

    let replacementResult = try await backup.createSnapshotIfDue(service: service)
    let replacement = try XCTUnwrap(replacementResult)
    XCTAssertNotEqual(replacement, first)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 2)
  }

  func testAutomaticBackupRebuildsSnapshotWithMismatchedDecodedContent() async throws {
    let root = temporaryDirectory(named: "note-auto-mismatch-root")
    let directory = temporaryDirectory(named: "note-auto-mismatch-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-mismatch-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      uploadStatusReader: { _ in .uploaded }
    )

    let firstResult = try await backup.createSnapshotIfDue(service: service)
    let first = try XCTUnwrap(firstResult)
    var mismatched = try KnowledgeNoteSnapshotBackupService.readSnapshot(at: first)
    mismatched.notes[0].markdown = "changed outside the note library"
    try FileManager.default.removeItem(at: first)
    try RPNotesPackageCodec.encode(mismatched).write(
      to: first, options: .atomic, originalContentsURL: nil)
    clock.advance(by: 25 * 60 * 60)

    let rebuilt = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNotNil(rebuilt)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 2)
  }

  func testAutomaticBackupRebuildsWhenTheCurrentBackupDirectoryChanges() async throws {
    let root = temporaryDirectory(named: "note-auto-target-root")
    let firstDirectory = temporaryDirectory(named: "note-auto-target-first")
    let secondDirectory = temporaryDirectory(named: "note-auto-target-second")
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: firstDirectory)
      try? FileManager.default.removeItem(at: secondDirectory)
    }
    let suite = "note-snapshot-target-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let currentDirectory = SnapshotTestDirectory(firstDirectory)
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { currentDirectory.value },
      uploadStatusReader: { _ in .uploaded }
    )

    let first = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNotNil(first)
    currentDirectory.set(secondDirectory)
    clock.advance(by: KnowledgeNoteAutomaticSnapshotBackup.retryInterval)

    let replacementResult = try await backup.createSnapshotIfDue(service: service)
    let replacement = try XCTUnwrap(replacementResult)
    XCTAssertEqual(replacement.deletingLastPathComponent(), secondDirectory)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: firstDirectory).count, 1)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: secondDirectory).count, 1)
  }

  func testAutomaticBackupReusesMatchingUploadedSnapshot() async throws {
    let root = temporaryDirectory(named: "note-auto-reuse-root")
    let directory = temporaryDirectory(named: "note-auto-reuse-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-reuse-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      uploadStatusReader: { _ in .uploaded }
    )

    let first = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNotNil(first)
    clock.advance(by: 25 * 60 * 60)

    let reuseResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(reuseResult)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 1)
  }

  func testUnknownSnapshotReadPreservesSuccessfulMetadataAndDoesNotCopy() async throws {
    let root = temporaryDirectory(named: "note-auto-unknown-root")
    let directory = temporaryDirectory(named: "note-auto-unknown-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-unknown-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let reader = SnapshotTestReader(.unknown)
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      snapshotReader: { _ in reader.value },
      uploadStatusReader: { _ in .uploaded }
    )

    let firstResult = try await backup.createSnapshotIfDue(service: service)
    let first = try XCTUnwrap(firstResult)
    let successAt = preferences.double(forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
    let signature = preferences.string(forKey: "knowledgeNoteICloudSnapshotContentHash")
    let status = preferences.string(forKey: "knowledgeNoteICloudSnapshotUploadStatus")
    clock.advance(by: 25 * 60 * 60)

    let unknownResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(unknownResult)
    XCTAssertEqual(
      preferences.double(forKey: "knowledgeNoteICloudSnapshotLastSuccessAt"), successAt)
    XCTAssertEqual(preferences.string(forKey: "knowledgeNoteICloudSnapshotLastURL"), first.path)
    XCTAssertEqual(preferences.string(forKey: "knowledgeNoteICloudSnapshotContentHash"), signature)
    XCTAssertEqual(preferences.string(forKey: "knowledgeNoteICloudSnapshotUploadStatus"), status)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 1)
  }

  func testPendingUploadDoesNotCreateRepeatedSnapshots() async throws {
    let root = temporaryDirectory(named: "note-auto-pending-root")
    let directory = temporaryDirectory(named: "note-auto-pending-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-pending-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      uploadStatusReader: { _ in .waitingForUpload }
    )

    let first = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNotNil(first)
    let notes = try await service.notesAsync()
    var changed = try XCTUnwrap(notes.first)
    changed.markdown = "a newer note must wait for the first upload"
    _ = try service.updateNote(changed)
    clock.advance(by: 25 * 60 * 60)
    let pendingResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(pendingResult)
    clock.advance(by: KnowledgeNoteAutomaticSnapshotBackup.retryInterval)
    let retryResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(retryResult)
    XCTAssertEqual(try KnowledgeNoteSnapshotBackupService.snapshots(in: directory).count, 1)
  }

  func testUnknownPreflightHonorsRetryIntervalAtFourteenFiftyNineAndFifteenMinutes() async throws {
    let root = temporaryDirectory(named: "note-auto-unknown-retry-root")
    let directory = temporaryDirectory(named: "note-auto-unknown-retry-icloud")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: directory)
    }
    let suite = "note-snapshot-unknown-retry-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let clock = SnapshotTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let service = try makeSnapshotService(root: root, date: clock.value)
    let reader = SnapshotTestReader(.unknown)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { clock.value },
      directoryProvider: { directory },
      snapshotReader: { _ in reader.value },
      uploadStatusReader: { _ in .uploaded }
    )

    let firstResult = try await backup.createSnapshotIfDue(service: service)
    let first = try XCTUnwrap(firstResult)
    try FileManager.default.removeItem(at: first)
    clock.advance(by: 24 * 60 * 60)
    let firstUnknownResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(firstUnknownResult)
    let attemptAt = preferences.double(forKey: "knowledgeNoteICloudSnapshotLastAttemptAt")
    clock.advance(by: KnowledgeNoteAutomaticSnapshotBackup.retryInterval - 1)
    let throttledResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(throttledResult)
    XCTAssertEqual(
      preferences.double(forKey: "knowledgeNoteICloudSnapshotLastAttemptAt"), attemptAt)
    clock.advance(by: 1)
    let retriedResult = try await backup.createSnapshotIfDue(service: service)
    XCTAssertNil(retriedResult)
    XCTAssertGreaterThan(
      preferences.double(forKey: "knowledgeNoteICloudSnapshotLastAttemptAt"), attemptAt)
  }

  func testUploadStatusFailsClosedWhenDirectoryEnumerationFails() throws {
    let packageURL = temporaryDirectory(named: "note-upload-enumeration-failure")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let incompleteURLs = KnowledgeNoteSnapshotBackupService.packageURLs(
      at: packageURL,
      enumerateContents: { url, handler in
        _ = handler(url, CocoaError(.fileReadNoPermission))
        return FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: nil, options: [])
      })
    XCTAssertNil(incompleteURLs)
    XCTAssertNil(
      KnowledgeNoteSnapshotBackupService.packageURLs(
        at: packageURL, enumerateContents: { _, _ in nil }))
    XCTAssertEqual(KnowledgeNoteSnapshotBackupService.uploadStatus(at: packageURL), .unavailable)
  }

  func testUnavailableICloudContainerRecordsFailureWithoutSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-auto-failure-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "note-snapshot-unavailable-\(UUID().uuidString)"
    let preferences = KnowledgeNoteSnapshotPreferences(suiteName: suite)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "knowledgeNoteICloudAutoBackupEnabled")
    let service = KnowledgeLibraryService(rootURL: root)
    let backup = KnowledgeNoteAutomaticSnapshotBackup(
      preferences: preferences,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      directoryProvider: {
        throw KnowledgeNoteSnapshotBackupService.SnapshotError.iCloudContainerUnavailable
      }
    )

    do {
      _ = try await backup.createSnapshotIfDue(service: service)
      XCTFail("Expected the unavailable container to be reported")
    } catch {
      XCTAssertEqual(error.localizedDescription, "iCloud 容器不可用。请检查 iCloud 登录状态与应用配置。")
    }
    XCTAssertEqual(preferences.double(forKey: "knowledgeNoteICloudSnapshotLastSuccessAt"), 0)
    XCTAssertFalse(
      (preferences.string(forKey: "knowledgeNoteICloudSnapshotLastError") ?? "").isEmpty)
  }

  func testCorruptedSnapshotCannotBeRead() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("corrupt-\(UUID().uuidString).rpnotes", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try Data("not a valid note package".utf8).write(
      to: packageURL.appendingPathComponent("unexpected"))

    XCTAssertThrowsError(try KnowledgeNoteSnapshotBackupService.readSnapshot(at: packageURL))
  }

  func testSnapshotReadResultTreatsTemporaryAttributesFailureAsUnknown() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("unreadable-\(UUID().uuidString).rpnotes", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let result = KnowledgeNoteSnapshotBackupService.snapshotReadResult(
      at: packageURL,
      fileManager: SnapshotUnreadableFileManager()
    )
    guard case .unknown = result else {
      return XCTFail("A temporary attribute read failure must remain unknown")
    }
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeSnapshotService(root: URL, date: Date) throws -> KnowledgeLibraryService {
    let service = KnowledgeLibraryService(rootURL: root)
    _ = try service.createNote(
      KnowledgeNote(title: "自动快照", createdAt: date, updatedAt: date, markdown: "原文"))
    return service
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

private final class SnapshotTestDirectory: Sendable {
  private let storedDirectory: OSAllocatedUnfairLock<URL>

  init(_ directory: URL) {
    storedDirectory = OSAllocatedUnfairLock(uncheckedState: directory)
  }

  var value: URL {
    storedDirectory.withLock { $0 }
  }

  func set(_ directory: URL) {
    storedDirectory.withLock { $0 = directory }
  }
}

private final class SnapshotTestReader: Sendable {
  private let result: KnowledgeNoteSnapshotReadResult

  init(_ result: KnowledgeNoteSnapshotReadResult) { self.result = result }

  var value: KnowledgeNoteSnapshotReadResult { result }
}

private final class SnapshotUnreadableFileManager: FileManager {
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    throw CocoaError(.fileReadNoPermission)
  }
}
