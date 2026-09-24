import Foundation
import CryptoKit
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeNoteCloudSyncAdapterTests: XCTestCase {
  func testBootstrapGateAndRevisionAwareMarkSent() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "one"))

    let beforeBootstrap = try await adapter.localChanges()
    XCTAssertTrue(beforeBootstrap.isEmpty)
    try await adapter.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let first = try await adapter.localChanges()
    XCTAssertEqual(first.count, 1)
    let firstRevision = try XCTUnwrap(first.first?.revision)
    try await adapter.markSent(id: note.id, revision: firstRevision, systemFields: Data([1]))
    let afterSend = try await adapter.localChanges()
    XCTAssertTrue(afterSend.isEmpty)

    _ = try service.updateNote(KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "two"))
    let second = try await adapter.localChanges()
    XCTAssertEqual(second.count, 1)
    XCTAssertNotEqual(second.first?.revision, firstRevision)
    try await adapter.markSent(id: note.id, revision: firstRevision, systemFields: Data([2]))
    let afterStaleSend = try await adapter.localChanges()
    XCTAssertEqual(afterStaleSend.count, 1, "A stale sent revision must not clear newer work")
  }

  func testRecoveryReseedsSameContentAfterClearingOldBaseline() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Saved", markdown: "same"))
    try await adapter.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await adapter.localChanges()
    let original = try XCTUnwrap(initialChanges.first)
    try await adapter.markSent(id: note.id, revision: original.revision, systemFields: Data([9]))
    let afterSend = try await adapter.localChanges()
    XCTAssertTrue(afterSend.isEmpty)

    try await adapter.prepareZoneRecovery()
    try await adapter.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let replay = try await adapter.localChanges()
    XCTAssertEqual(replay.count, 1)
    XCTAssertEqual(replay.first?.id, note.id)
    if case let .upsert(_, _, fields) = replay[0] { XCTAssertNil(fields) }
    else { XCTFail("Recovery must requeue the current note") }
  }

  func testPreparedDeleteSurvivesAdapterRecreationAsTombstone() async throws {
    let (root, service, firstAdapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Delete", markdown: "body"))
    try await firstAdapter.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await firstAdapter.localChanges()
    let upsert = try XCTUnwrap(initialChanges.first)
    try await firstAdapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([3]))
    try await firstAdapter.prepareLocalDeletion(ids: [note.id])
    _ = try service.deleteDocument(id: note.id)

    let restarted = KnowledgeNoteCloudSyncAdapter(
      service: service,
      stateDirectoryURL: root.appendingPathComponent("sidecar")
    )
    try await restarted.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await restarted.localChanges()
    XCTAssertEqual(changes.count, 1)
    if case let .tombstone(id, _, _, fields) = changes[0] {
      XCTAssertEqual(id, note.id)
      XCTAssertEqual(fields, Data([3]))
    } else { XCTFail("Expected persisted tombstone") }
  }

  func testAccountChangeResetsChangeTagsAndRetainsLocalDeleteIntent() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try service.createNote(KnowledgeNote(title: "Live", markdown: "body"))
    let deleted = try service.createNote(KnowledgeNote(title: "Deleted", markdown: "old"))
    try await adapter.savePersistentState(.init(boundAccountID: "old-account", initialFetchComplete: true))
    let initial = try await adapter.localChanges()
    for change in initial {
      try await adapter.markSent(id: change.id, revision: change.revision, systemFields: Data([7]))
    }
    try await adapter.prepareLocalDeletion(ids: [deleted.id])
    _ = try service.deleteDocument(id: deleted.id)

    try await adapter.prepareAccountChange()
    try await adapter.savePersistentState(.init(boundAccountID: "new-account", initialFetchComplete: true))
    let reseeded = try await adapter.localChanges()
    XCTAssertEqual(Set(reseeded.map(\.id)), Set([live.id, deleted.id]))
    for change in reseeded {
      switch change {
      case let .upsert(_, _, fields): XCTAssertNil(fields)
      case let .tombstone(_, _, _, fields): XCTAssertNil(fields)
      }
    }
  }

  func testRemoteCollisionPreservesLocalContentAsConflictCopy() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let local = try service.createNote(KnowledgeNote(id: id, title: "本机", markdown: "本机正文"))
    let remote = RPNote(
      id: id,
      title: "云端",
      tags: [],
      createdAt: local.createdAt,
      updatedAt: local.updatedAt.addingTimeInterval(60),
      isArchived: false,
      sourceURL: nil,
      markdown: "云端正文",
      attachments: []
    )
    let digest = SHA256.hash(data: try RPNoteCloudPayload.encode(remote)).map { String(format: "%02x", $0) }.joined()

    let result = try await adapter.applyRemote(.note(remote, sha256: digest, systemFields: Data([1])))
    XCTAssertEqual(result, .keptLocalWithConflictCopy)
    XCTAssertEqual(try service.note(documentID: id)?.markdown, "云端正文")
    let notes = try service.notes()
    XCTAssertEqual(notes.count, 2)
    XCTAssertTrue(notes.contains(where: { $0.id != id && $0.markdown == "本机正文" }))
  }

  func testRemoteLiveRecordCannotErasePreparedLocalTombstone() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "To delete", markdown: "body"))
    try await adapter.savePersistentState(.init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await adapter.localChanges()
    let upsert = try XCTUnwrap(changes.first)
    try await adapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([1]))
    try await adapter.prepareLocalDeletion(ids: [note.id])
    _ = try service.deleteDocument(id: note.id)

    var staleRemote = RPNote(
      id: note.id,
      title: "To delete",
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      markdown: "body"
    )
    staleRemote.updatedAt = note.updatedAt
    let digest = SHA256.hash(data: try RPNoteCloudPayload.encode(staleRemote)).map { String(format: "%02x", $0) }.joined()
    let result = try await adapter.applyRemote(.note(staleRemote, sha256: digest, systemFields: Data([2])))
    XCTAssertEqual(result, .ignoredStale)
    XCTAssertNil(try service.note(documentID: note.id))
    let pending = try await adapter.localChanges()
    XCTAssertEqual(pending.count, 1)
    if case let .tombstone(id, _, _, fields) = pending[0] {
      XCTAssertEqual(id, note.id)
      XCTAssertEqual(fields, Data([2]))
    } else { XCTFail("Remote live note must leave the tombstone queued") }
  }

  func testRestartPrunesOnlyOwnedStagedAssetFiles() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = try await adapter.stageAsset(Data([1, 2, 3]))
    let stageDirectory = staged.deletingLastPathComponent()
    let unrelated = stageDirectory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: unrelated)

    let restarted = KnowledgeNoteCloudSyncAdapter(
      service: service,
      stateDirectoryURL: root.appendingPathComponent("sidecar")
    )
    _ = try await restarted.loadPersistentState()
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  private func makeAdapter() throws -> (URL, KnowledgeLibraryService, KnowledgeNoteCloudSyncAdapter) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-adapter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: libraryRoot)
    let adapter = KnowledgeNoteCloudSyncAdapter(
      service: service,
      stateDirectoryURL: root.appendingPathComponent("sidecar", isDirectory: true)
    )
    return (root, service, adapter)
  }
}
