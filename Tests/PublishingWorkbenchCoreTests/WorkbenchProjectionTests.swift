import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchProjectionTests: XCTestCase {
  func testDraftListProjectionScopesAndSelectsWithoutStoreState() {
    let profileID = UUID()
    let otherProfileID = UUID()
    let siteDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "站点文章",
      date: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 20)
    )
    let otherSiteDraft = ArticleDraft(
      siteProfileID: otherProfileID,
      title: "其他站点文章",
      date: Date(timeIntervalSince1970: 30),
      updatedAt: Date(timeIntervalSince1970: 40)
    )
    let generalDraft = ArticleDraft(
      siteProfileID: profileID,
      scope: .general,
      title: "通用草稿",
      date: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: 60)
    )
    let drafts = [siteDraft, otherSiteDraft, generalDraft]

    XCTAssertEqual(
      DraftListProjection.siteDrafts(drafts, for: profileID).map(\.id),
      [siteDraft.id]
    )
    XCTAssertEqual(
      DraftListProjection.writingDrafts(
        drafts,
        activeProfileID: profileID,
        scope: .general
      ).map(\.id),
      [generalDraft.id]
    )
    XCTAssertEqual(
      DraftListProjection.selectedDraft(
        drafts,
        selectedDraftID: siteDraft.id,
        activeProfileID: profileID,
        scope: .currentSite
      )?.id,
      siteDraft.id
    )

    let statistics = DraftListProjection.statistics(drafts, activeProfileID: profileID)
    XCTAssertEqual(statistics.totalCount, 3)
    XCTAssertEqual(statistics.siteDraftCount, 1)
    XCTAssertEqual(statistics.generalDraftCount, 1)
  }

  func testDraftListProjectionUsesStableSortRules() {
    let profileID = UUID()
    let older = ArticleDraft(
      siteProfileID: profileID,
      title: "B",
      date: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = ArticleDraft(
      siteProfileID: profileID,
      title: "A",
      date: Date(timeIntervalSince1970: 20),
      updatedAt: Date(timeIntervalSince1970: 20)
    )

    XCTAssertEqual(
      DraftListProjection.sorted(
        [older, newer],
        by: .updatedNewest
      ).map(\.id),
      [newer.id, older.id]
    )
    XCTAssertEqual(
      DraftListProjection.sorted(
        [older, newer],
        by: .titleAscending
      ).map(\.id),
      [newer.id, older.id]
    )
  }

  func testContentHealthProjectionAggregatesRiskAndStatistics() {
    let warning = PreflightIssue(
      severity: .warning,
      title: "疑似本机路径",
      message: "请确认公开内容",
      category: .publicRisk
    )
    let summary = DraftPreflightSummary(
      draftID: UUID(),
      draftTitle: "文章",
      markdownPath: "content/article.md",
      issues: [warning]
    )

    let risk = ContentHealthProjection.publicRiskSummary(from: [summary])
    let statistics = ContentHealthProjection.statistics(from: [summary])

    XCTAssertEqual(risk.warningCount, 1)
    XCTAssertEqual(ContentHealthProjection.publicRiskDraftSummaries(from: [summary]).count, 1)
    XCTAssertEqual(statistics.draftCount, 1)
    XCTAssertEqual(statistics.issueCount, 1)
    XCTAssertEqual(statistics.warningCount, 1)
    XCTAssertEqual(statistics.passingDraftCount, 0)
  }

  func testPublishingReadinessProjectionKeepsRepositoryBoundaryOutsideProjection() {
    let package = PublishPackage(
      draftID: UUID(),
      title: "文章",
      markdownPath: "content/article.md",
      files: [],
      commitMessage: "更新文章",
      reviewBranchName: "codex/article",
      reviewTitle: "更新文章",
      reviewChecklist: []
    )
    let preview = LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    let notScanned = PreflightIssue(
      severity: .error,
      title: "仓库尚未扫描",
      message: "请先刷新仓库状态",
      field: "repository"
    )

    let readiness = PublishingReadinessProjection.makeReadiness(
      package: package,
      preview: preview,
      draftIssuesWithoutRepository: [],
      draftIssuesWithRepository: [],
      repositoryBlockingIssues: [notScanned]
    )

    XCTAssertEqual(readiness.writeReadiness, .unchanged)
    XCTAssertEqual(readiness.commitReadiness, .blocked)
    XCTAssertEqual(readiness.commitBlockingIssues, [notScanned])
    XCTAssertEqual(readiness.changedFileCount, 0)
  }
}
