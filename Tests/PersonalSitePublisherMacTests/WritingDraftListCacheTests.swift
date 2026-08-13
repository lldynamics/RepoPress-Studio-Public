import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WritingDraftListCacheTests: XCTestCase {
  func testRowPresentationKeyIgnoresBodyText() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "性能测试",
      slug: "performance-test",
      bodyMarkdown: "短正文"
    )
    let display = PrivateContentDisplay(
      title: draft.title,
      summary: draft.summary,
      isMasked: false
    )

    let before = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )
    draft.bodyMarkdown = String(repeating: "正文 ", count: 10_000)
    let after = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )

    XCTAssertEqual(before, after)
  }

  func testRowPresentationKeyTracksRenderedFieldChanges() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "性能测试",
      slug: "performance-test"
    )
    let display = PrivateContentDisplay(
      title: draft.title,
      summary: draft.summary,
      isMasked: false
    )
    let original = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )

    draft.updatedAt = draft.updatedAt.addingTimeInterval(1)
    let updated = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )

    XCTAssertNotEqual(original, updated)
  }

  func testCacheBuildsOnlyVisiblePageAndReusesBodyOnlyRows() {
    let profile = SiteProfile.defaultProfile
    let drafts = (0..<10_000).map { index in
      ArticleDraft(
        siteProfileID: profile.id,
        title: "性能测试 \(index)",
        slug: "performance-test-\(index)"
      )
    }
    var cache = WritingDraftListCache()
    let pageSize = 36
    let display: (ArticleDraft) -> PrivateContentDisplay = { draft in
      PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }

    cache.updateRowPresentations(
      sourceDrafts: drafts,
      visibleDrafts: drafts.prefix(pageSize),
      profileFor: { _ in profile },
      displayFor: display
    )
    XCTAssertEqual(cache.rowPresentationBuildCount, pageSize)

    cache.updateRowPresentations(
      sourceDrafts: drafts,
      visibleDrafts: drafts.prefix(pageSize),
      profileFor: { _ in profile },
      displayFor: display
    )
    XCTAssertEqual(cache.rowPresentationBuildCount, pageSize)

    var bodyOnlyDrafts = drafts
    bodyOnlyDrafts[0].bodyMarkdown = String(repeating: "正文 ", count: 10_000)
    cache.updateRowPresentations(
      sourceDrafts: bodyOnlyDrafts,
      visibleDrafts: bodyOnlyDrafts.prefix(pageSize),
      profileFor: { _ in profile },
      displayFor: display
    )
    XCTAssertEqual(cache.rowPresentationBuildCount, pageSize)
  }

  func testCachePrunesDeletedRowsBeforeFillingNextPage() {
    let profile = SiteProfile.defaultProfile
    let drafts = (0..<72).map { index in
      ArticleDraft(
        siteProfileID: profile.id,
        title: "草稿 \(index)",
        slug: "draft-\(index)"
      )
    }
    var cache = WritingDraftListCache()
    let display: (ArticleDraft) -> PrivateContentDisplay = { draft in
      PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }

    cache.updateRowPresentations(
      sourceDrafts: drafts,
      visibleDrafts: drafts.prefix(36),
      profileFor: { _ in profile },
      displayFor: display
    )
    let deletedID = drafts[0].id
    let remaining = Array(drafts.dropFirst())
    cache.updateRowPresentations(
      sourceDrafts: remaining,
      visibleDrafts: remaining.prefix(36),
      profileFor: { _ in profile },
      displayFor: display
    )

    XCTAssertNil(cache.rowPresentations[deletedID])
    XCTAssertEqual(cache.rowPresentationBuildCount, 37)
  }
}
