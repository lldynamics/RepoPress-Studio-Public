import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeLibraryNotesTests: XCTestCase {
  func testCreateBlankNotePreservesStableMetadataAndAttachment() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let attachmentID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let note = KnowledgeNote(
      id: UUID(),
      title: "",
      tags: ["灵感", "iOS"],
      createdAt: createdAt,
      updatedAt: createdAt,
      sourceURL: URL(string: "https://example.com/reference"),
      markdown: "",
      attachments: [
        KnowledgeNoteAttachment(
          id: attachmentID,
          fileName: "source.txt",
          mimeType: "text/plain",
          data: Data("附件正文".utf8)
        )
      ]
    )

    let saved = try service.createNote(note)
    let loaded = try XCTUnwrap(service.note(documentID: note.id))

    XCTAssertEqual(saved.id, note.id)
    XCTAssertEqual(loaded.id, note.id)
    XCTAssertEqual(loaded.title, "")
    XCTAssertEqual(loaded.tags, ["灵感", "iOS"])
    XCTAssertEqual(loaded.createdAt, createdAt)
    XCTAssertEqual(loaded.sourceURL, note.sourceURL)
    XCTAssertEqual(loaded.markdown, "")
    XCTAssertEqual(loaded.attachments.count, 1)
    XCTAssertEqual(loaded.attachments.first?.id, attachmentID)
    XCTAssertEqual(loaded.attachments.first?.data, Data("附件正文".utf8))
    XCTAssertFalse(
      try service.documents().contains(where: { $0.id == note.id && $0.allowsRemoteAIUse }))
  }

  func testUpdateCreatesRevisionAndKeepsCreatedAt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let original = try service.createNote(
      KnowledgeNote(title: "原始标题", markdown: "第一版正文", attachments: []))

    let updated = try service.updateNote(
      KnowledgeNote(
        id: original.id,
        title: "更新标题",
        tags: ["待整理"],
        createdAt: Date(),
        updatedAt: Date(),
        sourceURL: URL(string: "https://example.com/updated"),
        markdown: "# 第二版\n\n可插入文章的 Markdown 正文。"
      ))

    let loaded = try XCTUnwrap(service.note(documentID: original.id))
    // SQLite stores Unix time as Double; converting from Date's reference epoch can
    // change the least significant fraction without changing the user-visible time.
    XCTAssertEqual(
      updated.createdAt.timeIntervalSince1970,
      original.createdAt.timeIntervalSince1970,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      loaded.createdAt.timeIntervalSince1970,
      original.createdAt.timeIntervalSince1970,
      accuracy: 0.000_001
    )
    XCTAssertEqual(loaded.title, "更新标题")
    XCTAssertEqual(loaded.tags, ["待整理"])
    XCTAssertEqual(loaded.markdown, "# 第二版\n\n可插入文章的 Markdown 正文。")
    XCTAssertEqual(try service.revisions(documentID: original.id).count, 2)
    XCTAssertFalse(loaded.isArchived)
  }

  func testExpectedRevisionRejectsStaleEditorDraftWithoutOverwritingNewerContent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let original = try service.createNote(
      KnowledgeNote(
        title: "Note",
        markdown: "original",
        attachments: [KnowledgeNoteAttachment(fileName: "proof.txt", data: Data("proof".utf8))]
      ))
    let expectedRevision = service.noteEditRevision(original)
    _ = try service.updateNote(
      KnowledgeNote(
        id: original.id,
        title: "Note",
        createdAt: original.createdAt,
        updatedAt: original.updatedAt.addingTimeInterval(30),
        markdown: "remote update",
        attachments: original.attachments
      ))
    let staleDraft = KnowledgeNote(
      id: original.id,
      title: "Stale editor",
      createdAt: original.createdAt,
      updatedAt: Date(),
      markdown: "stale overwrite",
      attachments: original.attachments
    )

    XCTAssertThrowsError(
      try service.updateNote(staleDraft, expectedContentRevision: expectedRevision)
    ) { error in
      guard let libraryError = error as? KnowledgeLibraryError,
        case .staleNoteRevision = libraryError
      else {
        return XCTFail("Expected a typed stale revision error, got \(error)")
      }
    }
    XCTAssertEqual(try service.note(documentID: original.id)?.markdown, "remote update")
    var durableCopy = staleDraft
    durableCopy.id = UUID()
    durableCopy.title = "Stale editor（冲突副本）"
    durableCopy.attachments = durableCopy.attachments.map { attachment in
      var copy = attachment
      copy.id = UUID()
      return copy
    }
    _ = try service.createNote(durableCopy)
    let notes = try service.notes()
    XCTAssertEqual(notes.count, 2)
    XCTAssertTrue(notes.contains(where: { $0.id == original.id && $0.markdown == "remote update" }))
    XCTAssertTrue(
      notes.contains(where: {
        $0.id == durableCopy.id && $0.markdown == "stale overwrite"
          && $0.attachments.first?.data == Data("proof".utf8)
      }))
  }

  func testRejectConflictLeavesEntireBatchUnchanged() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let existing = try service.createNote(KnowledgeNote(title: "本机", markdown: "本机正文"))
    let newNote = KnowledgeNote(title: "应当不写入", markdown: "新内容")
    let conflict = KnowledgeNote(id: existing.id, title: "冲突", markdown: "不同正文")

    XCTAssertThrowsError(try service.importNotes([newNote, conflict]))
    XCTAssertNil(try service.note(documentID: newNote.id))
    XCTAssertEqual(try service.note(documentID: existing.id)?.markdown, "本机正文")
  }

  func testDeleteNoteRemovesUnreferencedAttachmentFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let data = Data([0, 1, 2, 3])
    let hash = KnowledgeChunkingService.contentHash(for: data)
    let note = try service.createNote(
      KnowledgeNote(
        markdown: "保留附件",
        attachments: [KnowledgeNoteAttachment(fileName: "proof.bin", data: data)]
      ))
    let attachmentURL = root.appendingPathComponent("attachments/sha256/\(hash.prefix(2))/\(hash)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

    _ = try service.deleteDocument(id: note.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
  }

  func testNilMIMEAndOctetStreamProduceTheSameImportSignature() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let noteID = UUID()
    let attachmentID = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try service.createNote(
      KnowledgeNote(
        id: noteID,
        title: "附件",
        createdAt: date,
        updatedAt: date,
        markdown: "正文",
        attachments: [
          KnowledgeNoteAttachment(id: attachmentID, fileName: "data.bin", data: Data([1, 2]))
        ]
      ))
    let incoming = KnowledgeNote(
      id: noteID,
      title: "附件",
      createdAt: date,
      updatedAt: date,
      markdown: "正文",
      attachments: [
        KnowledgeNoteAttachment(
          id: attachmentID,
          fileName: "data.bin",
          mimeType: "application/octet-stream",
          data: Data([1, 2])
        )
      ]
    )

    XCTAssertEqual(try service.importNote(incoming), .skippedIdentical(noteID))
  }

  func testRejectsCredentialBearingSourceURL() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    XCTAssertThrowsError(
      try service.createNote(
        KnowledgeNote(
          sourceURL: URL(string: "https://username:password@example.com/private"),
          markdown: "正文"
        )))
  }

  func testPostCommitCleanupFailureLeavesSavedNoteReadable() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    service.notePostCommitCleanup = { _ in throw CleanupFailure.expected }

    let saved = try service.createNote(
      KnowledgeNote(markdown: "提交后的清理故障也不能删除这条笔记。")
    )

    XCTAssertEqual(
      try service.note(documentID: saved.id)?.markdown,
      "提交后的清理故障也不能删除这条笔记。"
    )
  }

  func testNoteSourceURLPolicyAcceptsHTTPAndHTTPSButRejectsUnsafeForms() throws {
    XCTAssertEqual(
      try KnowledgeLibraryService.noteSourceURL(from: " https://example.com/reference "),
      URL(string: "https://example.com/reference")
    )
    XCTAssertEqual(
      try KnowledgeLibraryService.noteSourceURL(from: "http://example.com/reference"),
      URL(string: "http://example.com/reference")
    )

    for rawValue in [
      "ftp://example.com/reference",
      "https:///missing-host",
      "https://username:password@example.com/private",
    ] {
      XCTAssertThrowsError(try KnowledgeLibraryService.noteSourceURL(from: rawValue)) { error in
        guard let libraryError = error as? KnowledgeLibraryError,
          case .invalidNoteSourceURL = libraryError
        else {
          return XCTFail("Expected a typed invalid source URL error, got \(error)")
        }
      }
    }
  }

  func testImportRejectsMetadataThatWouldBeNormalized() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let now = Date()
    let invalidNotes = [
      KnowledgeNote(title: " 标题", createdAt: now, updatedAt: now, markdown: "正文"),
      KnowledgeNote(
        tags: Array(repeating: "标签", count: 51), createdAt: now, updatedAt: now, markdown: "正文"),
    ]

    for note in invalidNotes {
      XCTAssertThrowsError(try service.importNote(note))
      XCTAssertNil(try service.note(documentID: note.id))
    }
  }

  func testImportPreservesFutureTimestampsFromAnotherDeviceClock() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let createdAt = Date().addingTimeInterval(10 * 60)
    let updatedAt = createdAt.addingTimeInterval(30)
    let note = KnowledgeNote(
      createdAt: createdAt,
      updatedAt: updatedAt,
      markdown: "来自时钟略快设备的笔记"
    )

    XCTAssertEqual(try service.importNote(note), .inserted(note.id))
    let loaded = try XCTUnwrap(service.note(documentID: note.id))
    XCTAssertEqual(
      loaded.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.000_001)
    XCTAssertEqual(
      loaded.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
    XCTAssertEqual(try service.importNote(note), .skippedIdentical(note.id))
  }

  func testArchivedNoteDoesNotEnterTheRecycleBin() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let note = try service.createNote(
      KnowledgeNote(isArchived: true, markdown: "archiveuniqueneedle")
    )

    XCTAssertTrue(try XCTUnwrap(service.note(documentID: note.id)).isArchived)
    XCTAssertTrue(try service.notes(includeArchived: false).isEmpty)
    XCTAssertFalse(try service.recycledDocuments().contains(where: { $0.document.id == note.id }))
    XCTAssertFalse(try service.documents().contains(where: { $0.id == note.id }))
    XCTAssertFalse(
      try service.search(query: "archiveuniqueneedle", requiredSignal: .fullText)
        .contains(where: { $0.document.id == note.id })
    )
  }

  func testImportRejectsExistingNonNoteIdentifierWithoutOverwritingIt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let documentID = UUID()
    let existing = KnowledgeDocument(
      id: documentID,
      kind: .webpage,
      title: "原始网页资料",
      sourceName: "网页"
    )
    try service.database().upsertDocument(existing)

    XCTAssertThrowsError(
      try service.importNote(
        KnowledgeNote(id: documentID, markdown: "不能覆盖网页资料")
      )
    )
    XCTAssertEqual(try service.database().document(id: documentID)?.kind, .webpage)
    XCTAssertEqual(try service.database().document(id: documentID)?.title, "原始网页资料")
  }

  private enum CleanupFailure: Error { case expected }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
