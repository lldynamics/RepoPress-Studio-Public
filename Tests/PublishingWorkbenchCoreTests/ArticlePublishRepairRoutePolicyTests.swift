import XCTest

@testable import PublishingWorkbenchCore

final class ArticlePublishRepairRoutePolicyTests: XCTestCase {
  func testArticleReadinessTargetsStayInWritingWithTheirAtomicTarget() {
    let targets: [PublishReadinessTarget] = [
      .body(query: "/images/cover.png"),
      .metadata(field: "summary"),
      .images(attachmentID: UUID()),
      .seo,
    ]

    for target in targets {
      let route = ArticlePublishRepairRoutePolicy.route(for: target)
      XCTAssertEqual(route, .article(target))
      XCTAssertEqual(route.workspaceSection, .writing)
      XCTAssertTrue(route.keepsArticleContext)
    }
  }

  func testRepositoryReadinessIsTheOnlyTargetThatRoutesToSite() {
    let route = ArticlePublishRepairRoutePolicy.route(for: .repository)

    XCTAssertEqual(route, .repository)
    XCTAssertEqual(route.workspaceSection, .sync)
    XCTAssertFalse(route.keepsArticleContext)
  }

  func testPreflightRoutesKeepBodyQueryAndRepositoryClassificationAtomic() {
    let bodyIssue = PreflightIssue(
      severity: .error,
      title: "图片未登记",
      message: "修复图片引用",
      field: "body",
      category: .unregisteredBodyImage,
      relatedValue: "/images/cover.png"
    )
    XCTAssertEqual(
      PublishReadinessTarget.preflight(bodyIssue),
      .body(query: "/images/cover.png")
    )

    let repositoryIssue = PreflightIssue(
      severity: .error,
      title: "仓库未配置",
      message: "选择仓库",
      field: "repository"
    )
    XCTAssertEqual(PublishReadinessTarget.preflight(repositoryIssue), .repository)
  }
}

final class DraftPublishStatusTests: XCTestCase {
  func testMixedIssuesKeepChecklistCountAndPreferContentBlocker() {
    let status = make(
      issues: [
        .init(severity: .warning, title: "Warning"), .init(severity: .error, title: "Error"),
      ],
      pendingCount: 4,
      accountIsBlocked: true,
      accountDetail: "Account"
    )
    XCTAssertEqual(status.state, .contentBlocked)
    XCTAssertEqual(status.pendingCount, 4)
    XCTAssertEqual(status.severityCount, 2)
    XCTAssertEqual(status.reason, "Error")
  }

  func testAccountBlockerOutranksWarnings() {
    let status = make(
      issues: [.init(severity: .warning, title: "Warning")],
      pendingCount: 2,
      accountIsBlocked: true,
      accountDetail: "Credentials unavailable"
    )
    XCTAssertEqual(status.state, .contentBlocked)
    XCTAssertEqual(status.reason, "Credentials unavailable")
    XCTAssertEqual(status.severityCount, 1)
    XCTAssertEqual(status.pendingCount, 2)
  }

  func testPublishConditionsOutrankWarningsAndKeepChecklistCount() {
    let issue = PreflightIssue(
      severity: .error, title: "No Git repository", message: "Select a repo")
    let status = make(
      issues: [.init(severity: .warning, title: "Social card")],
      pendingCount: 1,
      readiness: readiness(write: .blocked, writeIssues: [issue])
    )
    XCTAssertEqual(status.state, .publishConditionsBlocked)
    XCTAssertEqual(status.reason, "No Git repository")
    XCTAssertEqual(status.pendingCount, 1)
  }

  func testContentBlockerPrecedesPublishCondition() {
    let condition = PreflightIssue(severity: .error, title: "Git", message: "Git")
    let status = make(
      issues: [.init(severity: .error, title: "Article")],
      pendingCount: 1,
      readiness: readiness(write: .blocked, writeIssues: [condition])
    )
    XCTAssertEqual(status.state, .contentBlocked)
    XCTAssertEqual(status.reason, "Article")
  }

  func testWarningShowsCompletePendingCount() {
    let status = make(issues: [.init(severity: .warning, title: "SEO")], pendingCount: 3)
    XCTAssertEqual(status.state, .warning)
    XCTAssertEqual(status.pendingCount, 3)
    XCTAssertEqual(status.reason, "SEO")
  }

  func testEmptyChecksWithoutReadinessRemainPending() {
    XCTAssertEqual(make().state, .pending)
  }

  func testLoadingChecksCannotReportReady() {
    XCTAssertEqual(make(readiness: readiness(), isLoading: true).state, .pending)
  }

  func testBlockedActionsWithoutAnIssueCannotReportReady() {
    XCTAssertEqual(make(readiness: readiness(write: .blocked)).state, .pending)
    XCTAssertEqual(make(readiness: readiness(commit: .blocked)).state, .pending)
  }

  func testCompletedChecksAllowReadyOrReviewableActions() {
    XCTAssertEqual(make(readiness: readiness()).state, .ready)
    XCTAssertEqual(
      make(readiness: readiness(write: .needsReview, commit: .unchanged)).state, .ready)
  }

  func testEmptyReasonsFallThroughToConcreteAccountReason() {
    let status = make(
      issues: [.init(severity: .error, title: " \n")],
      pendingCount: 2,
      accountIsBlocked: true,
      accountDetail: "  Keychain failure  "
    )
    XCTAssertEqual(status.reason, "Keychain failure")
  }

  func testOneBlockerAndEightOptimizationsExposeOnlyOneBlockingCount() {
    let blocker = DraftPublishStatus.Issue(severity: .error, title: "标题为空")
    let optimizations = (0..<8).map {
      DraftPublishStatus.Issue(
        severity: .warning, title: "优化 \($0)", isOptionalOptimization: true)
    }
    let status = make(issues: [blocker] + optimizations, pendingCount: 1, readiness: readiness())
    XCTAssertEqual(status.state, .contentBlocked)
    XCTAssertEqual(status.severityCount, 1)
  }

  func testOptionalOnlyIssuesAreReadyWhenFreshRequirementsAreSatisfied() {
    let status = make(
      issues: [
        .init(severity: .warning, title: "正文偏短", isOptionalOptimization: true),
        .init(severity: .warning, title: "标题重复", isOptionalOptimization: true),
      ], readiness: readiness())
    XCTAssertEqual(status.state, .ready)
    XCTAssertEqual(status.severityCount, 0)
  }

  func testUnknownSecurityAndDuplicatePathFindingsFailClosed() {
    let unknown = PreflightIssue(
      severity: .warning, title: "未知规则", message: "需要人工确认", ruleID: "future.rule")
    let security = PreflightIssue(
      severity: .warning, title: "公开风险", message: "本机路径", category: .publicRisk,
      ruleID: ContentHealthRuleID.shortBody.rawValue)
    let duplicatePath = PreflightIssue(
      severity: .error, title: "发布路径重复", message: "会覆盖文件", field: "slug")
    XCTAssertFalse(unknown.isOptionalOptimization)
    XCTAssertFalse(security.isOptionalOptimization)
    XCTAssertFalse(duplicatePath.isOptionalOptimization)
  }

  func testMeaningfulWarningRemainsSeparateFromOptimization() {
    let status = make(
      issues: [.init(severity: .warning, title: "远端状态未确认")],
      pendingCount: 1, readiness: readiness())
    XCTAssertEqual(status.state, .warning)
    XCTAssertEqual(status.severityCount, 1)
  }

  func testDuplicateTitleWarningDoesNotBlockDifferentPathsButDuplicatePathStillErrors() {
    let profile = SiteProfile.defaultProfile
    let body = String(repeating: "Long enough body. ", count: 8)
    let first = ArticleDraft(
      siteProfileID: profile.id, title: "Same title", slug: "first", draft: false,
      bodyMarkdown: body)
    let titleCollision = ArticleDraft(
      siteProfileID: profile.id, title: "Same title", slug: "second", draft: false,
      bodyMarkdown: body)
    let titleIssues = PreflightCheckService().run(
      draft: first, allDrafts: [first, titleCollision], profile: profile,
      includeRepositoryReadiness: false)
    let titleIssue = titleIssues.first { $0.ruleID == "content.title.duplicate" }
    XCTAssertEqual(titleIssue?.severity, .warning)
    XCTAssertTrue(titleIssue?.isOptionalOptimization == true)
    XCTAssertFalse(titleIssues.contains { $0.title == "发布路径重复" })

    let pathCollision = ArticleDraft(
      siteProfileID: profile.id, title: "Different title", slug: "first", draft: false,
      bodyMarkdown: body)
    let pathIssues = PreflightCheckService().run(
      draft: first, allDrafts: [first, pathCollision], profile: profile,
      includeRepositoryReadiness: false)
    XCTAssertTrue(pathIssues.contains { $0.title == "发布路径重复" && $0.severity == .error })
  }

  func testImageDuplicatePublishPathIsNotAnOptionalOptimization() {
    let issue = ImageWorkbenchIssue(
      severity: .warning, kind: .duplicatePublishPath,
      title: "图片发布路径重复", message: "两个附件共用同一路径")
    let duplicateSource = ImageWorkbenchIssue(
      severity: .warning, kind: .duplicateSource,
      title: "源图重复使用", message: "同一源图被多次使用")
    XCTAssertFalse(issue.isOptionalOptimization)
    XCTAssertTrue(duplicateSource.isOptionalOptimization)
  }

  private func make(
    issues: [DraftPublishStatus.Issue] = [],
    pendingCount: Int = 0,
    accountIsBlocked: Bool = false,
    accountDetail: String? = nil,
    readiness: LocalPublishReadiness? = nil,
    isLoading: Bool = false
  ) -> DraftPublishStatus {
    DraftPublishStatus(
      issues: issues,
      pendingCount: pendingCount,
      accountIsBlocked: accountIsBlocked,
      accountDetail: accountDetail,
      readiness: readiness,
      isLoading: isLoading
    )
  }

  private func readiness(
    write: LocalPublishActionReadiness = .ready,
    commit: LocalPublishActionReadiness = .ready,
    writeIssues: [PreflightIssue] = []
  ) -> LocalPublishReadiness {
    LocalPublishReadiness(
      writeReadiness: write,
      commitReadiness: commit,
      changedFileCount: 1,
      fileCount: 1,
      writeBlockingIssues: writeIssues,
      commitBlockingIssues: [],
      warningIssues: []
    )
  }
}
