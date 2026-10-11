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
