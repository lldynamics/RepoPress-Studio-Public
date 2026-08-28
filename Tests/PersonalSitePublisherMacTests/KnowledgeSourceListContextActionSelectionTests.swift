import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeSourceListContextActionSelectionTests: XCTestCase {
  func testSelectedContextDocumentTargetsEntireMultipleSelection() {
    let firstID = UUID()
    let secondID = UUID()
    let selectedDocumentIDs: Set<UUID> = [firstID, secondID]

    let documentIDs = KnowledgeSourceListContextActionSelection.documentIDs(
      contextDocumentID: secondID,
      selectedDocumentIDs: selectedDocumentIDs,
      isDocumentListSelectionActive: true
    )

    XCTAssertEqual(documentIDs, selectedDocumentIDs)
  }

  func testUnselectedContextDocumentTargetsOnlyContextDocument() {
    let firstID = UUID()
    let secondID = UUID()
    let contextDocumentID = UUID()

    let documentIDs = KnowledgeSourceListContextActionSelection.documentIDs(
      contextDocumentID: contextDocumentID,
      selectedDocumentIDs: [firstID, secondID],
      isDocumentListSelectionActive: true
    )

    XCTAssertEqual(documentIDs, [contextDocumentID])
  }

  func testContextDocumentTargetsItselfWhenSelectionIsEmpty() {
    let contextDocumentID = UUID()

    let documentIDs = KnowledgeSourceListContextActionSelection.documentIDs(
      contextDocumentID: contextDocumentID,
      selectedDocumentIDs: [],
      isDocumentListSelectionActive: true
    )

    XCTAssertEqual(documentIDs, [contextDocumentID])
  }

  func testSearchContextIgnoresStaleDocumentListSelection() {
    let contextDocumentID = UUID()
    let selectedDocumentIDs: Set<UUID> = [contextDocumentID, UUID()]

    let documentIDs = KnowledgeSourceListContextActionSelection.documentIDs(
      contextDocumentID: contextDocumentID,
      selectedDocumentIDs: selectedDocumentIDs,
      isDocumentListSelectionActive: false
    )

    XCTAssertEqual(documentIDs, [contextDocumentID])
  }
}
