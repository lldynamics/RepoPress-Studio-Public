import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ContentHealthActionQueueTests: XCTestCase {
  func testActionQueuePartitionsRowsByNextActionWithoutDuplicates() throws {
    let blocking = makeRow(
      title: "Blocking",
      issues: [.init(severity: .error, title: "Slug 为空", message: "需要 slug", field: "slug")],
      aiPriority: .high
    )
    let publicRisk = makeRow(
      title: "Public risk",
      issues: [
        .init(
          severity: .warning,
          title: "公开风险",
          message: "需要确认",
          category: .publicRisk
        )
      ],
      aiPriority: .medium
    )
    let duplicateRisk = makeRow(
      title: "Duplicate path",
      path: "content/posts/duplicate.md",
      issues: [.init(severity: .warning, title: "路径冲突", message: "需要确认")]
    )
    let regularRiskRows = (0..<8).map { index in
      makeRow(
        title: "Risk \(index)",
        issues: [.init(severity: .warning, title: "普通警告", message: "需要确认")]
      )
    }
    let remainingAutomaticFix = makeRow(
      title: "Z AI repair",
      issues: [.init(severity: .warning, title: "摘要为空", message: "建议补全", field: "summary")],
      aiPriority: .medium
    )
    let remainingSuggestion = makeRow(
      title: "ZZ suggestion",
      issues: [.init(severity: .warning, title: "普通建议", message: "稍后处理")]
    )
    let rows =
      [
        blocking,
        publicRisk,
        duplicateRisk,
        remainingAutomaticFix,
        remainingSuggestion,
      ] + regularRiskRows

    let queue = ContentHealthActionQueue(
      rows: rows,
      duplicateMarkdownPaths: [duplicateRisk.normalizedMarkdownPath]
    )

    XCTAssertEqual(queue.blockingRows.map(\.draftID), [blocking.draftID])
    XCTAssertEqual(queue.highestRiskRows.count, 10)
    XCTAssertEqual(queue.highestRiskRows.first?.draftID, publicRisk.draftID)
    XCTAssertEqual(queue.highestRiskRows.dropFirst().first?.draftID, duplicateRisk.draftID)
    XCTAssertEqual(queue.automaticFixRows.map(\.draftID), [remainingAutomaticFix.draftID])
    XCTAssertEqual(queue.suggestionRows.map(\.draftID), [remainingSuggestion.draftID])
    XCTAssertEqual(queue.automaticFixTotalCount, 3)
    XCTAssertEqual(queue.prioritizedAutomaticFixCount, 2)

    let partitionedIDs =
      queue.blockingRows.map(\.draftID)
      + queue.highestRiskRows.map(\.draftID)
      + queue.automaticFixRows.map(\.draftID)
      + queue.suggestionRows.map(\.draftID)
    XCTAssertEqual(Set(partitionedIDs), Set(rows.map(\.draftID)))
    XCTAssertEqual(partitionedIDs.count, rows.count)
  }

  func testHighestRiskQueueStopsAtTenItems() {
    let rows = (0..<15).map { index in
      makeRow(
        title: "Suggestion \(index)",
        issues: Array(
          repeating: PreflightIssue(
            severity: .warning,
            title: "建议",
            message: "稍后处理"
          ),
          count: index + 1
        )
      )
    }

    let queue = ContentHealthActionQueue(rows: rows, duplicateMarkdownPaths: [])

    XCTAssertEqual(queue.highestRiskRows.count, ContentHealthActionQueue.highestRiskLimit)
    XCTAssertEqual(queue.highestRiskRows.first?.warningCount, 15)
    XCTAssertEqual(queue.suggestionRows.count, 5)
  }

  func testHeaderSwitchesToTwoByTwoSummaryBeforeInspectorCausesCompression() {
    XCTAssertTrue(
      ContentHealthLayoutMetrics.usesCompactHeader(
        availableWidth: 1_080,
        usesSplitLayout: true
      )
    )
    XCTAssertTrue(
      ContentHealthLayoutMetrics.usesCompactHeader(
        availableWidth: 1_000,
        usesSplitLayout: false
      )
    )
    XCTAssertFalse(
      ContentHealthLayoutMetrics.usesCompactHeader(
        availableWidth: 1_500,
        usesSplitLayout: true
      )
    )
  }

  func testVisibleSummaryCountsOnlyDisplayedSources() {
    let article = makeRow(
      title: "Article",
      issues: [.init(severity: .error, title: "错误", message: "修正")]
    )
    let maintenance = MaintenanceActionItem(
      id: "maintenance", kind: .taxonomy, priority: .high,
      title: "整理标签", summary: "待处理", detail: "", draftID: nil,
      targetPath: nil, systemImage: "tag"
    )

    let maintenanceOnly = ContentHealthVisibleSummary(
      rows: [], siteIssues: [], maintenanceItems: [maintenance], passingDraftCount: 0
    )
    XCTAssertEqual(maintenanceOnly.errorCount, 0)
    XCTAssertEqual(maintenanceOnly.warningCount, 0)
    XCTAssertEqual(maintenanceOnly.maintenanceCount, 1)

    let articleOnly = ContentHealthVisibleSummary(
      rows: [article], siteIssues: [], maintenanceItems: [], passingDraftCount: 0
    )
    XCTAssertEqual(articleOnly.errorCount, 1)
    XCTAssertEqual(articleOnly.maintenanceCount, 0)
  }

  func testPresentationServiceBuildsSnapshotAndFilteredRowsAsynchronously() async throws {
    let draftID = UUID()
    let error = PreflightIssue(
      severity: .error,
      title: "路径无效",
      message: "需要修正"
    )
    let warning = PreflightIssue(
      severity: .warning,
      title: "公开风险",
      message: "需要确认",
      category: .publicRisk
    )
    let passing = DraftPreflightSummary(
      draftID: UUID(),
      draftTitle: "Passing",
      markdownPath: "content/passing.md",
      issues: []
    )
    let failing = DraftPreflightSummary(
      draftID: draftID,
      draftTitle: "Failing",
      markdownPath: "content/failing.md",
      issues: [error, warning]
    )
    let report = ContentHealthReport(
      sitePreflightIssues: [],
      draftSummaries: [failing, passing],
      publicRiskSummary: PublicRiskSummary(issues: [warning]),
      publicRiskDraftSummaries: [failing],
      aiFixQueueItems: []
    )
    let service = ContentHealthPresentationService()

    let snapshot = try await service.snapshot(
      profileID: UUID(),
      profileName: "Test",
      report: report
    )
    let presentation = try await service.articlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .errors
    )

    XCTAssertEqual(snapshot.errorCount, 1)
    XCTAssertEqual(snapshot.warningCount, 1)
    XCTAssertEqual(snapshot.passingDraftCount, 1)
    XCTAssertEqual(presentation.rows.map(\.draftID), [draftID])
    XCTAssertEqual(presentation.rows.first?.issues, [error])
  }

  func testRootCauseGroupsMergeArticlesAndKeepStableSeverityOrder() {
    let publicRisk = makeRow(
      title: "Z public risk",
      issues: [
        .init(
          severity: .warning,
          title: "公开风险",
          message: "需要确认",
          category: .publicRisk
        )
      ]
    )
    let missingSummary = makeRow(
      title: "A missing summary",
      issues: [.init(severity: .error, title: "摘要为空", message: "需要补全", field: "summary")]
    )
    let anotherMissingSummary = makeRow(
      title: "B missing summary",
      issues: [.init(severity: .error, title: "摘要为空", message: "需要补全", field: "summary")]
    )

    let groups = ContentHealthRootCausePresentation.groups(
      rows: [publicRisk, anotherMissingSummary, missingSummary]
    )

    XCTAssertEqual(
      groups.map(\.id), ["root-cause:field.summary", "root-cause:category.public-risk"])
    XCTAssertEqual(
      groups.first?.rows.map(\.draftTitle), ["A missing summary", "B missing summary"])
    XCTAssertEqual(groups.first?.title, "文章元数据不完整")
  }

  private func makeRow(
    title: String,
    path: String? = nil,
    issues: [PreflightIssue],
    aiPriority: AIPublishingFixQueuePriority? = nil
  ) -> ContentHealthArticleRowModel {
    let draftID = UUID()
    let markdownPath = path ?? "content/posts/\(draftID.uuidString).md"
    let summary = DraftPreflightSummary(
      draftID: draftID,
      draftTitle: title,
      markdownPath: markdownPath,
      issues: issues
    )
    let aiFixItem = aiPriority.map { priority in
      AIPublishingFixQueueItem(
        id: "\(draftID.uuidString)-ai-fix",
        priority: priority,
        draftID: draftID,
        draftTitle: title,
        markdownPath: markdownPath,
        needsSummary: true,
        needsTags: false,
        frontMatterIssueCount: 1,
        issueTitles: ["摘要为空"],
        recommendedAction: .suggestSummary
      )
    }
    return ContentHealthArticleRowModel(
      summary: summary,
      issues: issues,
      aiFixItem: aiFixItem
    )
  }

  func testAllClearRequiresNoIssuesAndALoadedEmptyMaintenanceQueue() {
    XCTAssertTrue(
      ContentHealthAllClear.isAllClear(
        errorCount: 0, warningCount: 0, siteIssueCount: 0, aiFixCount: 0, maintenanceItemCount: 0)
    )
    XCTAssertFalse(
      ContentHealthAllClear.isAllClear(
        errorCount: 0, warningCount: 0, siteIssueCount: 0, aiFixCount: 0,
        maintenanceItemCount: nil),
      "A maintenance snapshot that has not loaded yet is not all clear."
    )
    for counts in [
      (1, 0, 0, 0, 0), (0, 1, 0, 0, 0), (0, 0, 1, 0, 0), (0, 0, 0, 1, 0), (0, 0, 0, 0, 1),
    ] {
      XCTAssertFalse(
        ContentHealthAllClear.isAllClear(
          errorCount: counts.0, warningCount: counts.1, siteIssueCount: counts.2,
          aiFixCount: counts.3, maintenanceItemCount: counts.4)
      )
    }
  }
}

final class ContentHealthIssueListTests: XCTestCase {
  func testCountCardsToggleAndReplaceEachOther() {
    for card in [ContentHealthCountFilter.errors, .warnings, .optimizations, .maintenance] {
      let selected = card.toggled(severity: .all, source: .all)
      XCTAssertTrue(card.isSelected(severity: selected.severity, source: selected.source))
      let cancelled = card.toggled(severity: selected.severity, source: selected.source)
      XCTAssertEqual(cancelled.severity, .all)
      XCTAssertEqual(cancelled.source, .all)
    }
    let errors = ContentHealthCountFilter.errors.toggled(severity: .all, source: .maintenance)
    XCTAssertEqual(errors.severity, .errors)
    XCTAssertEqual(errors.source, .all)
    let maintenance = ContentHealthCountFilter.maintenance.toggled(
      severity: .warnings, source: .articles)
    XCTAssertEqual(maintenance.severity, .all)
    XCTAssertEqual(maintenance.source, .maintenance)
  }

  func testEveryIssueAppearsAndSameCauseMergesAcrossArticles() throws {
    let first = article(
      "First",
      issues: [
        issue(.error, "Missing title"), issue(.warning, "Broken link"),
        issue(.warning, "Broken link"),
      ])
    let second = article(
      "Second", issues: [issue(.warning, "Broken link"), issue(.warning, "Future date")])
    let rows = project([first, second])
    XCTAssertEqual(rows.map(\.section), [.errors, .warnings, .warnings])
    XCTAssertEqual(rows.reduce(0) { $0 + $1.occurrenceCount }, 5)
    let links = try XCTUnwrap(rows.first { $0.title == "Broken link" })
    XCTAssertEqual(links.affectedArticleCount, 2)
    XCTAssertEqual(links.occurrenceCount, 3)
    XCTAssertEqual(Set(links.articles.map(\.draftID)), [first.draftID, second.draftID])
    XCTAssertEqual(links.articles.first { $0.draftID == first.draftID }?.issues.count, 2)
  }

  func testSeveritySourceAndDifferentRulesDoNotMerge() {
    let warning = issue(.warning, "Same title")
    var otherRule = warning
    otherRule.field = "summary"
    let rows = project(
      [
        article("First", issues: [issue(.error, "Same title"), warning, otherRule])
      ], siteIssues: [warning])
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows.filter { !$0.siteIssues.isEmpty }.count, 1)
    XCTAssertEqual(rows.map(\.id).count, Set(rows.map(\.id)).count)
  }

  func testSearchMatchesArticlePathMessageAndMaintenanceWithoutLosingOtherSources() {
    let article = article(
      "Alpha title", issues: [issue(.warning, "Broken link", message: "Target missing")])
    let maintenance = maintenance("task", draftID: article.draftID, title: "复查旧文：Alpha title")
    XCTAssertEqual(project([article], search: "alpha MISSING").count, 1)
    XCTAssertEqual(project([article], search: "content/post").count, 1)
    XCTAssertEqual(project([article], search: "no match").count, 0)
    XCTAssertEqual(
      project([], siteIssues: [issue(.error, "Site configuration")], search: "configuration").count,
      1)
    XCTAssertEqual(project([], maintenanceItems: [maintenance], search: "Alpha").count, 1)
    XCTAssertEqual(project([article], search: "   ").count, 1)
  }

  func testIdentitySurvivesNewScanIssueIDsAndSelectionPayloadRefreshes() throws {
    let draftID = UUID()
    let before = project([
      article(
        "Before", draftID: draftID, issues: [issue(.warning, "Same cause", message: "Old detail")])
    ])
    let after = project([
      article(
        "After", draftID: draftID, issues: [issue(.warning, "Same cause", message: "New detail")])
    ])
    XCTAssertEqual(before.first?.id, after.first?.id)
    let selection = try XCTUnwrap(
      ContentHealthIssueListProjection.reconciled(before.first, rows: after))
    XCTAssertEqual(selection.articles.first?.draftTitle, "After")
    XCTAssertEqual(selection.detail, "New detail")
    XCTAssertNotEqual(before.first, selection)
    XCTAssertNil(ContentHealthIssueListProjection.reconciled(selection, rows: []))
    XCTAssertNil(ContentHealthIssueListProjection.reconciled(nil, rows: after))
  }

  func testKeyboardTraversesAllSourcesAndClampsAtBounds() throws {
    let rows = project(
      [article("Article", issues: [issue(.error, "Error"), issue(.warning, "Warning")])],
      maintenanceItems: [maintenance("task")]
    )
    XCTAssertEqual(ContentHealthIssueListProjection.moved(nil, offset: 1, rows: rows), rows.first)
    XCTAssertEqual(ContentHealthIssueListProjection.moved(nil, offset: -1, rows: rows), rows.last)
    var selected = rows.first
    selected = ContentHealthIssueListProjection.moved(selected, offset: 1, rows: rows)
    XCTAssertEqual(selected?.section, .warnings)
    selected = ContentHealthIssueListProjection.moved(selected, offset: 1, rows: rows)
    XCTAssertEqual(selected?.section, .maintenance)
    XCTAssertEqual(
      ContentHealthIssueListProjection.moved(selected, offset: 1, rows: rows), rows.last)
    XCTAssertEqual(
      ContentHealthIssueListProjection.moved(rows.first, offset: -1, rows: rows), rows.first)
    XCTAssertNil(ContentHealthIssueListProjection.moved(selected, offset: 1, rows: []))
  }

  func testMaintenanceMergeKeepsPriorityAndEveryTaskAction() throws {
    let first = maintenance("first", draftID: UUID(), title: "复查旧文：First")
    let second = maintenance("second", draftID: UUID(), title: "复查旧文：Second")
    var low = maintenance("low", draftID: UUID(), title: "复查旧文：Third")
    low.priority = .low
    let rows = project([], maintenanceItems: [low, second, first])
    XCTAssertEqual(rows.count, 2)
    let high = try XCTUnwrap(rows.first)
    XCTAssertEqual(high.title, "复查旧文")
    XCTAssertEqual(high.affectedArticleCount, 2)
    XCTAssertEqual(high.maintenanceItems.map(\.id), ["first", "second"])
    XCTAssertEqual(high.maintenanceItems.first?.priority, .high)
    XCTAssertEqual(rows.last?.maintenanceItems.first?.priority, .low)
  }

  func testGroupingModesKeepSeverityAndOccurrenceCounts() {
    let articles = [
      article("First", issues: [issue(.error, "Title"), issue(.warning, "Summary")]),
      article("Second", issues: [issue(.warning, "Summary")]),
    ]
    for mode in ContentHealthArticleGrouping.allCases {
      let rows = project(articles, grouping: mode)
      XCTAssertEqual(rows.first?.section, .errors)
      XCTAssertEqual(rows.reduce(0) { $0 + $1.occurrenceCount }, 3)
      if mode == .file {
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.subgroup == "content/post.md" })
      } else {
        XCTAssertEqual(rows.count, 2)
      }
    }
  }

  func testLegacyContextsRetainPublicRiskAIFixSiteAndMaintenanceScope() async throws {
    let draftID = UUID()
    let risk = PreflightIssue(
      severity: .warning, title: "Risk", message: "Review", category: .publicRisk)
    let ordinary = issue(.error, "Ordinary")
    let summary = DraftPreflightSummary(
      draftID: draftID, draftTitle: "Article", markdownPath: "post.md", issues: [risk, ordinary])
    let service = ContentHealthPresentationService()
    let snapshot = try await service.snapshot(
      profileID: UUID(), profileName: "Site",
      report: ContentHealthReport(
        sitePreflightIssues: [ordinary], draftSummaries: [summary],
        publicRiskSummary: PublicRiskSummary(issues: [risk]),
        publicRiskDraftSummaries: [summary], aiFixQueueItems: []
      ))
    let risks = try await service.articlePresentation(
      snapshot: snapshot, filter: .publicRisks, severityFilter: .all)
    XCTAssertEqual(risks.rows.first?.issues, [risk])
    let ai = try await service.articlePresentation(
      snapshot: snapshot, filter: .aiFixes, severityFilter: .all)
    XCTAssertTrue(ai.rows.isEmpty)
    let site = try await service.articlePresentation(
      snapshot: snapshot, filter: .siteIssues, severityFilter: .all)
    XCTAssertTrue(site.rows.isEmpty)
    XCTAssertEqual(site.siteIssues, [ordinary])
    let maintenance = try await service.articlePresentation(
      snapshot: snapshot, filter: .maintenance, severityFilter: .all)
    XCTAssertEqual(maintenance.rows.first?.issues, [risk, ordinary])
  }

  func testSiteInformationDoesNotBecomeAWarning() {
    let notes = project([], siteIssues: [issue(.info, "Upstream not set")])
    XCTAssertTrue(
      notes.isEmpty, "Site notes are displayed separately without changing warning counts.")
  }

  func testSameTitleMaintenanceActionsExposeDistinctTargets() {
    var first = maintenance("first", draftID: UUID(), title: "确认内链路径：Article")
    first.detail = "Line 4"
    first.targetPath = "/first"
    var second = first
    second.id = "second"
    second.detail = "Line 10"
    second.targetPath = "/second"
    let rows = project([], maintenanceItems: [first, second])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.maintenanceItems.count, 2)
    XCTAssertNotEqual(first.contentHealthActionTarget, second.contentHealthActionTarget)
    XCTAssertTrue(first.contentHealthActionTarget.contains("/first"))
    XCTAssertTrue(second.contentHealthActionTarget.contains("Line 10"))
  }

  func testRetainedEmptyMaintenanceSnapshotCannotMaskRefreshFailureOrStaleness() {
    typealias Presentation = ContentHealthMaintenanceScanPresentation
    XCTAssertEqual(
      Presentation.status(hasSnapshot: true, isRefreshing: false, errorMessage: nil), .ready)
    XCTAssertEqual(
      Presentation.status(hasSnapshot: true, isRefreshing: true, errorMessage: nil), .loading)
    XCTAssertEqual(
      Presentation.status(hasSnapshot: true, isRefreshing: false, errorMessage: "Failed"),
      .failed("Failed"))
    XCTAssertEqual(
      Presentation.status(hasSnapshot: false, isRefreshing: false, errorMessage: nil), .loading)
    XCTAssertEqual(
      Presentation.status(hasSnapshot: true, isRefreshing: false, isStale: true, errorMessage: nil),
      .stale)
    XCTAssertEqual(
      Presentation.status(
        hasSnapshot: true, isRefreshing: true, isStale: true, errorMessage: "Old error"), .loading)
  }

  private func project(
    _ articles: [ContentHealthArticleRowModel], siteIssues: [PreflightIssue] = [],
    maintenanceItems: [MaintenanceActionItem] = [],
    grouping: ContentHealthArticleGrouping = .actionQueue,
    search: String = ""
  ) -> [ContentHealthIssueSelection] {
    ContentHealthIssueListProjection.rows(
      articles: articles, siteIssues: siteIssues, maintenanceItems: maintenanceItems,
      grouping: grouping, profileName: "Site", search: search)
  }

  private func issue(_ severity: PreflightSeverity, _ title: String, message: String = "Review")
    -> PreflightIssue
  {
    PreflightIssue(severity: severity, title: title, message: message)
  }

  private func article(_ title: String, draftID: UUID = UUID(), issues: [PreflightIssue])
    -> ContentHealthArticleRowModel
  {
    ContentHealthArticleRowModel(
      summary: DraftPreflightSummary(
        draftID: draftID, draftTitle: title, markdownPath: "content/post.md", issues: issues),
      issues: issues, aiFixItem: nil)
  }

  private func maintenance(_ id: String, draftID: UUID? = nil, title: String = "Task")
    -> MaintenanceActionItem
  {
    MaintenanceActionItem(
      id: id, kind: .staleArticle, priority: .high, title: title, summary: "Review", detail: "",
      draftID: draftID, targetPath: nil, systemImage: "clock")
  }
}

final class ContentHealthSiteSummaryTests: XCTestCase {
  func testCountCardsRetainEntireSiteCountsAcrossEveryListFilter() async throws {
    let profileID = UUID()
    let error = PreflightIssue(severity: .error, title: "Error", message: "Fix")
    let warning = PreflightIssue(severity: .warning, title: "Warning", message: "Review")
    let report = ContentHealthReport(
      sitePreflightIssues: [
        error, warning, .init(severity: .info, title: "Note", message: "Info"),
      ],
      draftSummaries: [
        .init(
          draftID: UUID(), draftTitle: "Failing", markdownPath: "failing.md",
          issues: [error, warning, warning]),
        .init(draftID: UUID(), draftTitle: "Passing", markdownPath: "passing.md", issues: []),
      ],
      publicRiskSummary: PublicRiskSummary(issues: []), publicRiskDraftSummaries: [],
      aiFixQueueItems: [])
    let service = ContentHealthPresentationService()
    let snapshot = try await service.snapshot(
      profileID: profileID, profileName: "Site", report: report)
    let maintenance = maintenanceSnapshot(profileID: profileID)
    let expected = ContentHealthSiteSummary(snapshot: snapshot, maintenanceSnapshot: maintenance)
    XCTAssertEqual(expected.errorCount, 2)
    XCTAssertEqual(expected.warningCount, 3)
    XCTAssertEqual(expected.passingDraftCount, 1)
    XCTAssertEqual(expected.maintenanceCount, 1)
    XCTAssertEqual(expected.issueCount, 5)

    for context in [
      ContentHealthContextFilter.overview, .publicRisks, .aiFixes, .siteIssues, .maintenance,
    ] {
      for severity in ContentHealthSeverityFilter.allCases {
        let presentation = try await service.articlePresentation(
          snapshot: snapshot, filter: context, severityFilter: severity)
        for source in ContentHealthSourceFilter.allCases {
          for ai in ContentHealthAIFixFilter.allCases {
            let rows = ContentHealthIssueListProjection.rows(
              articles: source.includesArticles
                ? presentation.rows.filter { ai.includes(canUseAI: $0.aiFixItem != nil) } : [],
              siteIssues: source.includesSite && ai != .fixable ? presentation.siteIssues : [],
              maintenanceItems: source.includesMaintenance && severity == .all
                ? maintenance.report.actionItems.filter { ai.includes(canUseAI: $0.draftID != nil) }
                : [],
              grouping: .actionQueue, profileName: "Site", search: "no matching issue")
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(
              ContentHealthSiteSummary(snapshot: snapshot, maintenanceSnapshot: maintenance),
              expected)
          }
        }
      }
    }
  }

  func testAnotherSitesRetainedMaintenanceReportCannotChangeCountCards() {
    let snapshot = ContentHealthSnapshot(
      id: UUID(), generatedAt: Date(), profileID: UUID(), profileName: "Site",
      publicRiskDraftSummaries: [], aiFixQueueItems: [], sitePreflightIssues: [],
      contentHealthSummaries: [], slugChangeImpacts: [:], errorCount: 1, warningCount: 6,
      passingDraftCount: 41)
    let unrelated = maintenanceSnapshot(profileID: UUID())
    let summary = ContentHealthSiteSummary(snapshot: snapshot, maintenanceSnapshot: unrelated)
    XCTAssertEqual(summary.maintenanceCount, 0)
    XCTAssertEqual(summary.errorCount, 1)
    XCTAssertEqual(summary.warningCount, 6)
    XCTAssertEqual(summary.passingDraftCount, 41)
    XCTAssertEqual(summary.issueCount, 7)
  }

  @MainActor
  func testRailBadgeUsesTheSameErrorAndWarningCountAsCards() {
    let profileID = UUID()
    let snapshot = ContentHealthSnapshot(
      id: UUID(), generatedAt: Date(), profileID: profileID, profileName: "Site",
      publicRiskDraftSummaries: [], aiFixQueueItems: [], sitePreflightIssues: [],
      contentHealthSummaries: [], slugChangeImpacts: [:], errorCount: 1, warningCount: 6,
      passingDraftCount: 41)
    let summary = ContentHealthSiteSummary(snapshot: snapshot, maintenanceSnapshot: nil)
    let rail = ContentHealthSidebarProjection()
    rail.replace(profileID: profileID, aiFixQueueItems: [], issueCount: summary.issueCount)
    XCTAssertEqual(rail.knownIssueCount(for: profileID), 7)
    XCTAssertEqual(rail.knownIssueCount(for: profileID), summary.errorCount + summary.warningCount)
    XCTAssertNil(rail.knownIssueCount(for: UUID()))
  }

  private func maintenanceSnapshot(profileID: UUID) -> SiteMaintenanceSnapshot {
    var report = SiteMaintenanceService().report(
      drafts: [], profile: .defaultProfile, releaseRecords: [])
    report.actionItems = [
      MaintenanceActionItem(
        id: "task", kind: .taxonomy, priority: .high, title: "Task", summary: "Review", detail: "",
        draftID: nil, targetPath: nil, systemImage: "tag")
    ]
    return SiteMaintenanceSnapshot(
      report: report, profileID: profileID, profileName: "Site", draftCount: 0, sourceVersion: 0)
  }
}

@MainActor
final class ContentHealthInspectorActionsTests: XCTestCase {
  func testClearingPreviousPageOwnerKeepsNewPageActionsAndExitInvalidatesThem() {
    let actions = ContentHealthInspectorActions()
    let firstOwner = UUID()
    let nextOwner = UUID()
    var calls: [String] = []
    actions.install(
      ownerID: firstOwner, generatedAt: Date(),
      handlers: handlers { calls.append("first") })
    actions.install(
      ownerID: nextOwner, generatedAt: Date(),
      handlers: handlers { calls.append("next") })
    actions.clear(ownerID: firstOwner)
    XCTAssertTrue(actions.isAvailable)
    actions.locate(issue, draftID: UUID())
    XCTAssertEqual(calls, ["next"])
    actions.clear(ownerID: nextOwner)
    actions.locate(issue, draftID: UUID())
    XCTAssertEqual(calls, ["next"])
    XCTAssertFalse(actions.isAvailable)
    XCTAssertNil(actions.generatedAt)
  }

  func testProfileChangeBlocksEveryRetainedCommand() {
    let actions = ContentHealthInspectorActions()
    var isCurrent = true
    var calls = 0
    actions.install(
      ownerID: UUID(), generatedAt: Date(),
      handlers: handlers(isCurrent: { isCurrent }) { calls += 1 })
    isCurrent = false
    actions.locate(issue, draftID: UUID())
    actions.openMaintenanceDraft(UUID())
    actions.copyMaintenance(maintenance)
    actions.recordMaintenance(maintenance)
    actions.sendMaintenanceToAI(maintenance)
    actions.runAIFix(aiItem)
    XCTAssertNil(actions.slugResolution(for: UUID()))
    XCTAssertEqual(calls, 0)
  }

  func testAIBusyStateIsCheckedAgainWhenCommandRuns() {
    let actions = ContentHealthInspectorActions()
    let owner = UUID()
    var isRunning = false
    var calls = 0
    actions.install(
      ownerID: owner, generatedAt: Date(),
      handlers: handlers(isAIRunning: { isRunning }) { calls += 1 })
    isRunning = true
    actions.runAIFix(aiItem)
    actions.sendMaintenanceToAI(maintenance)
    XCTAssertEqual(calls, 0, "Commands must guard live state even before the UI receives it.")
    actions.updateAIState(ownerID: owner)
    XCTAssertTrue(actions.isAIRunning)
    isRunning = false
    actions.updateAIState(ownerID: owner)
    actions.runAIFix(aiItem)
    actions.sendMaintenanceToAI(maintenance)
    XCTAssertFalse(actions.isAIRunning)
    XCTAssertEqual(calls, 2)
  }

  func testSeparateWindowRoutersKeepTheirOwnHandlers() {
    let first = ContentHealthInspectorActions()
    let second = ContentHealthInspectorActions()
    let firstOwner = UUID()
    var firstCalls = 0
    var secondCalls = 0
    first.install(
      ownerID: firstOwner, generatedAt: Date(), handlers: handlers { firstCalls += 1 })
    second.install(
      ownerID: UUID(), generatedAt: Date(), handlers: handlers { secondCalls += 1 })
    first.clear(ownerID: firstOwner)
    first.locate(issue, draftID: UUID())
    second.locate(issue, draftID: UUID())
    XCTAssertEqual(firstCalls, 0)
    XCTAssertEqual(secondCalls, 1)
  }

  private func handlers(
    isCurrent: @escaping () -> Bool = { true },
    isAIRunning: @escaping () -> Bool = { false },
    action: @escaping () -> Void
  ) -> ContentHealthInspectorActions.Handlers {
    ContentHealthInspectorActions.Handlers(
      isCurrent: isCurrent, isAIRunning: isAIRunning,
      locate: { _, _ in action() }, runAIFix: { _ in action() },
      openMaintenanceDraft: { _ in action() }, copyMaintenance: { _ in action() },
      recordMaintenance: { _ in action() }, sendMaintenanceToAI: { _ in action() },
      slugResolution: { _ in
        action()
        return nil
      })
  }

  private var issue: PreflightIssue {
    PreflightIssue(severity: .warning, title: "Issue", message: "Review")
  }

  private var maintenance: MaintenanceActionItem {
    MaintenanceActionItem(
      id: "task", kind: .taxonomy, priority: .high, title: "Task", summary: "Review", detail: "",
      draftID: UUID(), targetPath: nil, systemImage: "tag")
  }

  private var aiItem: AIPublishingFixQueueItem {
    AIPublishingFixQueueItem(
      id: "ai", priority: .high, draftID: UUID(), draftTitle: "Article", markdownPath: "post.md",
      needsSummary: true, needsTags: false, frontMatterIssueCount: 1, issueTitles: ["Summary"],
      recommendedAction: .suggestSummary)
  }
}
