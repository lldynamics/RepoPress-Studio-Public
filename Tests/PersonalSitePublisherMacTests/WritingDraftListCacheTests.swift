import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WritingDraftListCacheTests: XCTestCase {
  func testRowPresentationKeyIgnoresBodyTextUntilPersistedCountChanges() {
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

    XCTAssertTrue(draft.storeWordCount(10_000, for: draft.bodyMarkdown))
    let refreshed = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )
    XCTAssertNotEqual(after, refreshed)
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

  func testFolderCacheReusesProjectionLookupAndFlattenedEntries() {
    let profile = folderCacheProfile()
    let drafts = folderCacheDrafts(profileID: profile.id)
    var cache = WritingDraftListCache()
    let draftIDs = Set(drafts.map(\.id))

    cache.updateFolderProjectionCache(
      presentationRevision: 1,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      query: "",
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [],
      loadedDraftIDs: draftIDs
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)
    XCTAssertEqual(Set(cache.folderDraftsByID.keys), draftIDs)

    cache.updateFolderProjectionCache(
      presentationRevision: 1,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      query: "",
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [],
      loadedDraftIDs: draftIDs
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)
  }

  func testFolderCacheInvalidatesByQuerySortSiteRevisionExpansionAndPage() {
    let profile = folderCacheProfile()
    let drafts = folderCacheDrafts(profileID: profile.id)
    var cache = WritingDraftListCache()
    let draftIDs = Set(drafts.map(\.id))
    let initialSort: DraftListSortOrder = .updatedNewest

    func update(
      _ cache: inout WritingDraftListCache,
      revision: UInt64,
      profile: SiteProfile,
      query: String,
      sortOrder: DraftListSortOrder
    ) {
      cache.updateFolderProjectionCache(
        presentationRevision: revision,
        profile: profile,
        universeDrafts: drafts,
        filteredDrafts: drafts,
        query: query,
        sortOrder: sortOrder,
        maskedDraftIDs: []
      )
    }

    update(&cache, revision: 1, profile: profile, query: "", sortOrder: initialSort)
    cache.updateFolderEntriesCache(expandedFolderIDs: [], loadedDraftIDs: draftIDs)
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)

    update(&cache, revision: 1, profile: profile, query: "文章", sortOrder: initialSort)
    XCTAssertEqual(cache.folderProjectionBuildCount, 3)
    cache.updateFolderEntriesCache(expandedFolderIDs: [], loadedDraftIDs: draftIDs)
    XCTAssertEqual(cache.folderEntriesBuildCount, 2)

    update(&cache, revision: 1, profile: profile, query: "文章", sortOrder: .titleAscending)
    XCTAssertEqual(cache.folderProjectionBuildCount, 5)

    var changedProfile = profile
    changedProfile.contentRoot = "site-content"
    update(
      &cache,
      revision: 1,
      profile: changedProfile,
      query: "文章",
      sortOrder: .titleAscending
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 7)

    update(
      &cache,
      revision: 2,
      profile: changedProfile,
      query: "文章",
      sortOrder: .titleAscending
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 9)

    let folderID = cache.filteredFolderProjection!.root.allFolderIDs[0]
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [folderID],
      loadedDraftIDs: draftIDs
    )
    XCTAssertEqual(cache.folderEntriesBuildCount, 3)
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [folderID],
      loadedDraftIDs: [drafts[0].id]
    )
    XCTAssertEqual(cache.folderEntriesBuildCount, 4)
  }

  private func folderCacheProfile() -> SiteProfile {
    SiteProfile(
      id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
      name: "缓存测试站点",
      contentRoot: "content",
      markdownPathPattern: "content/posts/{slug}.md"
    )
  }

  private func folderCacheDrafts(profileID: UUID) -> [ArticleDraft] {
    [
      ArticleDraft(
        id: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
        siteProfileID: profileID,
        title: "文章 A",
        slug: "2025/文章-a",
        updatedAt: Date(timeIntervalSince1970: 100)
      ),
      ArticleDraft(
        id: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
        siteProfileID: profileID,
        title: "文章 B",
        slug: "2026/文章-b",
        updatedAt: Date(timeIntervalSince1970: 200)
      ),
    ]
  }
}
