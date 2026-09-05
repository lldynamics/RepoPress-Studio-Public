import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeCollectionModelsTests: XCTestCase {
  func testSavedCollectionNormalizesNameDeduplicatesRulesAndRoundTrips() throws {
    let longName = " \n" + String(repeating: "知识", count: 50) + " \t"
    let collection = KnowledgeSavedCollection(
      name: longName,
      rules: [
        .tag("Swift"), .tag("swift"),
        .author("Alice"), .author("alice"),
        .aiPermission(true),
      ],
      matchMode: .any,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(collection.name.count, 80)
    XCTAssertEqual(collection.rules, [.tag("Swift"), .author("Alice"), .aiPermission(true)])
    XCTAssertEqual(collection.matchMode, .any)
    XCTAssertEqual(
      try JSONDecoder().decode(
        KnowledgeSavedCollection.self, from: JSONEncoder().encode(collection)),
      collection
    )
  }

  func testDocumentSortOrdersEachPersistentFieldAndUsesStableTies() {
    let oldest = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
      kind: .book,
      title: "Bravo",
      byteCount: 10,
      importedAt: 10,
      updatedAt: 30
    )
    let middle = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
      kind: .image,
      title: "Charlie",
      byteCount: 20,
      importedAt: 20,
      updatedAt: 10
    )
    let newest = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
      kind: .article,
      title: "Alpha",
      byteCount: 30,
      importedAt: 30,
      updatedAt: 20
    )
    let sameTitleEarlierID = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
      kind: .text,
      title: "Same",
      byteCount: 40,
      importedAt: 40,
      updatedAt: 40
    )
    let sameTitleLaterID = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
      kind: .text,
      title: "Same",
      byteCount: 50,
      importedAt: 40,
      updatedAt: 40
    )
    let documents = [oldest, middle, newest, sameTitleLaterID, sameTitleEarlierID]

    XCTAssertEqual(
      KnowledgeDocumentSort(field: .title, direction: .ascending).sorted(documents).map(\.id),
      [newest, oldest, middle, sameTitleEarlierID, sameTitleLaterID].map(\.id)
    )
    XCTAssertEqual(
      KnowledgeDocumentSort(field: .fileSize, direction: .descending).sorted(documents).first?.id,
      sameTitleLaterID.id
    )
    XCTAssertEqual(
      KnowledgeDocumentSort(field: .addedAt, direction: .ascending).sorted(documents).first?.id,
      oldest.id
    )
    XCTAssertEqual(
      KnowledgeDocumentSort(field: .updatedAt, direction: .descending).sorted(documents).first?.id,
      sameTitleEarlierID.id
    )
    XCTAssertEqual(
      Set(KnowledgeDocumentSort(field: .kind, direction: .ascending).sorted(documents).map(\.id)),
      Set(documents.map(\.id))
    )
  }

  func testSearchFilterCombinesScopeSignalAndDeterministicAddedNewestOrdering() {
    let current = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
      kind: .article,
      title: "Current",
      byteCount: 1,
      importedAt: 10,
      updatedAt: 10
    )
    let external = document(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
      kind: .article,
      title: "External",
      byteCount: 1,
      importedAt: 20,
      updatedAt: 20
    )
    let currentSemantic = result(document: current, ordinal: 1, signals: [.semantic])
    let externalFullText = result(document: external, ordinal: 0, signals: [.fullText])

    let semanticInCurrentCollection = KnowledgeSearchFilter(
      scope: .currentCollection,
      signal: .semantic,
      sort: .relevance
    )
    XCTAssertEqual(
      semanticInCurrentCollection.filtered([currentSemantic, externalFullText]) {
        $0.id == current.id
      }
      .map(\.id),
      [currentSemantic.id]
    )

    let newestAcrossLibrary = KnowledgeSearchFilter(
      scope: .allLibrary,
      signal: .all,
      sort: .addedNewest
    )
    XCTAssertEqual(
      newestAcrossLibrary.filtered([currentSemantic, externalFullText]) { _ in false }.map(\.id),
      [externalFullText.id, currentSemantic.id]
    )
  }

  func testSelectionEnumsExposeStableIDsAndNonEmptyPresentationMetadata() {
    XCTAssertEqual(
      Set(KnowledgeDocumentKind.allCases.map(\.id)),
      Set(KnowledgeDocumentKind.allCases.map(\.rawValue)))
    XCTAssertTrue(
      KnowledgeDocumentKind.allCases.allSatisfy {
        !$0.displayName.isEmpty && !$0.systemImage.isEmpty
      })
    XCTAssertTrue(
      KnowledgeRetrievalPolicy.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.detail.isEmpty }
    )
    XCTAssertTrue(KnowledgeDocumentSortField.allCases.allSatisfy { !$0.displayName.isEmpty })
    XCTAssertTrue(
      KnowledgeSortDirection.allCases.allSatisfy {
        !$0.displayName.isEmpty && !$0.systemImage.isEmpty
      })
  }

  private func document(
    id: UUID,
    kind: KnowledgeDocumentKind,
    title: String,
    byteCount: Int64,
    importedAt: TimeInterval,
    updatedAt: TimeInterval
  ) -> KnowledgeDocument {
    KnowledgeDocument(
      id: id,
      kind: kind,
      title: title,
      sourceByteCount: byteCount,
      importedAt: Date(timeIntervalSince1970: importedAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  private func result(
    document: KnowledgeDocument,
    ordinal: Int,
    signals: Set<KnowledgeRetrievalSignal>
  ) -> KnowledgeSearchResult {
    KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: ordinal,
        content: document.title,
        tokenEstimate: 1,
        contentHash: "chunk-\(ordinal)-\(document.id.uuidString)"
      ),
      score: 1,
      signals: signals
    )
  }
}
