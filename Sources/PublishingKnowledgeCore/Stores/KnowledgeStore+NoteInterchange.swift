import Foundation

public struct KnowledgeNotePackagePreview: Identifiable, Sendable {
  public let id = UUID()
  public let package: RPNotePackage
  public let newCount: Int
  public let identicalCount: Int
  public let conflictingTitles: [String]
  public let blockedTitles: [String]

  public var conflictCount: Int { conflictingTitles.count }
  public var blockedCount: Int { blockedTitles.count }
}

@MainActor
extension KnowledgeStore {
  /// Schedules an opt-in, throttled iCloud note snapshot from the library's
  /// current locally committed state.
  public func createAutomaticNoteSnapshotIfDue() async throws -> URL? {
    try await KnowledgeNoteAutomaticSnapshotBackup.shared.createSnapshotIfDue(service: service)
  }

  public func exportNotePackage(selectedIDs: Set<UUID>) async throws -> RPNotePackage {
    let allNotes = try await service.notesAsync()
    let chosen = selectedIDs.isEmpty
      ? allNotes
      : allNotes.filter { selectedIDs.contains($0.id) }
    return RPNotePackage(notes: chosen.map(Self.portableNote))
  }

  public func previewNotePackage(_ package: RPNotePackage) async throws -> KnowledgeNotePackagePreview {
    try await service.validateNotesForImportAsync(package.notes.map(Self.knowledgeNote))
    var newCount = 0
    var identicalCount = 0
    var conflictingTitles: [String] = []
    var blockedTitles: [String] = []
    for incoming in package.notes {
      guard let existing = try await service.noteAsync(documentID: incoming.id) else {
        if let existingDocument = try service.document(id: incoming.id) {
          blockedTitles.append(existingDocument.title.isEmpty ? incoming.id.uuidString : existingDocument.title)
        } else {
          newCount += 1
        }
        continue
      }
      if Self.equivalent(Self.portableNote(existing), incoming) {
        identicalCount += 1
      } else {
        conflictingTitles.append(incoming.title.isEmpty ? "未命名笔记" : incoming.title)
      }
    }
    return KnowledgeNotePackagePreview(
      package: package,
      newCount: newCount,
      identicalCount: identicalCount,
      conflictingTitles: conflictingTitles,
      blockedTitles: blockedTitles
    )
  }

  /// Applies one validated package through the library's all-or-nothing import path.
  public func importNotePackage(
    _ package: RPNotePackage,
    keepConflictingCopies: Bool
  ) async throws -> [KnowledgeNoteImportDisposition] {
    let notes = package.notes.map(Self.knowledgeNote)
    let mode: KnowledgeNoteImportMode = keepConflictingCopies ? .copyWithNewID : .rejectConflict
    let busyOperationID = beginBusyOperation()
    defer { finishBusyOperation(busyOperationID) }
    do {
      let dispositions = try await performQueuedKnowledgeMutation { [service] in
        try await service.importNotesAsync(notes, mode: mode)
      }
      await waitAfterAcceptedMutationBeforeProjection()
      await reloadAfterAcceptedMutation()
      statusMessage = "笔记包已导入。"
      lastError = nil
      return dispositions
    } catch {
      lastError = error.localizedDescription
      statusMessage = "导入笔记包失败：\(error.localizedDescription)"
      throw error
    }
  }

  private static func portableNote(_ note: KnowledgeNote) -> RPNote {
    RPNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        RPNoteAttachment(
          id: $0.id,
          fileName: $0.fileName,
          mimeType: $0.mimeType ?? "application/octet-stream",
          data: $0.data
        )
      }
    )
  }

  private static func knowledgeNote(_ note: RPNote) -> KnowledgeNote {
    KnowledgeNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        KnowledgeNoteAttachment(
          id: $0.id,
          fileName: $0.fileName,
          mimeType: $0.mimeType,
          data: $0.data
        )
      }
    )
  }

  private static func equivalent(_ lhs: RPNote, _ rhs: RPNote) -> Bool {
    var left = lhs
    var right = rhs
    left.attachments.sort { $0.id.uuidString < $1.id.uuidString }
    right.attachments.sort { $0.id.uuidString < $1.id.uuidString }
    return left == right
  }
}
