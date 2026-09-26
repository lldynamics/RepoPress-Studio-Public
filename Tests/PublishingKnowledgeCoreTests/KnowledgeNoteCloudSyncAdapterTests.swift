import CryptoKit
import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeNoteCloudSyncAdapterTests: XCTestCase {
  func testBrokenSidecarSymlinkDoesNotBecomeFreshSyncState() async throws {
    let (root, _, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecarDirectory = root.appendingPathComponent("sidecar", isDirectory: true)
    try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
    let stateURL = sidecarDirectory.appendingPathComponent("adapter-state.json")
    try FileManager.default.createSymbolicLink(
      at: stateURL, withDestinationURL: root.appendingPathComponent("missing-state.json"))

    do {
      _ = try await adapter.loadPersistentState()
      XCTFail("An inaccessible existing sidecar must not be treated as a first sync")
    } catch let error as KnowledgeLibraryError {
      guard case .databaseIntegrity = error else {
        return XCTFail("Expected fail-closed state error, got \(error)")
      }
    }
    XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: stateURL.path))
  }

  func testAbandonedSendCannotAcknowledgeAndOldFailureCannotCancelNewSend() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let firstChanges = try await adapter.localChanges()
    let first = try XCTUnwrap(firstChanges.first)
    await adapter.prepareForSend(first)
    await adapter.abandonPreparedSend(id: note.id, revision: first.revision)
    try await adapter.markSent(id: note.id, revision: first.revision, systemFields: Data([1]))
    let afterAbandon = try await adapter.localChanges()
    guard case .upsert(_, let revision, let fields) = try XCTUnwrap(afterAbandon.first) else {
      return XCTFail("A failed send must remain pending")
    }
    XCTAssertEqual(revision, first.revision)
    XCTAssertNil(fields)

    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "B"))
    let secondChanges = try await adapter.localChanges()
    let second = try XCTUnwrap(secondChanges.first)
    await adapter.prepareForSend(second)
    await adapter.abandonPreparedSend(id: note.id, revision: first.revision)
    try await adapter.markSent(id: note.id, revision: second.revision, systemFields: Data([2]))
    let afterSuccess = try await adapter.localChanges()
    XCTAssertTrue(afterSuccess.isEmpty)
  }

  func testBootstrapGateAndRevisionAwareMarkSent() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "one"))

    let beforeBootstrap = try await adapter.localChanges()
    XCTAssertTrue(beforeBootstrap.isEmpty)
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let first = try await adapter.localChanges()
    XCTAssertEqual(first.count, 1)
    let firstRevision = try XCTUnwrap(first.first?.revision)
    await adapter.prepareForSend(first[0])
    try await adapter.markSent(id: note.id, revision: firstRevision, systemFields: Data([1]))
    let afterSend = try await adapter.localChanges()
    XCTAssertTrue(afterSend.isEmpty)

    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "two"))
    let second = try await adapter.localChanges()
    XCTAssertEqual(second.count, 1)
    XCTAssertNotEqual(second.first?.revision, firstRevision)
    try await adapter.markSent(id: note.id, revision: firstRevision, systemFields: Data([2]))
    let afterStaleSend = try await adapter.localChanges()
    XCTAssertEqual(afterStaleSend.count, 1, "A stale sent revision must not clear newer work")
  }

  func testMarkSentRetainsPendingRevisionWhenContentChangedBeforeRescan() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "one"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let first = try await adapter.localChanges()
    let firstRevision = try XCTUnwrap(first.first?.revision)
    await adapter.prepareForSend(first[0])

    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "two"))
    try await adapter.markSent(id: note.id, revision: firstRevision, systemFields: Data([2]))

    let stateData = try Data(contentsOf: root.appendingPathComponent("sidecar/adapter-state.json"))
    let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: stateData) as? [String: Any])
    let entries = try XCTUnwrap(state["entries"] as? [String: Any])
    let entry = try XCTUnwrap(entries[note.id.uuidString.lowercased()] as? [String: Any])
    XCTAssertNotEqual(entry["pendingRevision"] as? String, firstRevision)
    XCTAssertEqual(entry["baselineRevision"] as? String, firstRevision)
    XCTAssertNotEqual(entry["currentRevision"] as? String, firstRevision)
    let afterRescan = try await adapter.localChanges()
    XCTAssertEqual(afterRescan.count, 1)
    XCTAssertNotEqual(afterRescan.first?.revision, firstRevision)
  }

  func testDelayedAckAfterRescanKeepsNewPendingRevisionAndBaselineFields() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let firstChanges = try await adapter.localChanges()
    let a = try XCTUnwrap(firstChanges.first?.revision)
    let sentA: RPNote
    if case .upsert(let value, _, _) = firstChanges[0] {
      sentA = value
    } else {
      return XCTFail("Expected initial upsert")
    }
    await adapter.prepareForSend(firstChanges[0])
    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "B"))
    let secondChanges = try await adapter.localChanges()
    let b = try XCTUnwrap(secondChanges.first?.revision)

    try await adapter.markSent(id: note.id, revision: a, systemFields: Data([10]))
    let queuedChanges = try await adapter.localChanges()
    let queued = try XCTUnwrap(queuedChanges.first)
    XCTAssertEqual(queued.revision, b)
    if case .upsert(_, _, let fields) = queued {
      XCTAssertEqual(fields, Data([10]))
    } else {
      XCTFail("Expected pending B upsert")
    }
    let digest = try noteRevision(sentA)
    let remoteResult = try await adapter.applyRemote(
      .note(sentA, sha256: digest, systemFields: Data([10])))
    XCTAssertEqual(remoteResult, .ignoredStale)
    XCTAssertEqual(try service.notes().count, 1)
  }

  func testAckWithoutRescanThenRemoteEchoDoesNotCreateConflictCopy() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let first = try await adapter.localChanges()
    let sentA = try XCTUnwrap(first.first)
    guard case .upsert(let remoteA, _, _) = sentA else { return XCTFail("Expected upsert") }
    await adapter.prepareForSend(sentA)
    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "B"))
    try await adapter.markSent(id: note.id, revision: sentA.revision, systemFields: Data([11]))

    let result = try await adapter.applyRemote(
      .note(remoteA, sha256: noteRevision(remoteA), systemFields: Data([11])))
    XCTAssertEqual(result, .ignoredStale)
    XCTAssertEqual(try service.notes().count, 1)
    XCTAssertEqual(try service.note(documentID: note.id)?.markdown, "B")
  }

  func testLateAckAfterConfirmedBAndNewCDoesNotRollFieldsBack() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let aChanges = try await adapter.localChanges()
    let a = try XCTUnwrap(aChanges.first)
    await adapter.prepareForSend(a)
    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "B"))
    let bChanges = try await adapter.localChanges()
    let b = try XCTUnwrap(bChanges.first)
    await adapter.prepareForSend(b)
    try await adapter.markSent(id: note.id, revision: b.revision, systemFields: Data([12]))
    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "C"))
    let cChanges = try await adapter.localChanges()
    XCTAssertEqual(cChanges.count, 1)
    try await adapter.markSent(id: note.id, revision: a.revision, systemFields: Data([10]))
    let queued = try await adapter.localChanges()
    XCTAssertEqual(queued.count, 1)
    XCTAssertEqual(queued.first?.revision, cChanges.first?.revision)
    if case .upsert(_, _, let fields) = try XCTUnwrap(queued.first) {
      XCTAssertEqual(fields, Data([12]))
    } else {
      XCTFail("Expected C upsert")
    }
  }

  func testAckAfterDirectDeleteRequeuesTombstone() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Delete", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initial = try await adapter.localChanges()
    let sentA = try XCTUnwrap(initial.first)
    await adapter.prepareForSend(sentA)
    _ = try service.deleteDocument(id: note.id)
    _ = try await adapter.localChanges()
    try await adapter.markSent(id: note.id, revision: sentA.revision, systemFields: Data([13]))
    let queued = try await adapter.localChanges()
    guard case .tombstone(_, _, _, let fields) = try XCTUnwrap(queued.first) else {
      return XCTFail("Expected tombstone")
    }
    XCTAssertEqual(fields, Data([13]))
  }

  func testTombstoneAckAfterLocalRestoreKeepsNotePending() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let note = try service.createNote(KnowledgeNote(id: id, title: "Delete", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    _ = try await adapter.localChanges()
    try await adapter.prepareLocalDeletion(ids: [id])
    _ = try service.deleteDocument(id: id)
    let tombstones = try await adapter.localChanges()
    let tombstone = try XCTUnwrap(tombstones.first)
    await adapter.prepareForSend(tombstone)
    _ = try service.createNote(KnowledgeNote(id: id, title: note.title, markdown: "restored"))
    try await adapter.markSent(id: id, revision: tombstone.revision, systemFields: Data([14]))
    let pending = try await adapter.localChanges()
    guard case .upsert(let restored, _, let fields) = try XCTUnwrap(pending.first) else {
      return XCTFail("Expected restored note upsert")
    }
    XCTAssertEqual(restored.markdown, "restored")
    XCTAssertEqual(fields, Data([14]))
  }

  func testOlderServerEchoCannotRollBaselineBackAfterNewerAck() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Local", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let firstChanges = try await adapter.localChanges()
    let a = try XCTUnwrap(firstChanges.first?.revision)
    await adapter.prepareForSend(firstChanges[0])
    _ = try service.updateNote(
      KnowledgeNote(id: note.id, title: "Local", createdAt: note.createdAt, markdown: "B"))
    let secondChanges = try await adapter.localChanges()
    let b = try XCTUnwrap(secondChanges.first?.revision)
    await adapter.prepareForSend(secondChanges[0])
    try await adapter.markSent(id: note.id, revision: b, systemFields: Data([20]))
    try await adapter.markSent(id: note.id, revision: a, systemFields: Data([10]))

    let remaining = try await adapter.localChanges()
    XCTAssertTrue(remaining.isEmpty)
    let stateData = try Data(contentsOf: root.appendingPathComponent("sidecar/adapter-state.json"))
    let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: stateData) as? [String: Any])
    let entries = try XCTUnwrap(state["entries"] as? [String: Any])
    let entry = try XCTUnwrap(entries[note.id.uuidString.lowercased()] as? [String: Any])
    XCTAssertEqual(entry["baselineRevision"] as? String, b)
    XCTAssertEqual(entry["systemFields"] as? String, Data([20]).base64EncodedString())
  }

  func testDelayedUpsertAckPreservesPreparedDeletion() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Delete", markdown: "A"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let firstChanges = try await adapter.localChanges()
    let a = try XCTUnwrap(firstChanges.first?.revision)
    await adapter.prepareForSend(firstChanges[0])
    try await adapter.prepareLocalDeletion(ids: [note.id])
    _ = try service.deleteDocument(id: note.id)
    let deletionChanges = try await adapter.localChanges()
    let deletion = try XCTUnwrap(deletionChanges.first)
    guard case .tombstone(_, _, let tombstoneRevision, _) = deletion else {
      return XCTFail("Expected tombstone")
    }
    await adapter.prepareForSend(firstChanges[0])

    try await adapter.markSent(id: note.id, revision: a, systemFields: Data([30]))
    let queuedChanges = try await adapter.localChanges()
    let queued = try XCTUnwrap(queuedChanges.first)
    guard case .tombstone(_, _, let queuedRevision, let fields) = queued else {
      return XCTFail("Expected deletion to remain queued")
    }
    XCTAssertEqual(queuedRevision, tombstoneRevision)
    XCTAssertEqual(fields, Data([30]))
  }

  func testRecoveryReseedsSameContentAfterClearingOldBaseline() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Saved", markdown: "same"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await adapter.localChanges()
    let original = try XCTUnwrap(initialChanges.first)
    await adapter.prepareForSend(original)
    try await adapter.markSent(id: note.id, revision: original.revision, systemFields: Data([9]))
    let afterSend = try await adapter.localChanges()
    XCTAssertTrue(afterSend.isEmpty)

    try await adapter.prepareZoneRecovery()
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let replay = try await adapter.localChanges()
    XCTAssertEqual(replay.count, 1)
    XCTAssertEqual(replay.first?.id, note.id)
    if case .upsert(_, _, let fields) = replay[0] {
      XCTAssertNil(fields)
    } else {
      XCTFail("Recovery must requeue the current note")
    }
  }

  func testPreparedDeleteSurvivesAdapterRecreationAsTombstone() async throws {
    let (root, service, firstAdapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Delete", markdown: "body"))
    try await firstAdapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await firstAdapter.localChanges()
    let upsert = try XCTUnwrap(initialChanges.first)
    await firstAdapter.prepareForSend(upsert)
    try await firstAdapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([3]))
    try await firstAdapter.prepareLocalDeletion(ids: [note.id])
    _ = try service.deleteDocument(id: note.id)

    let restarted = KnowledgeNoteCloudSyncAdapter(
      service: service,
      stateDirectoryURL: root.appendingPathComponent("sidecar")
    )
    try await restarted.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await restarted.localChanges()
    XCTAssertEqual(changes.count, 1)
    if case .tombstone(let id, _, _, let fields) = changes[0] {
      XCTAssertEqual(id, note.id)
      XCTAssertEqual(fields, Data([3]))
    } else {
      XCTFail("Expected persisted tombstone")
    }
  }

  func testAccountChangeResetsChangeTagsAndRetainsLocalDeleteIntent() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try service.createNote(KnowledgeNote(title: "Live", markdown: "body"))
    let deleted = try service.createNote(KnowledgeNote(title: "Deleted", markdown: "old"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "old-account", initialFetchComplete: true))
    let initial = try await adapter.localChanges()
    for change in initial {
      await adapter.prepareForSend(change)
      try await adapter.markSent(id: change.id, revision: change.revision, systemFields: Data([7]))
    }
    try await adapter.prepareLocalDeletion(ids: [deleted.id])
    _ = try service.deleteDocument(id: deleted.id)

    try await adapter.prepareAccountChange()
    try await adapter.savePersistentState(
      .init(boundAccountID: "new-account", initialFetchComplete: true))
    let reseeded = try await adapter.localChanges()
    XCTAssertEqual(Set(reseeded.map(\.id)), Set([live.id, deleted.id]))
    for change in reseeded {
      switch change {
      case .upsert(_, _, let fields): XCTAssertNil(fields)
      case .tombstone(_, _, _, let fields): XCTAssertNil(fields)
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
    let digest = SHA256.hash(data: try RPNoteCloudPayload.encode(remote)).map {
      String(format: "%02x", $0)
    }.joined()

    let result = try await adapter.applyRemote(
      .note(remote, sha256: digest, systemFields: Data([1])))
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
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await adapter.localChanges()
    let upsert = try XCTUnwrap(changes.first)
    await adapter.prepareForSend(upsert)
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
    let digest = SHA256.hash(data: try RPNoteCloudPayload.encode(staleRemote)).map {
      String(format: "%02x", $0)
    }.joined()
    let result = try await adapter.applyRemote(
      .note(staleRemote, sha256: digest, systemFields: Data([2])))
    XCTAssertEqual(result, .ignoredStale)
    XCTAssertNil(try service.note(documentID: note.id))
    let pending = try await adapter.localChanges()
    XCTAssertEqual(pending.count, 1)
    if case .tombstone(let id, _, _, let fields) = pending[0] {
      XCTAssertEqual(id, note.id)
      XCTAssertEqual(fields, Data([2]))
    } else {
      XCTFail("Remote live note must leave the tombstone queued")
    }
  }

  func testRemoteTombstonePreservesDirtyLocalContentAsConflictCopy() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let local = try service.createNote(KnowledgeNote(id: id, title: "Local", markdown: "unsynced"))
    let result = try await adapter.applyRemote(
      .tombstone(
        id: id,
        deletedAt: local.updatedAt.addingTimeInterval(60),
        systemFields: Data([4])
      ))

    XCTAssertEqual(result, .keptLocalWithConflictCopy)
    XCTAssertNil(try service.note(documentID: id))
    let notes = try service.notes()
    XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(notes.first?.markdown, "unsynced")
  }

  func testDuplicateRemoteNoteDoesNotOverwriteSubsequentLocalEdit() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let remote = RPNote(id: id, title: "Remote", markdown: "server")
    let revision = try noteRevision(remote)
    let change = RPNoteCloudRemoteChange.note(remote, sha256: revision, systemFields: Data([5]))

    let initialResult = try await adapter.applyRemote(change)
    XCTAssertEqual(initialResult, .applied)
    let imported = try XCTUnwrap(try service.note(documentID: id))
    _ = try service.updateNote(
      KnowledgeNote(
        id: id,
        title: imported.title,
        tags: imported.tags,
        createdAt: imported.createdAt,
        isArchived: imported.isArchived,
        sourceURL: imported.sourceURL,
        markdown: "edited after fetch",
        attachments: imported.attachments
      ))

    let replayResult = try await adapter.applyRemote(change)
    XCTAssertEqual(replayResult, .ignoredStale)
    XCTAssertEqual(try service.note(documentID: id)?.markdown, "edited after fetch")
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await adapter.localChanges()
    XCTAssertEqual(changes.count, 1)
    XCTAssertNotEqual(changes.first?.revision, revision)
  }

  func testDuplicateRemoteTombstoneDoesNotDeleteSubsequentLocalEdit() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let change = RPNoteCloudRemoteChange.tombstone(
      id: id, deletedAt: deletedAt, systemFields: Data([6]))

    let initialResult = try await adapter.applyRemote(change)
    XCTAssertEqual(initialResult, .applied)
    _ = try service.createNote(
      KnowledgeNote(id: id, title: "Restored", markdown: "new local content"))
    let replayResult = try await adapter.applyRemote(change)
    XCTAssertEqual(replayResult, .ignoredStale)
    XCTAssertEqual(try service.note(documentID: id)?.markdown, "new local content")
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let changes = try await adapter.localChanges()
    XCTAssertEqual(changes.count, 1)
    XCTAssertEqual(changes.first?.id, id)
  }

  func testRemoteTombstoneCompletesPreparedLocalDeletionWithoutConflictCopy() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Delete", markdown: "body"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await adapter.localChanges()
    let upsert = try XCTUnwrap(initialChanges.first)
    await adapter.prepareForSend(upsert)
    try await adapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([7]))
    try await adapter.prepareLocalDeletion(ids: [note.id])
    _ = try service.deleteDocument(id: note.id)

    let remoteResult = try await adapter.applyRemote(
      .tombstone(
        id: note.id,
        deletedAt: Date(timeIntervalSince1970: 1_700_000_001),
        systemFields: Data([8])
      ))
    XCTAssertEqual(remoteResult, .applied)
    XCTAssertNil(try service.note(documentID: note.id))
    XCTAssertTrue(try service.notes().isEmpty)
    let remainingChanges = try await adapter.localChanges()
    XCTAssertTrue(remainingChanges.isEmpty)
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

  func testRemoteTombstoneKeepsRecycledNoteWithoutCreatingActiveConflictCopy() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Recycle", markdown: "recoverable body"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await adapter.localChanges()
    let upsert = try XCTUnwrap(initialChanges.first)
    await adapter.prepareForSend(upsert)
    try await adapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([1]))
    try await adapter.prepareLocalDeletion(ids: [note.id])
    try await service.moveToRecycleBinAsync(documentIDs: [note.id])

    let result = try await adapter.applyRemote(
      .tombstone(id: note.id, deletedAt: Date(), systemFields: Data([2])))

    XCTAssertEqual(result, .applied)
    XCTAssertTrue(try service.notes().isEmpty, "A shared deletion must not create a live copy")
    XCTAssertEqual(try service.document(id: note.id)?.isArchived, true)
    XCTAssertEqual(try service.note(documentID: note.id)?.markdown, "recoverable body")
    let pending = try await adapter.localChanges()
    XCTAssertTrue(pending.isEmpty)

    try await service.restoreFromRecycleBinAsync(documentIDs: [note.id])
    let restored = try await adapter.localChanges()
    XCTAssertEqual(restored.count, 1)
    guard case .upsert(let restoredNote, _, _) = try XCTUnwrap(restored.first) else {
      return XCTFail("An explicit restore must become a new upsert")
    }
    XCTAssertEqual(restoredNote.id, note.id)
  }

  func testDeletionAcknowledgementDoesNotRequeueRecycledNote() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Recycle", markdown: "body"))
    try await adapter.savePersistentState(
      .init(boundAccountID: "account", initialFetchComplete: true))
    let initialChanges = try await adapter.localChanges()
    let upsert = try XCTUnwrap(initialChanges.first)
    await adapter.prepareForSend(upsert)
    try await adapter.markSent(id: note.id, revision: upsert.revision, systemFields: Data([1]))
    try await adapter.prepareLocalDeletion(ids: [note.id])
    try await service.moveToRecycleBinAsync(documentIDs: [note.id])
    let deletionChanges = try await adapter.localChanges()
    let deletion = try XCTUnwrap(deletionChanges.first)
    await adapter.prepareForSend(deletion)
    try await adapter.markSent(id: note.id, revision: deletion.revision, systemFields: Data([2]))

    XCTAssertEqual(try service.document(id: note.id)?.isArchived, true)
    let stateData = try Data(contentsOf: root.appendingPathComponent("sidecar/adapter-state.json"))
    let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: stateData) as? [String: Any])
    let entries = try XCTUnwrap(state["entries"] as? [String: Any])
    let entry = try XCTUnwrap(entries[note.id.uuidString.lowercased()] as? [String: Any])
    XCTAssertNil(entry["pendingKind"], "A recycled row is not a restored live note")
    let pending = try await adapter.localChanges()
    XCTAssertTrue(pending.isEmpty)
  }

  func testRemoteTombstoneWaitsUntilLocalRecycleMoveCommits() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Moving", markdown: "recoverable"))
    let prepared = expectation(description: "Deletion intent prepared")
    let permit = DeletionCommitPermit()
    let deletion = Task {
      try await adapter.performLocalDeletion(ids: [note.id]) {
        prepared.fulfill()
        await permit.wait()
        try await service.moveToRecycleBinAsync(documentIDs: [note.id])
      }
    }
    await fulfillment(of: [prepared], timeout: 2)
    let remote = Task {
      try await adapter.applyRemote(
        .tombstone(id: note.id, deletedAt: Date(), systemFields: Data([2])))
    }
    try await Task.sleep(for: .milliseconds(50))
    await permit.release()
    try await deletion.value
    let result = try await remote.value
    XCTAssertEqual(result, .applied)
    XCTAssertTrue(try service.notes().isEmpty)
    XCTAssertEqual(try service.document(id: note.id)?.isArchived, true)
    XCTAssertEqual(try service.note(documentID: note.id)?.markdown, "recoverable")
  }

  func testRemoteTombstonePreservesActiveNoteWhenPreparedDeletionDidNotCommit() async throws {
    let (root, service, adapter) = try makeAdapter()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = try service.createNote(KnowledgeNote(title: "Keep", markdown: "unremoved body"))
    do {
      try await adapter.performLocalDeletion(ids: [note.id]) {
        throw CocoaError(.fileWriteNoPermission)
      }
      XCTFail("Deletion fixture must fail before the library commits")
    } catch {
      XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
    }

    let result = try await adapter.applyRemote(
      .tombstone(id: note.id, deletedAt: Date(), systemFields: Data([2])))

    XCTAssertEqual(result, .keptLocalWithConflictCopy)
    let notes = try service.notes()
    XCTAssertEqual(notes.count, 1)
    XCTAssertNotEqual(notes.first?.id, note.id)
    XCTAssertEqual(notes.first?.markdown, "unremoved body")
  }

  private func makeAdapter() throws -> (URL, KnowledgeLibraryService, KnowledgeNoteCloudSyncAdapter)
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloud-adapter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: libraryRoot)
    let adapter = KnowledgeNoteCloudSyncAdapter(
      service: service,
      stateDirectoryURL: root.appendingPathComponent("sidecar", isDirectory: true)
    )
    return (root, service, adapter)
  }

  private func noteRevision(_ note: RPNote) throws -> String {
    SHA256.hash(data: try RPNoteCloudPayload.encode(note)).map { String(format: "%02x", $0) }
      .joined()
  }
}

private actor DeletionCommitPermit {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
