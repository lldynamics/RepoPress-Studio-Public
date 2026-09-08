import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class KnowledgeStoreSearchSelectionTests: XCTestCase {
  func testClearingSearchResultSelectionKeepsLoadedDocumentSelected() async {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeSearchSelection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = KnowledgeStore(service: KnowledgeLibraryService(rootURL: rootURL))
    await store.reload()

    let document = KnowledgeDocument(kind: .article, title: "Searchable document")
    let result = KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: 0,
        content: "Matched passage",
        tokenEstimate: 2,
        contentHash: "test-hash"
      ),
      score: 1,
      signals: [.fullText]
    )
    store.documents = [document]
    store.searchResults = [result]
    store.searchText = "matched"
    store.selectSearchResult(result)

    store.clearSearchResultSelection()

    XCTAssertNil(store.selectedSearchResult)
    XCTAssertEqual(store.selectedResultQuery, "")
    XCTAssertEqual(store.selectedDocumentID, document.id)
  }

  func testSavingAnnotationForBackgroundDocumentDoesNotReplaceCurrentInspector() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeAnnotationProjection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceA = rootURL.appendingPathComponent("a.md")
    let sourceB = rootURL.appendingPathComponent("b.md")
    try "# A\n\nA body".write(to: sourceA, atomically: true, encoding: .utf8)
    try "# B\n\nB body".write(to: sourceB, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceA))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceB))
    let documents = try service.documents()
    let documentA = try XCTUnwrap(documents.first { $0.sourceURL == sourceA })
    let documentB = try XCTUnwrap(documents.first { $0.sourceURL == sourceB })
    let store = KnowledgeStore(service: service)

    await store.reload(selecting: documentB.id)
    await store.documentInsightsTask?.value
    let saved = await store.saveAnnotation(
      KnowledgeAnnotation(documentID: documentA.id, note: "A 的后台标注")
    )
    XCTAssertTrue(saved)

    XCTAssertEqual(store.selectedDocumentID, documentB.id)
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertEqual(try service.annotations(documentID: documentA.id).count, 1)
  }

  func testSourceRefreshReloadsSelectedDocumentWhenRevisionChanges() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeRevisionProjection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Version\n\nOLD_REVISION_SENTINEL".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let store = KnowledgeStore(service: service)

    await store.reload(selecting: document.id)
    await store.selectedTextTask?.value
    XCTAssertTrue(store.selectedDocumentText.contains("OLD_REVISION_SENTINEL"))
    let initialRevisionID = store.selectedDocumentTextRevisionID

    try "# Version\n\nNEW_REVISION_SENTINEL".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let preview = try await store.makeSourceRefreshPreview(documentID: document.id)
    let refreshed = await store.applySourceRefresh(preview)
    XCTAssertTrue(refreshed)
    await store.selectedTextTask?.value

    XCTAssertTrue(store.selectedDocumentText.contains("NEW_REVISION_SENTINEL"))
    XCTAssertFalse(store.selectedDocumentText.contains("OLD_REVISION_SENTINEL"))
    XCTAssertNotEqual(store.selectedDocumentTextRevisionID, initialRevisionID)
    XCTAssertEqual(store.selectedDocumentTextRevisionID, store.selectedDocument?.currentRevisionID)
  }
}
