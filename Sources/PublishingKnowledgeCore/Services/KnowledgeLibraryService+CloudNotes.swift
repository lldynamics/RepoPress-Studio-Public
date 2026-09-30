import Foundation

struct KnowledgeCloudNoteMutationResult: Sendable {
  let preservedConflictCopy: Bool
  let hadLocalNote: Bool
}

extension KnowledgeLibraryService {
  /// All local writers use this lock. Read the current note and preserve it before
  /// applying a remote value; no suspension can admit an unprotected local edit.
  func applyCloudNoteMutation(
    id: UUID,
    replacement: KnowledgeNote?,
    remoteRevision: String,
    baselineRevision: String?,
    hasPendingLocalChange: Bool
  ) throws -> KnowledgeCloudNoteMutationResult {
    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    let document = try document(id: id)
    if let document, document.kind != .note {
      throw KnowledgeLibraryError.invalidMetadata("相同标识已被非笔记资料使用。")
    }
    let local = document?.isArchived == false ? try note(documentID: id) : nil
    let portable = local.map(KnowledgeNoteCloudSyncAdapter.portableNote)
    let localRevision = try portable.map(KnowledgeNoteCloudSyncAdapter.revision)
    let preserveLocal =
      local != nil && localRevision != remoteRevision
      && (hasPendingLocalChange || baselineRevision == nil || localRevision != baselineRevision)
    var writes: [KnowledgeNote] = []
    if preserveLocal, var copy = portable, let localRevision {
      let copyID = KnowledgeNoteCloudSyncAdapter.deterministicUUID(
        namespace: id, name: "\(localRevision):\(remoteRevision)")
      copy.id = copyID
      copy.attachments = copy.attachments.map { attachment in
        var copy = attachment
        copy.id = KnowledgeNoteCloudSyncAdapter.deterministicUUID(
          namespace: copyID, name: attachment.id.uuidString.lowercased())
        return copy
      }
      if let existingDocument = try self.document(id: copyID) {
        guard existingDocument.kind == .note, let existing = try note(documentID: copyID),
          try KnowledgeNoteCloudSyncAdapter.revision(
            for: KnowledgeNoteCloudSyncAdapter.portableNote(existing))
            == KnowledgeNoteCloudSyncAdapter.revision(for: copy)
        else {
          throw KnowledgeLibraryError.databaseIntegrity("iCloud 冲突副本标识已被占用，已停止覆盖。")
        }
      } else {
        writes.append(KnowledgeNoteCloudSyncAdapter.knowledgeNote(copy))
      }
    }
    if let replacement, localRevision != remoteRevision { writes.append(replacement) }
    // Copy and live replacement share one database commit. For tombstones the
    // copy commits first; a failed deletion is safely retryable with the same ID.
    _ = try writeNotesAlreadyLocked(writes, mode: .exactImport)
    if replacement == nil, local != nil {
      _ = try deleteDocumentAlreadyLocked(id: id)
    }
    return KnowledgeCloudNoteMutationResult(
      preservedConflictCopy: preserveLocal, hadLocalNote: local != nil)
  }
}
