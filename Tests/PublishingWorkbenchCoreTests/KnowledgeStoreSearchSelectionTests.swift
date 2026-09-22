import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class KnowledgeStoreSearchSelectionTests: XCTestCase {
  func testUnifiedSearchRevealsCurrentHitAndFallsBackAfterRevisionChanges() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeUnifiedNavigation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.md")
    try "# Document\n\nNavigation needle".write(to: source, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: root.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: source))
    let document = try XCTUnwrap(service.documents().first)
    let result = KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id, revisionID: document.currentRevisionID,
        ordinal: 0, content: "Navigation needle", tokenEstimate: 2, contentHash: "navigation"
      ),
      score: 1, signals: [.fullText]
    )
    let store = KnowledgeStore(service: service)
    await store.reload()
    store.folderScope = .folder(UUID())
    store.updateSearchText("old query")

    XCTAssertTrue(store.revealSearchResult(result, query: "needle"))
    XCTAssertEqual(store.folderScope, .all)
    XCTAssertEqual(store.searchText, "")
    XCTAssertFalse(store.isSearching)
    XCTAssertEqual(store.selectedDocumentID, result.document.id)
    XCTAssertEqual(store.selectedSearchResult?.chunk.id, result.chunk.id)
    XCTAssertEqual(store.selectedResultQuery, "needle")

    store.documents[0].currentRevisionID = UUID()
    XCTAssertTrue(store.revealSearchResult(result, query: "needle"))
    XCTAssertEqual(store.selectedDocumentID, result.document.id)
    XCTAssertNil(store.selectedSearchResult)
    store.documents = []
    XCTAssertFalse(store.revealSearchResult(result, query: "needle"))
  }

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

  func testSourceRefreshRequeriesActiveSearchWithCurrentRevision() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeSearchRefresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Version\n\nREFRESH_SENTINEL old".write(
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
    let initialTextRevision = store.selectedDocumentTextRevisionID
    store.updateSearchText("REFRESH_SENTINEL")
    await store.searchTask?.value
    let oldResult = try XCTUnwrap(store.searchResults.first)
    XCTAssertTrue(oldResult.chunk.content.contains("old"))

    // A no-op source check still re-runs the active query without changing
    // the hit's revision.
    let unchangedPreview = try await store.makeSourceRefreshPreview(documentID: document.id)
    let unchanged = await store.applySourceRefresh(unchangedPreview)
    XCTAssertTrue(unchanged)
    await store.searchTask?.value
    XCTAssertEqual(store.searchResults.first?.chunk.revisionID, oldResult.chunk.revisionID)

    try "# Version\n\nREFRESH_SENTINEL new".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    store.updateSearchText("REFRESH_SENTINEL")
    let pendingSearchTask = store.searchTask
    var staleSearchPublished = false
    store.afterAcceptedMutationBeforeProjection = {
      await pendingSearchTask?.value
      staleSearchPublished = !store.searchResults.isEmpty
    }
    let preview = try await store.makeSourceRefreshPreview(documentID: document.id)
    let refreshed = await store.applySourceRefresh(preview)
    store.afterAcceptedMutationBeforeProjection = nil
    XCTAssertTrue(refreshed)
    XCTAssertFalse(staleSearchPublished)
    await store.searchTask?.value
    await store.selectedTextTask?.value

    XCTAssertFalse(
      store.searchResults.contains { $0.chunk.revisionID == oldResult.chunk.revisionID })
    XCTAssertTrue(store.searchResults.contains { $0.chunk.content.contains("new") })
    XCTAssertNotEqual(store.selectedDocumentTextRevisionID, initialTextRevision)
    XCTAssertEqual(
      store.visibleDocuments.first?.currentRevisionID, store.documents.first?.currentRevisionID)
  }

  func testDeletingDocumentDuringSearchLeavesSearchingFinished() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeSearchDelete-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Delete\n\nDELETE_SEARCH_SENTINEL".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let store = KnowledgeStore(service: service)
    await store.reload()

    store.updateSearchText("DELETE_SEARCH_SENTINEL")
    let deleted = await store.deleteDocument(document.id)
    XCTAssertTrue(deleted)
    await store.searchTask?.value

    XCTAssertFalse(store.isSearching)
    XCTAssertTrue(store.searchResults.isEmpty)
    XCTAssertTrue(store.documents.isEmpty)
  }

  func testSelectSearchResultRejectsStaleRevision() async {
    let store = KnowledgeStore(
      service: KnowledgeLibraryService(
        rootURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("KnowledgeStaleSelection-\(UUID().uuidString)")))
    let document = KnowledgeDocument(kind: .article, title: "Stale")
    let result = KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: 0,
        content: "stale",
        tokenEstimate: 1,
        contentHash: "stale"
      ),
      score: 1,
      signals: [.fullText]
    )
    store.documents = [document]
    store.searchResults = [result]
    store.searchText = "stale"
    store.documents[0].currentRevisionID = UUID()

    store.selectSearchResult(result)

    XCTAssertNil(store.selectedSearchResult)
    XCTAssertTrue(store.statusMessage?.contains("重新搜索") == true)
  }

  func testCurrentCollectionSearchRequeriesAfterRestoreProjection() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeCollectionRestore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Collection\n\nCOLLECTION_RESTORE_SENTINEL".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let store = KnowledgeStore(service: service)
    await store.reload()
    await store.createFolder(name: "Collection")
    let folderID = try XCTUnwrap(store.folders.first?.id)
    await store.moveDocument(document.id, to: folderID)
    store.folderScope = .folder(folderID)
    store.setSearchScope(.currentCollection)
    store.updateSearchText("COLLECTION_RESTORE_SENTINEL")
    await store.searchTask?.value
    XCTAssertEqual(store.searchResults.first?.document.id, document.id)

    let movedToRecycleBin = await store.moveToRecycleBin(Set([document.id]))
    XCTAssertTrue(movedToRecycleBin)
    let restored = await store.restoreFromRecycleBin(Set([document.id]))
    XCTAssertTrue(restored)
    await store.searchTask?.value

    XCTAssertEqual(store.searchResults.first?.document.id, document.id)
    XCTAssertEqual(store.visibleDocuments.first?.id, document.id)
  }
}
