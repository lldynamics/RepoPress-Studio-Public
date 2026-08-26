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

  func testRowPresentationKeyUsesMetadataTimeInsteadOfBodyWriteTime() {
    let profile = SiteProfile.defaultProfile
    let timestamp = Date(timeIntervalSince1970: 100)
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "性能测试",
      slug: "performance-test",
      updatedAt: timestamp,
      metadataUpdatedAt: timestamp
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
    let bodyWrite = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )
    XCTAssertEqual(original, bodyWrite)

    draft.markMetadataUpdated(at: draft.updatedAt.addingTimeInterval(1))
    let metadataUpdate = WritingDraftRowPresentationCacheKey(
      draft: draft,
      profile: profile,
      display: display
    )
    XCTAssertNotEqual(bodyWrite, metadataUpdate)
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
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [],
      loadedDraftIDs: draftIDs
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
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

  func testFolderCacheInvalidatesOnlyByTopologyMembershipAndOrderingInputs() {
    let profile = folderCacheProfile()
    let drafts = folderCacheDrafts(profileID: profile.id)
    var cache = WritingDraftListCache()
    let draftIDs = Set(drafts.map(\.id))
    let initialSort: DraftListSortOrder = .updatedNewest

    func update(
      _ cache: inout WritingDraftListCache,
      profile: SiteProfile,
      universeDrafts: [ArticleDraft],
      filteredDrafts: [ArticleDraft],
      sortOrder: DraftListSortOrder
    ) {
      cache.updateFolderProjectionCache(
        profile: profile,
        universeDrafts: universeDrafts,
        filteredDrafts: filteredDrafts,
        sortOrder: sortOrder,
        maskedDraftIDs: [],
        universeSourceRevision: 1
      )
    }

    update(
      &cache,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: initialSort
    )
    cache.updateFolderEntriesCache(expandedFolderIDs: [], loadedDraftIDs: draftIDs)
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)

    // The query is intentionally not part of the projection API. Reusing the
    // same matched IDs leaves both topology layers warm.
    update(
      &cache,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: initialSort
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
    cache.updateFolderEntriesCache(expandedFolderIDs: [], loadedDraftIDs: draftIDs)
    XCTAssertEqual(cache.folderEntriesBuildCount, 1)

    // Filter membership changes rebuild only the filtered projection.
    update(
      &cache,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: [drafts[0]],
      sortOrder: initialSort
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 3)

    update(
      &cache,
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: [drafts[0]],
      sortOrder: .titleAscending
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 5)

    var changedProfile = profile
    changedProfile.contentRoot = "site-content"
    update(
      &cache,
      profile: changedProfile,
      universeDrafts: drafts,
      filteredDrafts: [drafts[0]],
      sortOrder: .titleAscending
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 7)

    let folderID = cache.filteredFolderProjection!.root.allFolderIDs[0]
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [folderID],
      loadedDraftIDs: draftIDs
    )
    XCTAssertEqual(cache.folderEntriesBuildCount, 2)
    cache.updateFolderEntriesCache(
      expandedFolderIDs: [folderID],
      loadedDraftIDs: [drafts[0].id]
    )
    XCTAssertEqual(cache.folderEntriesBuildCount, 3)
  }

  func testFolderCacheIgnoresBodyContentTimestampAndUnrelatedMetadata() {
    let profile = folderCacheProfile()
    let drafts = (0..<10_000).map { index in
      let timestamp = Date(timeIntervalSince1970: TimeInterval(index))
      return ArticleDraft(
        siteProfileID: profile.id,
        title: "性能文章 \(index)",
        slug: "2025/性能文章-\(index)",
        updatedAt: timestamp,
        metadataUpdatedAt: timestamp
      )
    }
    var cache = WritingDraftListCache()

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)

    var bodyOnlyDrafts = drafts
    bodyOnlyDrafts[0].bodyMarkdown = String(repeating: "正文 ", count: 10_000)
    bodyOnlyDrafts[0].updatedAt = Date(timeIntervalSince1970: 9_999)
    bodyOnlyDrafts[0].summary = "正文摘要变化"
    bodyOnlyDrafts[0].categories = ["无关分类变化"]
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: bodyOnlyDrafts,
      filteredDrafts: bodyOnlyDrafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 2)
  }

  func testFolderCacheInvalidatesOnlyEffectiveAssignmentAndOrderingChanges() {
    let profile = folderCacheProfile()
    let drafts = folderCacheDrafts(profileID: profile.id)
    var cache = WritingDraftListCache()

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)

    var changed = drafts
    changed[0].slug = "2025/改名后的路径"
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    // The configured pattern keeps both slugs in `content/posts`, so changing
    // the slug does not change this projection's effective folder assignment.
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)

    changed[0].repositoryPath = "private/2025/文章-a.md"
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    // Materializing a public draft's repository path does not change its
    // effective folder assignment, so the projection stays warm.
    XCTAssertEqual(cache.folderProjectionBuildCount, 2)

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: [changed[0].id]
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 4)

    changed[0].assignToGeneralDraft(editingProfileID: profile.id)
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: [changed[0].id]
    )
    // A masked draft stays in the protected node regardless of ownership.
    XCTAssertEqual(cache.folderProjectionBuildCount, 4)

    changed[0].assignToSite(profile.id)
    changed[0].markMetadataUpdated(at: Date(timeIntervalSince1970: 300))
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 6)

    var changedProfile = profile
    changedProfile.markdownPathPattern = "content/articles/{slug}.md"
    cache.updateFolderProjectionCache(
      profile: changedProfile,
      universeDrafts: changed,
      filteredDrafts: changed,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, 8)
  }

  func testArticleDateFolderOrderingInvalidatesWhenTieBreakTitleChanges() throws {
    let profile = folderCacheProfile()
    let sharedDate = Date(timeIntervalSince1970: 100)
    var drafts = folderCacheDrafts(profileID: profile.id).map { draft in
      var sameDateDraft = draft
      sameDateDraft.date = sharedDate
      return sameDateDraft
    }
    drafts[0].title = "AAA"
    drafts[0].slug = "2025/a"
    drafts[1].title = "BBB"
    drafts[1].slug = "2025/b"
    var cache = WritingDraftListCache()

    func leafDraftOrder(in node: DraftFolderNode) -> [UUID]? {
      if node.draftIDs.count == drafts.count {
        return node.draftIDs
      }
      return node.children.lazy.compactMap(leafDraftOrder).first
    }

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .articleDateNewest,
      maskedDraftIDs: []
    )
    let originalOrder = try XCTUnwrap(
      cache.filteredFolderProjection.flatMap { leafDraftOrder(in: $0.root) }
    )

    drafts[0].title = "ZZZ"
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .articleDateNewest,
      maskedDraftIDs: []
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 4)
    let updatedOrder = try XCTUnwrap(
      cache.filteredFolderProjection.flatMap { leafDraftOrder(in: $0.root) }
    )
    XCTAssertEqual(originalOrder, [drafts[0].id, drafts[1].id])
    XCTAssertEqual(updatedOrder, [drafts[1].id, drafts[0].id])
  }

  func testUpdatedFolderOrderingInvalidatesWhenTieBreakTitleChanges() throws {
    let profile = folderCacheProfile()
    let sharedTimestamp = Date(timeIntervalSince1970: 100)
    var drafts = folderCacheDrafts(profileID: profile.id)
    drafts[0].title = "AAA"
    drafts[0].slug = "2025/a"
    drafts[0].markMetadataUpdated(at: sharedTimestamp)
    drafts[1].title = "BBB"
    drafts[1].slug = "2025/b"
    drafts[1].markMetadataUpdated(at: sharedTimestamp)
    var cache = WritingDraftListCache()

    func leafDraftOrder(in node: DraftFolderNode) -> [UUID]? {
      if node.draftIDs.count == drafts.count {
        return node.draftIDs
      }
      return node.children.lazy.compactMap(leafDraftOrder).first
    }

    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )
    let originalOrder = try XCTUnwrap(
      cache.filteredFolderProjection.flatMap { leafDraftOrder(in: $0.root) }
    )

    drafts[0].title = "ZZZ"
    cache.updateFolderProjectionCache(
      profile: profile,
      universeDrafts: drafts,
      filteredDrafts: drafts,
      sortOrder: .updatedNewest,
      maskedDraftIDs: []
    )

    XCTAssertEqual(cache.folderProjectionBuildCount, 4)
    let updatedOrder = try XCTUnwrap(
      cache.filteredFolderProjection.flatMap { leafDraftOrder(in: $0.root) }
    )
    XCTAssertEqual(originalOrder, [drafts[0].id, drafts[1].id])
    XCTAssertEqual(updatedOrder, [drafts[1].id, drafts[0].id])
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
        updatedAt: Date(timeIntervalSince1970: 100),
        metadataUpdatedAt: Date(timeIntervalSince1970: 100)
      ),
      ArticleDraft(
        id: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
        siteProfileID: profileID,
        title: "文章 B",
        slug: "2026/文章-b",
        updatedAt: Date(timeIntervalSince1970: 200),
        metadataUpdatedAt: Date(timeIntervalSince1970: 200)
      ),
    ]
  }
}
