import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeHistoryIsolationTests: XCTestCase {
  func testRestoringBackgroundHistoryKeepsOtherDocumentSelected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-history-restore-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let first = try service.createNote(KnowledgeNote(title: "A", markdown: "A original"))
    let original = try XCTUnwrap(try service.revisions(documentID: first.id).first)
    _ = try service.updateNote(
      KnowledgeNote(
        id: first.id, title: "A", createdAt: first.createdAt, updatedAt: Date(),
        markdown: "A edited"
      ))
    let second = try service.createNote(KnowledgeNote(title: "B", markdown: "B reading"))
    let store = KnowledgeStore(service: service)
    await store.reload(selecting: second.id)
    await store.selectedTextTask?.value
    let text = store.selectedDocumentText

    let restored = await store.restoreRevision(original.id, documentID: first.id)

    XCTAssertTrue(restored)
    XCTAssertEqual(store.selectedDocumentID, second.id)
    XCTAssertEqual(store.selectedDocumentText, text)
    let revisions = try await store.revisionsForHistory(documentID: first.id)
    XCTAssertTrue(revisions.allSatisfy { $0.documentID == first.id })
    XCTAssertEqual(revisions.count, 2)
    XCTAssertEqual(store.documents.first { $0.id == first.id }?.currentRevisionID, original.id)
  }

  func testRefreshingBackgroundSourceKeepsSelectionMadeDuringMutation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-history-refresh-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.md")
    try "# Source\n\nOriginal body".write(to: file, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: root.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: file))
    let first = try XCTUnwrap(service.documents().first)
    let second = try service.createNote(KnowledgeNote(title: "B", markdown: "B reading"))
    let store = KnowledgeStore(service: service)
    await store.reload(selecting: first.id)
    try "# Source\n\nUpdated body".write(to: file, atomically: true, encoding: .utf8)
    let preview = try await store.makeSourceRefreshPreview(documentID: first.id)
    store.afterAcceptedMutationBeforeProjection = { store.selectDocument(second.id) }

    let refreshed = await store.applySourceRefresh(preview)

    XCTAssertTrue(refreshed)
    XCTAssertEqual(store.selectedDocumentID, second.id)
    await store.selectedTextTask?.value
    XCTAssertTrue(store.selectedDocumentText.contains("B reading"))
    XCTAssertNotEqual(
      store.documents.first { $0.id == first.id }?.currentRevisionID, first.currentRevisionID)
  }

  func testHistoryQueryStaysOnDocumentWhenAnotherSelectionLoadsInsights() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-history-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let first = try service.createNote(KnowledgeNote(title: "A", markdown: "A unique body"))
    let second = try service.createNote(KnowledgeNote(title: "B", markdown: "B unique body"))
    let store = KnowledgeStore(service: service)
    await store.reload(selecting: first.id)

    let firstHistory = try await store.revisionsForHistory(documentID: first.id)
    XCTAssertFalse(firstHistory.isEmpty)
    XCTAssertTrue(firstHistory.allSatisfy { $0.documentID == first.id })

    await store.reload(selecting: second.id)
    let secondHistory = try await store.revisionsForHistory(documentID: second.id)
    let historyWhileBIsSelected = try await store.revisionsForHistory(documentID: first.id)
    XCTAssertEqual(store.selectedDocumentID, second.id)
    XCTAssertEqual(historyWhileBIsSelected, firstHistory)
    XCTAssertTrue(secondHistory.allSatisfy { $0.documentID == second.id })
    XCTAssertTrue(Set(firstHistory.map(\.id)).isDisjoint(with: secondHistory.map(\.id)))

    _ = try service.updateNote(
      KnowledgeNote(
        id: first.id,
        title: "A",
        createdAt: first.createdAt,
        updatedAt: Date(),
        markdown: "A new unique body"
      )
    )
    let refreshedHistory = try await store.revisionsForHistory(documentID: first.id)
    XCTAssertGreaterThan(refreshedHistory.count, firstHistory.count)
    XCTAssertTrue(refreshedHistory.allSatisfy { $0.documentID == first.id })
    XCTAssertEqual(store.selectedDocumentID, second.id)
  }
}
