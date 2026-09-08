import XCTest

@testable import PersonalSitePublisherMac

final class AssetReferenceRepairPreviewSelectionPolicyTests: XCTestCase {
  func testReplacingPreviewForSameDraftWithDifferentPathsRemovesPreviousPreviewAndSelection() {
    let existingID = UUID()
    let incomingID = UUID()
    let otherID = UUID()
    let sharedDraftID = UUID()
    let result = AssetReferenceRepairPreviewSelectionPolicy.replacing(
      preview: AssetReferenceRepairPreviewSelectionCandidate(
        id: incomingID, draftID: sharedDraftID, sourcePath: "content/posts/article-renamed.md"),
      existingPreviews: [
        AssetReferenceRepairPreviewSelectionCandidate(
          id: existingID, draftID: sharedDraftID, sourcePath: "content/posts/article.md"),
        AssetReferenceRepairPreviewSelectionCandidate(
          id: otherID, draftID: UUID(), sourcePath: "content/posts/other.md"),
      ],
      selectedPreviewIDs: [existingID, otherID]
    )

    XCTAssertEqual(result.removedPreviewIDs, [existingID])
    XCTAssertEqual(result.selectedPreviewIDs, [incomingID, otherID])
  }

  func testPreviewForDifferentDraftWithSameDisplayPathKeepsExistingBatchSelection() {
    let existingID = UUID()
    let incomingID = UUID()
    let result = AssetReferenceRepairPreviewSelectionPolicy.replacing(
      preview: AssetReferenceRepairPreviewSelectionCandidate(
        id: incomingID, draftID: UUID(), sourcePath: "content/posts/article.md"),
      existingPreviews: [
        AssetReferenceRepairPreviewSelectionCandidate(
          id: existingID, draftID: UUID(), sourcePath: "content/posts/article.md")
      ],
      selectedPreviewIDs: [existingID]
    )

    XCTAssertTrue(result.removedPreviewIDs.isEmpty)
    XCTAssertEqual(result.selectedPreviewIDs, [existingID, incomingID])
  }
}
