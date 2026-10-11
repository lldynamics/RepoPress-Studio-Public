import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishDrawerConnectionPresentationTests: XCTestCase {
  private func preview(hasToken: Bool = true, issues: [PreflightIssue] = [])
    -> RemoteRepositoryPublishPreview
  {
    RemoteRepositoryPublishPreview(
      provider: .github, repositoryName: "example/site", mode: .directCommit,
      branchName: "main", targetBranch: "main", changedPaths: ["post.md"], hasToken: hasToken,
      blockingIssues: issues, warningIssues: [])
  }

  func testUnavailableConnectionAlwaysHasAnExplanationAndRelevantRemedy() {
    let missing = PublishDrawerConnectionPresentation.make(preview: nil)
    XCTAssertFalse(missing.canStart)
    XCTAssertFalse(missing.message.isEmpty)
    XCTAssertEqual(missing.remedy, .refresh)
    let noToken = PublishDrawerConnectionPresentation.make(preview: preview(hasToken: false))
    XCTAssertFalse(noToken.canStart)
    XCTAssertEqual(noToken.remedy, .account)
    XCTAssertFalse(
      PublishDrawerConnectionPresentation.make(preview: preview(), isChecking: true).canStart)
    XCTAssertFalse(
      PublishDrawerConnectionPresentation.make(preview: preview(), isPublishing: true).canStart)
  }

  func testRealBlockerRemainsBlockedButDeferredRemoteCheckCanReachConfirmation() {
    let issue = PreflightIssue(severity: .error, title: "缺少标题", message: "填写标题", field: "title")
    let blocked = PublishDrawerConnectionPresentation.make(preview: preview(issues: [issue]))
    XCTAssertFalse(blocked.canStart)
    XCTAssertEqual(blocked.remedy, .issue(issue))
    let remoteIssue = PreflightIssue(
      severity: .error, title: "待检查", message: "确认前检查", field: "remoteBaseline")
    XCTAssertTrue(
      PublishDrawerConnectionPresentation.make(preview: preview(issues: [remoteIssue])).canStart)
  }

  func testRemoteIssuesUseStableCodesAcrossDifferentDisplayTranslations() {
    let remoteIssues: [PreflightIssue] = [
      .init(
        severity: .warning, title: "Remote Same-Path Changes", message: "Review remote diff",
        field: "repository", code: .remoteSamePathChanges),
      .init(
        severity: .warning, title: "Remote Status Unconfirmed", message: "Check at confirmation",
        field: "repository", code: .remoteStatusUnconfirmed),
    ]
    for issue in remoteIssues {
      XCTAssertTrue(
        PublishDrawerConnectionPresentation.make(preview: preview(issues: [issue])).canStart)
    }

    let unrelated = PreflightIssue(
      severity: .error, title: "Remote Same-Path Changes", message: "Different cause",
      field: "repository")
    XCTAssertFalse(
      PublishDrawerConnectionPresentation.make(
        preview: preview(issues: remoteIssues + [unrelated])
      ).canStart)
  }

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

  func testWorkflowRetainsFourStepsAndDoesNotClaimDeploymentSucceededAfterCommit() {
    let readiness = PublishDrawerReadinessPresentation(sections: [
      .init(id: "content", title: "内容", systemImage: "doc", issues: [], isLoading: false)
    ])
    let steps = PublishDrawerWorkflowStep.make(
      readiness: readiness,
      accountDetail: "未连接", accountStatus: .blocked, changedFileCount: nil,
      isPublishing: false, deploymentDetail: "等待检查线上版本", isReviewRequest: false)
    XCTAssertEqual(steps.map(\.title), ["内容检查", "发布账户", "变更内容", "提交并核验部署"])
    XCTAssertEqual(steps[1].status, .blocked)
    XCTAssertEqual(steps[2].status, .pending)
    XCTAssertEqual(steps[3].status, .pending)
    XCTAssertEqual(steps[3].detail, "等待检查线上版本")
    let running = PublishDrawerWorkflowStep.make(
      readiness: readiness,
      accountDetail: "连接正常", accountStatus: .passed, changedFileCount: 2,
      isPublishing: true, deploymentDetail: nil, isReviewRequest: true)
    XCTAssertEqual(running[3].status, .running)
    XCTAssertEqual(running[3].detail, "正在提交并推送")
    let verified = PublishDrawerWorkflowStep.make(
      readiness: readiness,
      accountDetail: "连接正常", accountStatus: .passed, changedFileCount: 2,
      isPublishing: false, deploymentDetail: "线上版本已核验", isReviewRequest: false,
      deploymentLevel: .success)
    XCTAssertEqual(verified[3].status, .passed)
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

  func testBatchRestoreCanCheckAccountWithoutAnArticleAndStillRequiresWritablePermission() {
    var state = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true, permission: .unchecked, publishableArticleCount: 1, changedFileCount: 1)
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(state))
    // Account verification has no draft identity requirement, so a failed
    // batch with no record.draftID still has a route to unlock confirmation.
    XCTAssertTrue(
      PublishDrawerAccountCheckPresentation.canCheck(
        scope: .managedArticles,
        hasToken: true, isBusy: false))
    XCTAssertFalse(
      PublishDrawerAccountCheckPresentation.canCheck(
        scope: .managedArticles,
        hasToken: false, isBusy: false))
    XCTAssertFalse(
      PublishDrawerAccountCheckPresentation.canCheck(
        scope: .managedArticles,
        hasToken: true, isBusy: true))
    XCTAssertFalse(
      PublishDrawerAccountCheckPresentation.canCheck(
        scope: .repository,
        hasToken: false, isBusy: false))
    state.permission = .readOnly
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(state))
    state.permission = .writable
    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(state))
  }
}
