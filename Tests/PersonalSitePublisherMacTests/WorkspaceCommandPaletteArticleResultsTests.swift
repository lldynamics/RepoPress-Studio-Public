import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceCommandPaletteArticleResultsTests: XCTestCase {
  func testViewAllPreservesDistinctBodyLocationsAndKeyboardOrder() {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "文章", bodyMarkdown: "")
    let hits = (0..<15).map { index in
      DraftFullTextSearchHit(
        draftID: draft.id, siteProfileID: draft.siteProfileID, draftTitle: draft.title,
        field: .body, sourceRange: NSRange(location: index * 10, length: 2),
        snippetPrefix: "", matchedText: "命中", snippetSuffix: "", updatedAt: draft.updatedAt,
        score: 1
      )
    }
    let visible = WorkspacePaletteArticleResultPresentation.visibleHits(from: hits, showsAll: false)
    let expanded = WorkspacePaletteArticleResultPresentation.visibleHits(from: hits, showsAll: true)

    XCTAssertEqual(visible.map(\.id), Array(hits.prefix(12)).map(\.id))
    XCTAssertEqual(expanded.map(\.id), hits.map(\.id))
    XCTAssertEqual(Set(expanded.map(\.id)).count, 15)
  }

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
