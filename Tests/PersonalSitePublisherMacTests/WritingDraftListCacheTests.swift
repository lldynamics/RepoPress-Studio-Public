import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WritingDraftListCacheTests: XCTestCase {
  func testDraftListDateUsesTimeForTodayAndShortDateForOtherDays() {
    var calendar = Calendar(identifier: .gregorian)
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      XCTFail("UTC time zone unavailable")
      return
    }
    calendar.timeZone = utc
    let now = Date(timeIntervalSince1970: 1_758_780_000)
    let today = now.addingTimeInterval(-2 * 60 * 60)
    let previousDay = now.addingTimeInterval(-26 * 60 * 60)
    let fourDaysAgo = now.addingTimeInterval(-4 * 24 * 60 * 60)
    let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 60 * 60)
    var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
    weekday.calendar = calendar
    weekday.timeZone = utc

    XCTAssertEqual(
      writingDraftListDateText(today, now: now, calendar: calendar),
      today.formatted(date: .omitted, time: .shortened)
    )
    XCTAssertEqual(
      writingDraftListDateText(previousDay, now: now, calendar: calendar),
      String(localized: "昨天")
    )
    XCTAssertEqual(
      writingDraftListDateText(fourDaysAgo, now: now, calendar: calendar),
      fourDaysAgo.formatted(weekday)
    )
    XCTAssertEqual(
      writingDraftListDateText(twoWeeksAgo, now: now, calendar: calendar),
      twoWeeksAgo.formatted(date: .numeric, time: .omitted)
    )
  }

  func testDraftRowsKeepNeutralStatusForAccessibilityWithoutDuplicateIcons() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Plain draft", status: .draft)
    let presentation = WritingDraftRowPresentation(
      draft: draft,
      profile: profile,
      display: PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    )

    XCTAssertEqual(presentation.metadataDetails, "")
    XCTAssertEqual(presentation.metadata, presentation.metadataDate)
    XCTAssertEqual(presentation.statusTags, [.draft])
    XCTAssertEqual(presentation.metadataSymbolRole, .neutral)
    XCTAssertTrue(presentation.help.contains(DraftStatus.draft.localizedDisplayName))
  }

  func testRowPresentationKeepsStatusAndFullDateInSeparateMetadataFields() {
    let profile = SiteProfile.defaultProfile
    let metadataUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "English article title",
      slug: "english-article",
      draft: false,
      visibility: .private,
      status: .ready,
      metadataUpdatedAt: metadataUpdatedAt
    )
    let display = PrivateContentDisplay(
      title: draft.title,
      summary: draft.summary,
      isMasked: false
    )

    let presentation = WritingDraftRowPresentation(
      draft: draft,
      profile: profile,
      display: display
    )

    XCTAssertEqual(presentation.metadataDetails, "")
    XCTAssertEqual(presentation.statusTags, [.ready])
    XCTAssertEqual(
      presentation.metadataDate,
      writingDraftListDateText(metadataUpdatedAt)
    )
    XCTAssertEqual(presentation.metadata, presentation.metadataDate)
  }

  func testRowAttentionShowsIssuesAndSyncAndInvalidatesTheCacheKey() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Needs work", status: .draft)
    let display = PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    let attention = WritingDraftRowAttention(articleIssueCount: 2, needsSync: true)

    let presentation = WritingDraftRowPresentation(
      draft: draft, profile: profile, display: display, attention: attention
    )

    XCTAssertEqual(presentation.issueSummary, String(localized: "\(2) 项问题"))
    XCTAssertEqual(presentation.metadataDetails, "")
    XCTAssertEqual(presentation.statusTags, [.draft, .unsynced, .alerts(2)])
    XCTAssertTrue(presentation.help.contains(String(localized: "同步异常")))
    XCTAssertTrue(presentation.statusSummary.hasPrefix(String(localized: "\(2) 项问题")))
    XCTAssertEqual(presentation.metadataSymbolRole, .warning)
    XCTAssertNotEqual(
      WritingDraftRowPresentationCacheKey(draft: draft, profile: profile, display: display),
      WritingDraftRowPresentationCacheKey(
        draft: draft, profile: profile, display: display, attention: attention)
    )
  }

  func testCompactPrivateRowKeepsAttentionAndDoesNotExposeMaskedContent() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id, title: "Secret title", slug: "secret-path", draft: false,
      visibility: .private, status: .ready
    )
    let display = PrivateContentDisplay(
      title: "Masked title", summary: "Masked summary", isMasked: true)
    let presentation = WritingDraftRowPresentation(
      draft: draft, profile: profile, display: display,
      attention: WritingDraftRowAttention(articleIssueCount: 2, needsSync: true)
    )

    XCTAssertEqual(presentation.title, display.title)
    XCTAssertEqual(presentation.privacySystemImage, "lock.shield.fill")
    XCTAssertTrue(presentation.statusSummary.hasPrefix(String(localized: "\(2) 项问题")))
    XCTAssertTrue(presentation.statusSummary.contains(String(localized: "同步异常")))
    XCTAssertTrue(presentation.statusSummary.contains(DraftStatus.ready.localizedDisplayName))
    XCTAssertFalse(presentation.statusSummary.contains(draft.visibility.localizedDisplayName))
    XCTAssertFalse(presentation.help.contains(draft.title))
    XCTAssertFalse(presentation.help.contains(draft.slug))
    XCTAssertTrue(presentation.help.contains(display.summary))
  }

  func testOrdinaryPublishedRowIsNeutralAndPublishFailureStaysProminent() {
    let profile = SiteProfile.defaultProfile
    for status in [DraftStatus.draft, .ready, .published, .failed] {
      let draft = ArticleDraft(
        siteProfileID: profile.id, title: "Article", draft: status == .draft, status: status)
      let presentation = WritingDraftRowPresentation(
        draft: draft, profile: profile,
        display: PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
      )
      XCTAssertNil(presentation.privacySystemImage)
      XCTAssertEqual(
        presentation.statusSummary,
        status == .failed
          ? String(localized: "发布失败") + " · " + ArticleState.ready.displayName
          : draft.articleState.displayName
      )
      XCTAssertEqual(presentation.metadataSymbolRole, status == .failed ? .failed : .neutral)
      XCTAssertTrue(presentation.help.contains(draft.articleState.displayName))
    }
  }

  func testPrivatePublishedArticlesUsePublishedFilterAndKeepTheirLock() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id, title: "Private published article", draft: false,
      visibility: .private, status: .published
    )
    XCTAssertTrue(DraftListFilter.published.matches(draft, taskState: nil))
    XCTAssertTrue(DraftListFilter.privateArticles.matches(draft, taskState: nil))
    XCTAssertFalse(DraftListFilter.ready.matches(draft, taskState: nil))
    for masked in [false, true] {
      let row = WritingDraftRowPresentation(
        draft: draft, profile: profile,
        display: PrivateContentDisplay(title: "Visible title", summary: "", isMasked: masked)
      )
      XCTAssertEqual(row.statusTags, [.published])
      XCTAssertEqual(row.privacySystemImage, masked ? "lock.shield.fill" : "lock.fill")
    }
  }

  func testPublishFailureRemainsFirstWhenChecksAndSyncAlsoNeedAttention() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Failed article", status: .failed)
    let presentation = WritingDraftRowPresentation(
      draft: draft, profile: profile,
      display: PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false),
      attention: WritingDraftRowAttention(articleIssueCount: 12, needsSync: true)
    )
    XCTAssertTrue(presentation.statusSummary.hasPrefix(String(localized: "发布失败")))
    XCTAssertEqual(presentation.metadataSymbolRole, .failed)
    XCTAssertTrue(presentation.statusSummary.contains(String(localized: "\(12) 项问题")))
    XCTAssertTrue(presentation.help.contains(String(localized: "同步异常")))
  }

  func testOnlyFailedOrDivergedRepositoryStatesNeedAttention() {
    XCTAssertFalse(WritingDraftRowAttention.syncNeedsAttention(.localChanged))
    XCTAssertTrue(WritingDraftRowAttention.syncNeedsAttention(.diverged))
    XCTAssertTrue(WritingDraftRowAttention.syncNeedsAttention(.failed))
    XCTAssertFalse(WritingDraftRowAttention.syncNeedsAttention(.localOnly))
    XCTAssertFalse(WritingDraftRowAttention.syncNeedsAttention(.projectSaved))
    XCTAssertFalse(WritingDraftRowAttention.syncNeedsAttention(.synced))
    XCTAssertFalse(WritingDraftRowAttention.syncNeedsAttention(.awaitingReview))
  }

  func testStateFilterAndCacheFollowDraftFlagAndGeneralScope() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(siteProfileID: profile.id, title: "State projection", status: .ready)
    let display = PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    let before = WritingDraftRowPresentationCacheKey(
      draft: draft, profile: profile, display: display)
    XCTAssertTrue(DraftListFilter.draft.matches(draft, taskState: nil))
    XCTAssertFalse(DraftListFilter.ready.matches(draft, taskState: nil))
    draft.draft = false
    XCTAssertTrue(DraftListFilter.ready.matches(draft, taskState: nil))
    XCTAssertNotEqual(
      before, WritingDraftRowPresentationCacheKey(draft: draft, profile: profile, display: display))
    draft.assignToGeneralDraft()
    XCTAssertTrue(DraftListFilter.localOnly.matches(draft, taskState: nil))
    XCTAssertFalse(DraftListFilter.draft.matches(draft, taskState: nil))
    let row = WritingDraftRowPresentation(draft: draft, profile: profile, display: display)
    XCTAssertEqual(row.statusSummary, ArticleState.localOnly.displayName)
    XCTAssertEqual(row.statusTags, [.localOnly])
  }

  func testRecencySectionsFollowListOrderAndKeepPagingIndices() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    let now = Date(timeIntervalSince1970: 1_758_780_000)
    let profile = SiteProfile.defaultProfile
    func draft(_ title: String, daysAgo: Double) -> ArticleDraft {
      ArticleDraft(
        siteProfileID: profile.id, title: title,
        metadataUpdatedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60 - 60)
      )
    }
    let drafts = [
      draft("a", daysAgo: 0), draft("b", daysAgo: 0), draft("c", daysAgo: 3),
      draft("d", daysAgo: 30),
    ]

    let sections = WritingDraftRecencyGroup.sections(for: drafts, now: now, calendar: calendar)

    XCTAssertEqual(sections.map(\.group), [.today, .thisWeek, .earlier])
    XCTAssertEqual(sections.map { $0.rows.map(\.index) }, [[0, 1], [2], [3]])
    XCTAssertEqual(
      WritingDraftRecencyGroup(
        date: now.addingTimeInterval(3 * 24 * 60 * 60), now: now, calendar: calendar),
      .future
    )
    XCTAssertEqual(
      WritingDraftRecencyGroup.sections(for: drafts.reversed(), now: now, calendar: calendar)
        .map(\.group),
      [.earlier, .thisWeek, .today]
    )
  }

  func testGeneralFolderMoveInvalidatesCachedTree() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id, scope: .general, title: "General"
    )
    var cache = WritingDraftListCache()
    cache.updateFolderProjectionCache(
      profile: profile, contentScope: .general,
      universeDrafts: [draft], filteredDrafts: [draft],
      sortOrder: .updatedNewest, maskedDraftIDs: []
    )
    XCTAssertEqual(cache.filteredFolderProjection?.root.children.map(\.kind), [.unfiled])
    let initialBuildCount = cache.folderProjectionBuildCount

    XCTAssertTrue(draft.setGeneralDraftFolderName("Research"))
    cache.updateFolderProjectionCache(
      profile: profile, contentScope: .general,
      universeDrafts: [draft], filteredDrafts: [draft],
      sortOrder: .updatedNewest, maskedDraftIDs: []
    )
    XCTAssertEqual(cache.folderProjectionBuildCount, initialBuildCount + 2)
    XCTAssertEqual(cache.filteredFolderProjection?.root.children.map(\.name), ["Research"])
  }

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
