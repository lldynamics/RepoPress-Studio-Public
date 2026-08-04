import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class KnowledgeListPresentationCacheTests: XCTestCase {
  func testVisibleListSnapshotsRebuildOnlyAfterPresentationRevisionChanges() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeListPresentationCacheTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = KnowledgeStore(service: KnowledgeLibraryService(rootURL: rootURL))
    await store.reload()

    let firstDirection: KnowledgeSortDirection = store.documentSort.direction == .ascending
      ? .descending
      : .ascending
    store.setDocumentSortDirection(firstDirection)

    let documentBuilds = store.visibleDocumentsSnapshotBuildCount
    _ = store.visibleDocuments
    let firstDocumentBuilds = store.visibleDocumentsSnapshotBuildCount
    _ = store.visibleDocuments
    XCTAssertEqual(firstDocumentBuilds, documentBuilds + 1)
    XCTAssertEqual(store.visibleDocumentsSnapshotBuildCount, firstDocumentBuilds)

    let searchBuilds = store.visibleSearchResultsSnapshotBuildCount
    _ = store.visibleSearchResults
    let firstSearchBuilds = store.visibleSearchResultsSnapshotBuildCount
    _ = store.visibleSearchResults
    XCTAssertEqual(firstSearchBuilds, searchBuilds + 1)
    XCTAssertEqual(store.visibleSearchResultsSnapshotBuildCount, firstSearchBuilds)

    let previousRevision = store.listPresentationRevision
    let nextDirection: KnowledgeSortDirection = store.documentSort.direction == .ascending
      ? .descending
      : .ascending
    store.setDocumentSortDirection(nextDirection)
    XCTAssertGreaterThan(store.listPresentationRevision, previousRevision)

    _ = store.visibleDocuments
    _ = store.visibleSearchResults
    XCTAssertEqual(store.visibleDocumentsSnapshotBuildCount, firstDocumentBuilds + 1)
    XCTAssertEqual(store.visibleSearchResultsSnapshotBuildCount, firstSearchBuilds + 1)
  }
}
