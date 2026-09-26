import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeReferenceWindowSnapshotTests: XCTestCase {
  func testReferenceSnapshotKeepsMainSelectionAndReadsCurrentRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-reference-window-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = KnowledgeLibraryService(rootURL: root)
    let reference = try service.createNote(
      KnowledgeNote(title: "Reference", markdown: "# First revision")
    )
    let mainSelection = try service.createNote(
      KnowledgeNote(title: "Main selection", markdown: "Main body")
    )
    let store = KnowledgeStore(service: service)
    await store.reload(selecting: mainSelection.id)
    XCTAssertEqual(store.selectedDocumentID, mainSelection.id)

    let firstSnapshot = try await store.referenceDocumentSnapshot(documentID: reference.id)
    let first = try XCTUnwrap(firstSnapshot)
    XCTAssertEqual(first.document.id, reference.id)
    XCTAssertEqual(first.normalizedText, "# First revision")
    XCTAssertEqual(store.selectedDocumentID, mainSelection.id)

    _ = try service.updateNote(
      KnowledgeNote(
        id: reference.id,
        title: "Reference updated",
        createdAt: reference.createdAt,
        updatedAt: Date(),
        markdown: "# Second revision"
      )
    )
    let latestSnapshot = try await store.referenceDocumentSnapshot(documentID: reference.id)
    let latest = try XCTUnwrap(latestSnapshot)
    XCTAssertEqual(latest.document.title, "Reference updated")
    XCTAssertEqual(latest.normalizedText, "# Second revision")
    XCTAssertEqual(store.selectedDocumentID, mainSelection.id)

    _ = try service.updateNote(
      KnowledgeNote(
        id: reference.id,
        title: "Reference updated",
        createdAt: reference.createdAt,
        updatedAt: Date(),
        isArchived: true,
        markdown: "# Second revision"
      )
    )
    let archivedSnapshot = try await store.referenceDocumentSnapshot(documentID: reference.id)
    let archived = try XCTUnwrap(archivedSnapshot)
    XCTAssertTrue(archived.document.isArchived)
    XCTAssertEqual(archived.normalizedText, "")
    XCTAssertEqual(store.selectedDocumentID, mainSelection.id)

    _ = try service.updateNote(
      KnowledgeNote(
        id: reference.id,
        title: "Reference restored",
        createdAt: reference.createdAt,
        updatedAt: Date(),
        isArchived: false,
        markdown: "# Restored revision"
      )
    )
    let restoredSnapshot = try await store.referenceDocumentSnapshot(documentID: reference.id)
    let restored = try XCTUnwrap(restoredSnapshot)
    XCTAssertFalse(restored.document.isArchived)
    XCTAssertEqual(restored.normalizedText, "# Restored revision")
  }
}
