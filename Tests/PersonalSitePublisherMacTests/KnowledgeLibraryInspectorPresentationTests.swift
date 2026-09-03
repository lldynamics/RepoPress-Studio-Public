import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeLibraryInspectorPresentationTests: XCTestCase {
  func testMetadataAndHistoryRequestsKeepTheirOriginalDocumentTargets() throws {
    let first = KnowledgeDocument(kind: .article, title: "第一篇")
    let second = KnowledgeDocument(kind: .webpage, title: "第二篇")
    var presentation = KnowledgeLibraryInspectorPresentationState()

    presentation.editMetadata(for: first)
    presentation.openSourceHistory(
      for: second.id,
      preparesLocalRepairOnAppear: true
    )

    XCTAssertEqual(presentation.metadataDocument?.id, first.id)
    let history = try XCTUnwrap(presentation.sourceHistory)
    XCTAssertEqual(history.documentID, second.id)
    XCTAssertTrue(history.preparesLocalRepairOnAppear)
  }

  func testAnnotationRequestsUseTheSelectedRevisionAndSearchLocation() throws {
    let revisionID = UUID()
    let document = KnowledgeDocument(
      kind: .article,
      title: "可批注资料",
      currentRevisionID: revisionID
    )
    let chunk = KnowledgeChunk(
      documentID: document.id,
      revisionID: revisionID,
      ordinal: 0,
      headingPath: "第二章",
      locator: "段落 8",
      content: "搜索命中的正文",
      tokenEstimate: 20,
      contentHash: "search-hit"
    )
    let result = KnowledgeSearchResult(
      document: document,
      chunk: chunk,
      score: 1,
      signals: [.fullText]
    )
    var presentation = KnowledgeLibraryInspectorPresentationState()

    presentation.addAnnotation(to: document)
    XCTAssertEqual(presentation.annotationDraft?.revisionID, revisionID)
    XCTAssertNil(presentation.annotationDraft?.chunkID)

    presentation.annotateSearchResult(result, in: document)
    let annotation = try XCTUnwrap(presentation.annotationDraft)
    XCTAssertEqual(annotation.documentID, document.id)
    XCTAssertEqual(annotation.revisionID, revisionID)
    XCTAssertEqual(annotation.chunkID, chunk.id)
    XCTAssertEqual(annotation.locator, "段落 8")
    XCTAssertEqual(annotation.highlightedText, "搜索命中的正文")
  }
}
