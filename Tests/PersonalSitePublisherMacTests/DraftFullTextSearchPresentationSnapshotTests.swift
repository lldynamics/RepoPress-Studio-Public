import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class DraftFullTextSearchPresentationSnapshotTests: XCTestCase {
  func testSnapshotGroupsInterleavedHitsInStableFirstSeenOrder() {
    let firstDraftID = UUID()
    let secondDraftID = UUID()
    let firstTitleHit = makeHit(
      draftID: firstDraftID,
      title: "第一篇",
      field: .title,
      location: 0
    )
    let secondBodyHit = makeHit(
      draftID: secondDraftID,
      title: "第二篇",
      field: .body,
      location: 8
    )
    let firstBodyHit = makeHit(
      draftID: firstDraftID,
      title: "第一篇",
      field: .body,
      location: 21
    )

    let snapshot = DraftFullTextSearchPresentationSnapshot(
      hits: [firstTitleHit, secondBodyHit, firstBodyHit]
    )

    XCTAssertEqual(snapshot.groups.map(\.draftID), [firstDraftID, secondDraftID])
    XCTAssertEqual(snapshot.groups.map(\.hits.count), [2, 1])
    XCTAssertEqual(
      snapshot.displayedHits.map(\.id),
      [firstTitleHit.id, firstBodyHit.id, secondBodyHit.id]
    )
  }

  func testSnapshotIndexesKeyboardNavigationAndSelectionWithoutRegrouping() {
    let draftID = UUID()
    let hits = [
      makeHit(draftID: draftID, title: "文章", field: .title, location: 0),
      makeHit(draftID: draftID, title: "文章", field: .summary, location: 4),
      makeHit(draftID: draftID, title: "文章", field: .body, location: 12),
    ]
    let snapshot = DraftFullTextSearchPresentationSnapshot(hits: hits)

    XCTAssertEqual(snapshot.index(of: hits[1].id), 1)
    XCTAssertEqual(snapshot.hit(withID: hits[2].id), hits[2])
    XCTAssertNil(
      snapshot.hit(
        withID: DraftFullTextSearchHitID(
          draftID: UUID(),
          field: .body,
          location: 0
        )
      )
    )
  }

  func testPreparationUsesLiveBodyAndMasksPrivateDraftContentOffProjectionPath() {
    let privateDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "私密文章",
      slug: "private",
      tags: ["secret"],
      visibility: .private,
      summary: "私密摘要",
      bodyMarkdown: "私密正文"
    )
    let input = DraftFullTextSearchInput(
      draft: privateDraft,
      bodyMarkdown: "最新正文"
    )

    let prepared = DraftFullTextSearchPreparation.prepare(
      inputs: [input],
      masksPrivateContent: true
    )

    XCTAssertEqual(prepared.count, 1)
    XCTAssertEqual(prepared[0].title, "私密文章")
    XCTAssertTrue(prepared[0].bodyMarkdown.isEmpty)
    XCTAssertTrue(prepared[0].tags.isEmpty)
    XCTAssertTrue(prepared[0].summary.isEmpty)

    let unmasked = DraftFullTextSearchPreparation.prepare(
      inputs: [input],
      masksPrivateContent: false
    )
    XCTAssertEqual(unmasked[0].bodyMarkdown, "最新正文")
    XCTAssertEqual(unmasked[0].slug, "private")
  }

  private func makeHit(
    draftID: UUID,
    title: String,
    field: DraftFullTextSearchField,
    location: Int
  ) -> DraftFullTextSearchHit {
    DraftFullTextSearchHit(
      draftID: draftID,
      siteProfileID: UUID(),
      draftTitle: title,
      field: field,
      sourceRange: NSRange(location: location, length: 2),
      snippetPrefix: "前",
      matchedText: "命中",
      snippetSuffix: "后",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      score: 10
    )
  }
}
