import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishDrawerConnectionPresentationTests: XCTestCase {
  func testGroupingPreservesAllDetailsStrongestSeverityAndDifferentPaths() {
    let issues: [PreflightIssue] = [
      .init(severity: .warning, title: "未选择仓库", message: "选择根目录", field: "repository"),
      .init(severity: .error, title: "未选择仓库", message: "当前操作需要仓库", field: "repository"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "a.png"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "b.png"),
    ]
    let grouped = PublishReadinessIssueGrouping.coalesced(issues)
    XCTAssertEqual(grouped.count, 3)
    XCTAssertEqual(grouped[0].severity, .error)
    XCTAssertTrue(grouped[0].message.contains("选择根目录"))
    XCTAssertTrue(grouped[0].message.contains("当前操作需要仓库"))
    XCTAssertEqual(grouped[0].id, issues[0].id)
  }

  func testGroupingKeepsDistinctIssueCodesSeparate() {
    let issues: [PreflightIssue] = [
      .init(
        severity: .warning, title: "Remote check", message: "Refresh first",
        field: "repository", code: .remoteStatusUnconfirmed),
      .init(
        severity: .warning, title: "Remote check", message: "Review paths",
        field: "repository", code: .remoteSamePathChanges),
    ]

    XCTAssertEqual(PublishReadinessIssueGrouping.coalesced(issues).count, 2)
  }

  func testInspectorUsesExplicitWindowDraftAndRejectsOtherProfile() {
    let profileID = UUID()
    let draft = ArticleDraft(siteProfileID: profileID, title: "Window article")
    XCTAssertEqual(
      PublishDrawerDraftPresentation.resolve(draftID: draft.id, profileID: profileID, draft: draft)?
        .id,
      draft.id)
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: nil, profileID: profileID, draft: draft))
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: UUID(), profileID: profileID, draft: draft))
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: draft.id, profileID: UUID(), draft: draft))
  }

  func testIssueSelectionSurvivesRegeneratedIDsAndLocatesExactBodyValue() {
    let first = PreflightIssue(
      severity: .warning, title: "链接无法解析", message: "检查目标",
      field: "body", category: .brokenInternalLink, relatedValue: "/posts/missing")
    var refreshed = first
    refreshed.id = UUID()
    let draftID = UUID()
    let firstRow = PublishDrawerReadinessIssue.preflight(first, draftID: draftID, prefix: "body")
    let refreshedRow = PublishDrawerReadinessIssue.preflight(
      refreshed, draftID: draftID, prefix: "body")
    XCTAssertEqual(firstRow.id, refreshedRow.id)
    XCTAssertEqual(firstRow.draftID, draftID)
    XCTAssertEqual(firstRow.target, .body(query: "/posts/missing"))
    XCTAssertTrue(firstRow.supportsAIFix)
    let date = PreflightIssue(severity: .warning, title: "时间在未来", message: "确认时间", field: "date")
    let dateRow = PublishDrawerReadinessIssue.preflight(date, draftID: draftID, prefix: "date")
    XCTAssertEqual(dateRow.actionTitle, "修改时间")
    XCTAssertEqual(dateRow.target, .metadata(field: "date"))
    XCTAssertFalse(dateRow.supportsAIFix)
  }

  func testPendingChecksAreNotReportedAsPassedAndBlockersPrecedeWarningsAcrossGroups() {
    let warning = PreflightIssue(severity: .warning, title: "提醒", message: "确认", field: "date")
    let blocker = PreflightIssue(severity: .error, title: "阻断", message: "修复", field: "title")
    let readiness = PublishDrawerReadinessPresentation(sections: [
      .init(
        id: "warning", title: "提醒组", systemImage: "clock",
        issues: [.preflight(warning, draftID: nil, prefix: "warning")], isLoading: false),
      .init(id: "passed", title: "通过组", systemImage: "photo", issues: [], isLoading: false),
      .init(id: "loading", title: "检查中", systemImage: "clock", issues: [], isLoading: true),
      .init(
        id: "blocker", title: "阻断组", systemImage: "doc",
        issues: [.preflight(blocker, draftID: nil, prefix: "blocker")], isLoading: false),
    ])
    XCTAssertEqual(readiness.issues.map(\.severity), [.error, .warning])
    XCTAssertEqual(readiness.passedSections.map(\.id), ["passed"])
    XCTAssertEqual(readiness.blockingCount, 1)
    XCTAssertEqual(readiness.warningCount, 1)
    XCTAssertTrue(readiness.isLoading)
  }

  func testArticleContentDoesNotTurnDeferredRemoteChecksIntoBlockers() {
    let draftID = UUID()
    let issues: [PreflightIssue] = [
      .init(severity: .error, title: "远端待确认", message: "确认前检查", field: "remoteBaseline"),
      .init(severity: .error, title: "缺少标题", message: "请填写", field: "title"),
    ]
    let seo = SEOAuditReport(
      titleCharacterCount: 10, summaryCharacterCount: 10,
      bodyCharacterCount: 10, h1Count: 1, hasPublishableCoverImage: false,
      markdownPath: "post.md", frontMatterPreview: "", findings: [])
    let readiness = PublishDrawerReadinessPresentation.article(
      draftID: draftID,
      preflightIssues: issues, imageReport: nil, isImageReportLoading: true,
      seoReport: seo, socialSnapshot: nil, isSocialPreviewStale: false)
    XCTAssertEqual(readiness.blockingCount, 1)
    XCTAssertEqual(readiness.issues.first?.title, "缺少标题")
    XCTAssertEqual(readiness.passedSections.map(\.id), ["seo"])
    XCTAssertTrue(readiness.issues.allSatisfy { $0.draftID == draftID })
  }

  func testIgnoredSiteCheckFindingsAreNeitherListedNorCounted() {
    let draftID = UUID()
    let ignored = PreflightIssue(severity: .warning, title: "正文偏短", message: "可选")
    let kept = PreflightIssue(severity: .warning, title: "摘要偏短", message: "可选")
    let seo = SEOAuditReport(
      titleCharacterCount: 10, summaryCharacterCount: 10,
      bodyCharacterCount: 10, h1Count: 1, hasPublishableCoverImage: false,
      markdownPath: "post.md", frontMatterPreview: "", findings: [])
    let readiness = PublishDrawerReadinessPresentation.article(
      draftID: draftID, preflightIssues: [ignored, kept], imageReport: nil,
      isImageReportLoading: false, seoReport: seo, socialSnapshot: nil,
      isSocialPreviewStale: false,
      isPreflightIssueIgnored: { $0.title == ignored.title })
    XCTAssertEqual(readiness.ignoredCount, 1)
    XCTAssertFalse(readiness.issues.contains { $0.title == ignored.title })
    XCTAssertTrue(readiness.issues.contains { $0.title == kept.title })
    // 摘要偏短 plus the not-yet-generated social card.
    XCTAssertEqual(
      ArticlePublishAttention.pendingCount(readiness: readiness, accountStatus: .passed), 2)

    let plan = BatchPublishPlan(
      profileID: UUID(), siteName: "Site",
      items: [])
    let batch = PublishDrawerReadinessPresentation.batch(
      plan: plan, profileID: plan.profileID, isRefreshing: false,
      isIssueIgnored: { _, _ in true })
    XCTAssertEqual(batch.ignoredCount, 0)
  }

  func testBatchReadinessRejectsPlanFromAnotherSite() {
    let stalePlan = BatchPublishPlan(profileID: UUID(), siteName: "Other site", items: [])
    let presentation = PublishDrawerReadinessPresentation.batch(
      plan: stalePlan,
      profileID: UUID(), isRefreshing: false)
    XCTAssertTrue(presentation.isLoading)
    XCTAssertTrue(presentation.passedSections.isEmpty)
    XCTAssertTrue(presentation.issues.isEmpty)
  }

  func testOptionalOnlySiteFindingIsAvailableThroughOptimizationFilter() {
    let issue = PreflightIssue(
      severity: .warning, title: "正文偏短", message: "建议补充内容", field: "body",
      ruleID: ContentHealthRuleID.shortBody.rawValue)
    let snapshot = ContentHealthSnapshot(
      id: UUID(), generatedAt: Date(), profileID: UUID(), profileName: "Site",
      publicRiskDraftSummaries: [], aiFixQueueItems: [], sitePreflightIssues: [issue],
      contentHealthSummaries: [], slugChangeImpacts: [:], errorCount: 0, warningCount: 0,
      optimizationCount: 1, passingDraftCount: 0)
    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot, filter: .overview, severityFilter: .all)
    XCTAssertTrue(presentation.rows.isEmpty)
    XCTAssertEqual(presentation.siteIssues.count, 1)
    let optimizationPresentation = ContentHealthArticlePresentation(
      snapshot: snapshot, filter: .overview, severityFilter: .optimizations)
    XCTAssertEqual(optimizationPresentation.siteIssues.count, 1)
    XCTAssertEqual(snapshot.optimizationCount, 1)
  }
}
