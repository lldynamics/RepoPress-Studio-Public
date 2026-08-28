import Foundation
import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceQuickSearchPresentationTests: XCTestCase {
  func testImageWorkspaceUsesImageResourcesTitleBeforeSearching() {
    XCTAssertEqual(
      WorkspaceQuickSearchPresentation.resultSectionTitle(
        query: "",
        scope: .imageResources
      ),
      "图片资源"
    )
    XCTAssertEqual(
      WorkspaceQuickSearchPresentation.resultSectionTitle(
        query: "",
        scope: .recent
      ),
      "最近变更"
    )
    XCTAssertEqual(
      WorkspaceQuickSearchPresentation.resultSectionTitle(
        query: "  图片  ",
        scope: .imageResources
      ),
      "搜索结果"
    )
  }

  func testContentHealthWorkspaceUsesAIFixableTitleBeforeSearching() {
    XCTAssertEqual(
      WorkspaceQuickSearchPresentation.resultSectionTitle(
        query: "",
        scope: .aiFixes
      ),
      "AI 可修复"
    )
    XCTAssertEqual(
      WorkspaceQuickSearchPresentation.resultSectionTitle(
        query: "  摘要  ",
        scope: .aiFixes
      ),
      "搜索结果"
    )
  }

  func testContentHealthSidebarProjectionKeepsAIFixDraftsScopedToProfile() async {
    await MainActor.run {
      let projection = ContentHealthSidebarProjection()
      let profileID = UUID()
      let draftID = UUID()
      projection.replace(
        profileID: profileID,
        aiFixQueueItems: [Self.fixItem(id: "ai-fix", draftID: draftID)]
      )

      XCTAssertEqual(projection.aiFixDraftIDs(for: profileID), [draftID])
      XCTAssertEqual(projection.queueState(for: profileID), .ready([draftID]))
      XCTAssertNil(projection.aiFixDraftIDs(for: UUID()))
      XCTAssertEqual(projection.queueState(for: UUID()), .loading)
    }
  }

  func testContentHealthSidebarProjectionDistinguishesLoadingEmptyAndFailure() async {
    await MainActor.run {
      let projection = ContentHealthSidebarProjection()
      let profileID = UUID()

      XCTAssertEqual(projection.queueState(for: profileID), .loading)

      projection.beginLoading(profileID: profileID)
      XCTAssertEqual(projection.queueState(for: profileID), .loading)
      XCTAssertNil(projection.aiFixDraftIDs(for: profileID))

      projection.replace(profileID: profileID, aiFixQueueItems: [])
      XCTAssertEqual(projection.queueState(for: profileID), .ready([]))
      XCTAssertEqual(projection.aiFixDraftIDs(for: profileID), [])

      projection.markFailed(profileID: profileID)
      XCTAssertEqual(projection.queueState(for: profileID), .failed)
      XCTAssertNil(projection.aiFixDraftIDs(for: profileID))
    }
  }

  func testContentHealthSidebarProjectionPreservesQueueOrderAndRemovesDuplicates() async {
    await MainActor.run {
      let projection = ContentHealthSidebarProjection()
      let profileID = UUID()
      let highPriorityDraftID = UUID()
      let lowPriorityDraftID = UUID()
      projection.replace(
        profileID: profileID,
        aiFixQueueItems: [
          Self.fixItem(id: "high", draftID: highPriorityDraftID, priority: .high),
          Self.fixItem(id: "low", draftID: lowPriorityDraftID, priority: .low),
          Self.fixItem(id: "duplicate", draftID: highPriorityDraftID, priority: .low),
        ]
      )

      XCTAssertEqual(
        projection.queueState(for: profileID),
        .ready([highPriorityDraftID, lowPriorityDraftID])
      )
    }
  }

  func testEmptyAIFixScopeDoesNotFallBackToRecentDrafts() {
    let profileID = UUID()
    let recentDraft = ArticleDraft(siteProfileID: profileID, title: "Recent")

    XCTAssertTrue(
      WorkspaceQuickSearchPresentation.scopedDrafts(
        [recentDraft],
        includedDraftIDs: []
      ).isEmpty
    )
  }

  func testAIFixQueueUsesPriorityOrderInsteadOfRecentUpdateOrder() {
    let profileID = UUID()
    let olderHighPriorityDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "Older High Priority",
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newerLowPriorityDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "Newer Low Priority",
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let preferredDraftIDs = [olderHighPriorityDraft.id, newerLowPriorityDraft.id]
    let scopedDrafts = WorkspaceQuickSearchPresentation.scopedDrafts(
      [newerLowPriorityDraft, olderHighPriorityDraft],
      includedDraftIDs: Set(preferredDraftIDs)
    )

    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: scopedDrafts,
      query: "",
      preferredDraftIDs: preferredDraftIDs
    ) { _, _ in
      XCTFail("An empty query must not invoke the matcher.")
      return false
    }

    XCTAssertEqual(matches.map(\.id), preferredDraftIDs)
  }

  func testAIFixSearchStaysInsideQueueAndPreservesPriorityOrder() {
    let profileID = UUID()
    let firstQueueDraft = ArticleDraft(siteProfileID: profileID, title: "First Match")
    let secondQueueDraft = ArticleDraft(siteProfileID: profileID, title: "Second Match")
    let unrelatedRecentDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "Unrelated Match",
      updatedAt: Date.distantFuture
    )
    let preferredDraftIDs = [firstQueueDraft.id, secondQueueDraft.id]
    let scopedDrafts = WorkspaceQuickSearchPresentation.scopedDrafts(
      [unrelatedRecentDraft, secondQueueDraft, firstQueueDraft],
      includedDraftIDs: Set(preferredDraftIDs)
    )

    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: scopedDrafts,
      query: "Match",
      preferredDraftIDs: preferredDraftIDs
    ) { draft, query in
      draft.title.localizedCaseInsensitiveContains(query)
    }

    XCTAssertEqual(matches.map(\.id), preferredDraftIDs)
    XCTAssertFalse(matches.contains { $0.id == unrelatedRecentDraft.id })
  }

  func testEmptyQueryOrdersRecentDraftsAndCapsSidebarResults() {
    let profileID = UUID()
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let drafts = (0..<20).map { index in
      ArticleDraft(
        siteProfileID: profileID,
        title: "Article \(index)",
        updatedAt: baseDate.addingTimeInterval(TimeInterval(index))
      )
    }

    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: drafts,
      query: ""
    ) { _, _ in
      XCTFail("An empty query must not invoke the matcher.")
      return false
    }
    let visible = WorkspaceQuickSearchPresentation.visibleDrafts(
      from: matches,
      query: ""
    )

    XCTAssertEqual(matches.first?.title, "Article 19")
    XCTAssertEqual(matches.last?.title, "Article 0")
    XCTAssertEqual(visible.count, WorkspaceQuickSearchPresentation.recentResultLimit)
  }

  func testRecentOrderIgnoresBodyOnlyContentTimestamp() {
    let profileID = UUID()
    let metadataOlder = ArticleDraft(
      siteProfileID: profileID,
      title: "Metadata Older",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      metadataUpdatedAt: Date(timeIntervalSince1970: 100)
    )
    let metadataNewer = ArticleDraft(
      siteProfileID: profileID,
      title: "Metadata Newer",
      updatedAt: Date(timeIntervalSince1970: 200),
      metadataUpdatedAt: Date(timeIntervalSince1970: 200)
    )

    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: [metadataOlder, metadataNewer],
      query: ""
    ) { _, _ in
      XCTFail("An empty query must not invoke the matcher.")
      return false
    }

    XCTAssertEqual(matches.map(\.id), [metadataNewer.id, metadataOlder.id])
  }

  func testSearchTrimsQueryFiltersAndPreservesRecentOrder() {
    let profileID = UUID()
    let older = ArticleDraft(
      siteProfileID: profileID,
      title: "Older Match",
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newer = ArticleDraft(
      siteProfileID: profileID,
      title: "Newer Match",
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let unrelated = ArticleDraft(
      siteProfileID: profileID,
      title: "Unrelated",
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    var receivedQueries: [String] = []

    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: [older, newer, unrelated],
      query: "  Match  "
    ) { draft, query in
      receivedQueries.append(query)
      return draft.title.localizedCaseInsensitiveContains(query)
    }

    XCTAssertEqual(matches.map(\.title), ["Newer Match", "Older Match"])
    XCTAssertEqual(Set(receivedQueries), ["Match"])
  }

  func testSearchResultLimitIsLargerThanRecentResultLimit() {
    let profileID = UUID()
    let drafts = (0..<50).map { index in
      ArticleDraft(siteProfileID: profileID, title: "Match \(index)")
    }
    let matches = WorkspaceQuickSearchPresentation.matchingDrafts(
      drafts: drafts,
      query: "Match"
    ) { draft, query in
      draft.title.contains(query)
    }
    let visible = WorkspaceQuickSearchPresentation.visibleDrafts(
      from: matches,
      query: "Match"
    )

    XCTAssertGreaterThan(
      WorkspaceQuickSearchPresentation.searchResultLimit,
      WorkspaceQuickSearchPresentation.recentResultLimit
    )
    XCTAssertEqual(visible.count, WorkspaceQuickSearchPresentation.searchResultLimit)
  }

  func testUnifiedSearchScopesHaveStableInclusionRules() {
    XCTAssertTrue(WorkspaceUnifiedSearchScope.all.includesArticles)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.all.includesResources)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.all.includesRSS)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.all.includesSettings)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.all.includesCommands)

    XCTAssertTrue(WorkspaceUnifiedSearchScope.articles.includesArticles)
    XCTAssertFalse(WorkspaceUnifiedSearchScope.articles.includesSettings)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.resources.includesResources)
    XCTAssertFalse(WorkspaceUnifiedSearchScope.resources.includesRSS)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.rss.includesRSS)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.settings.includesSettings)
    XCTAssertTrue(WorkspaceUnifiedSearchScope.commands.includesCommands)
  }

  func testUnifiedSearchSectionFilteringDoesNotCrossScopes() {
    let sections: [WorkspaceSection] = [.writing, .library, .rss, .images]

    XCTAssertEqual(
      WorkspaceUnifiedSearchPresentation.matchingSections(
        sections,
        query: "",
        scope: .resources
      ),
      [.library, .images]
    )
    XCTAssertEqual(
      WorkspaceUnifiedSearchPresentation.matchingSections(
        sections,
        query: "",
        scope: .rss
      ),
      [.rss]
    )
  }

  private static func fixItem(
    id: String,
    draftID: UUID,
    priority: AIPublishingFixQueuePriority = .medium
  ) -> AIPublishingFixQueueItem {
    AIPublishingFixQueueItem(
      id: id,
      priority: priority,
      draftID: draftID,
      draftTitle: "Draft",
      markdownPath: "content/draft.md",
      needsSummary: true,
      needsTags: false,
      frontMatterIssueCount: 0,
      issueTitles: [],
      recommendedAction: .suggestSummary
    )
  }
}
