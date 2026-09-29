import XCTest

@testable import PublishingKnowledgeCore

#if DEBUG
  @MainActor
  final class KnowledgeNavigationSnapshotCacheTests: XCTestCase {
    func testNavigationSnapshotKeepsCountsFreshWithoutSelectionRescans() async {
      let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("KnowledgeNavigationSnapshotCacheTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: rootURL) }
      let store = KnowledgeStore(service: KnowledgeLibraryService(rootURL: rootURL))
      await store.reload()

      let reading = KnowledgeFolder(name: "阅读")
      let research = KnowledgeFolder(name: "研究")
      let matching = KnowledgeDocument(
        kind: .article,
        title: "Swift 并发",
        authors: ["Ada"],
        tags: ["Swift"],
        folderID: reading.id
      )
      let unfiled = KnowledgeDocument(
        kind: .webpage,
        title: "未分类网页",
        authors: ["Grace"],
        tags: ["Web"]
      )
      let authorCollection = KnowledgeSavedCollection(
        name: "Ada 的资料",
        rules: [.author("Ada")]
      )
      store.folders = [reading, research]
      store.documents = [matching, unfiled]

      let initialSnapshotBuilds = store.navigationSnapshotBuildCount
      let initialSavedCountBuilds = store.navigationSavedCollectionCountBuildCount
      let first = store.navigationSnapshot(savedCollections: [authorCollection])
      XCTAssertEqual(first.documentCount, 2)
      XCTAssertEqual(first.unfiledDocumentCount, 1)
      XCTAssertEqual(first.documentCount(forFolderID: reading.id), 1)
      XCTAssertEqual(first.documentCount(forFolderID: research.id), 0)
      XCTAssertEqual(first.documentCount(for: authorCollection), 1)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 1)
      XCTAssertEqual(store.navigationSavedCollectionCountBuildCount, initialSavedCountBuilds + 1)

      store.setFolderScope(.folder(reading.id))
      store.selectedDocumentID = matching.id
      store.setDocumentSortDirection(.ascending)
      let afterSelection = store.navigationSnapshot(savedCollections: [authorCollection])
      XCTAssertEqual(afterSelection.documentCount(forFolderID: reading.id), 1)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 1)
      XCTAssertEqual(store.navigationSavedCollectionCountBuildCount, initialSavedCountBuilds + 1)

      store.folders[0].name = "待读"
      let afterRename = store.navigationSnapshot(savedCollections: [authorCollection])
      XCTAssertEqual(afterRename.documentCount(forFolderID: reading.id), 1)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 1)

      store.documents[1].folderID = reading.id
      let afterMove = store.navigationSnapshot(savedCollections: [authorCollection])
      XCTAssertEqual(afterMove.unfiledDocumentCount, 0)
      XCTAssertEqual(afterMove.documentCount(forFolderID: reading.id), 2)
      XCTAssertEqual(afterMove.documentCount(for: authorCollection), 1)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 2)
      XCTAssertEqual(store.navigationSavedCollectionCountBuildCount, initialSavedCountBuilds + 2)

      let changedRules = KnowledgeSavedCollection(
        id: authorCollection.id,
        name: "无匹配标签",
        rules: [.tag("Missing")],
        createdAt: authorCollection.createdAt
      )
      let afterRuleChange = store.navigationSnapshot(savedCollections: [changedRules])
      XCTAssertEqual(afterRuleChange.documentCount(for: changedRules), 0)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 2)
      XCTAssertEqual(store.navigationSavedCollectionCountBuildCount, initialSavedCountBuilds + 3)
      XCTAssertLessThanOrEqual(store.navigationSavedCollectionCacheEntryCount, 1)

      var documentsAfterMetadataUpdate = store.documents
      documentsAfterMetadataUpdate[0].tags = ["Missing"]
      store.documents = documentsAfterMetadataUpdate
      let afterDocumentUpdate = store.navigationSnapshot(savedCollections: [changedRules])
      XCTAssertEqual(afterDocumentUpdate.documentCount(for: changedRules), 1)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 3)

      store.folders = []
      store.documents = store.documents.map { document in
        var unfiledDocument = document
        unfiledDocument.folderID = nil
        return unfiledDocument
      }
      let afterFolderDeletion = store.navigationSnapshot(savedCollections: [changedRules])
      XCTAssertEqual(afterFolderDeletion.documentCount, 2)
      XCTAssertEqual(afterFolderDeletion.unfiledDocumentCount, 2)
      XCTAssertEqual(afterFolderDeletion.documentCount(forFolderID: reading.id), 0)
      XCTAssertEqual(store.navigationSnapshotBuildCount, initialSnapshotBuilds + 4)
      XCTAssertEqual(store.navigationSavedCollectionCountBuildCount, initialSavedCountBuilds + 5)
    }
  }
#endif
