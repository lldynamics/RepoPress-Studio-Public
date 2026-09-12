import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceCommandPaletteArticleResultsTests: XCTestCase {
  func testViewAllRemovesOnlyThePresentationCapForKeyboardNavigation() {
    let profileID = UUID()
    let drafts = (0..<15).map { index in
      ArticleDraft(siteProfileID: profileID, title: "文章 \(index)")
    }

    let visible = WorkspacePaletteArticleResultPresentation.visibleDrafts(
      from: drafts,
      showsAll: false
    )
    let all = WorkspacePaletteArticleResultPresentation.visibleDrafts(
      from: drafts,
      showsAll: true
    )

    XCTAssertEqual(
      visible.count,
      WorkspacePaletteArticleResultPresentation.defaultVisibleResultLimit
    )
    XCTAssertTrue(
      WorkspacePaletteArticleResultPresentation.shouldOfferViewAll(
        visibleCount: visible.count,
        resultCount: drafts.count
      )
    )
    XCTAssertEqual(all.map(\.id), drafts.map(\.id))
    XCTAssertFalse(
      WorkspacePaletteArticleResultPresentation.shouldOfferViewAll(
        visibleCount: all.count,
        resultCount: drafts.count
      )
    )
  }
}
