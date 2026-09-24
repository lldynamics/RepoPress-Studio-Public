import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeNoteInterchangeTests: XCTestCase {
  func testPackageRoundTripRepeatedImportAndConflictCopy() async throws {
    let sourceRoot = try makeRoot()
    let destinationRoot = try makeRoot()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }

    let sourceService = KnowledgeLibraryService(rootURL: sourceRoot)
    let noteID = UUID()
    let attachmentID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_726_000_000.123_456_789)
    let bytes = Data([0, 1, 2, 255])
    _ = try sourceService.createNote(
      KnowledgeNote(
        id: noteID,
        title: "跨设备笔记",
        tags: ["交换", "附件"],
        createdAt: timestamp,
        updatedAt: timestamp,
        sourceURL: URL(string: "https://example.com/note"),
        markdown: "# Markdown\n\n正文与附件。",
        attachments: [
          KnowledgeNoteAttachment(
            id: attachmentID,
            fileName: "Meeting Notes.pdf",
            mimeType: "application/pdf",
            data: bytes
          )
        ]
      )
    )

    let sourceStore = KnowledgeStore(service: sourceService)
    let exported = try await sourceStore.exportNotePackage(selectedIDs: [noteID])
    let decoded = try RPNotesPackageCodec.decode(RPNotesPackageCodec.encode(exported))
    XCTAssertEqual(decoded.notes.count, 1)
    XCTAssertEqual(decoded.notes[0].attachments.first?.data, bytes)

    let destinationService = KnowledgeLibraryService(rootURL: destinationRoot)
    let destinationStore = KnowledgeStore(service: destinationService)
    let firstPreview = try await destinationStore.previewNotePackage(decoded)
    XCTAssertEqual(firstPreview.newCount, 1)
    XCTAssertEqual(firstPreview.conflictCount, 0)
    let firstImport = try await destinationStore.importNotePackage(
      decoded, keepConflictingCopies: false)
    XCTAssertEqual(firstImport, [.inserted(noteID)])
    XCTAssertEqual(try destinationService.note(documentID: noteID)?.attachments.first?.data, bytes)

    let secondPreview = try await destinationStore.previewNotePackage(decoded)
    XCTAssertEqual(secondPreview.identicalCount, 1)
    let repeatedImport = try await destinationStore.importNotePackage(
      decoded, keepConflictingCopies: false)
    XCTAssertEqual(repeatedImport, [.skippedIdentical(noteID)])

    var modified = decoded
    modified.notes[0].markdown = "# 另一版"
    let conflictPreview = try await destinationStore.previewNotePackage(modified)
    XCTAssertEqual(conflictPreview.conflictCount, 1)
    let result = try await destinationStore.importNotePackage(
      modified,
      keepConflictingCopies: true
    )
    guard case .copied(let sourceID, let copyID) = try XCTUnwrap(result.first) else {
      return XCTFail("Expected a copy")
    }
    XCTAssertEqual(sourceID, noteID)
    XCTAssertNotEqual(copyID, noteID)
    XCTAssertEqual(try destinationService.note(documentID: noteID)?.markdown, "# Markdown\n\n正文与附件。")
    XCTAssertEqual(try destinationService.note(documentID: copyID)?.markdown, "# 另一版")
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-note-exchange-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
