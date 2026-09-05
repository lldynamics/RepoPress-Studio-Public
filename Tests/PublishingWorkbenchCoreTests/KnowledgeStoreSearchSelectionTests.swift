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
}
