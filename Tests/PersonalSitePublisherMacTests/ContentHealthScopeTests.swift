import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ContentHealthScopeTests: XCTestCase {
  func testCurrentArticleIsInitialScopeWhenSelectionExistsAndFallsBackWithoutSelection() {
    let selected = UUID()

    XCTAssertEqual(ContentHealthScope.initial(selectedDraftID: selected), .currentArticle)
    XCTAssertEqual(
      ContentHealthScope.currentArticle.resolved(selectedDraftID: selected),
      .currentArticle(selected)
    )
    let nextSelected = UUID()
    XCTAssertEqual(
      ContentHealthScope.currentArticle.resolved(selectedDraftID: nextSelected),
      .currentArticle(nextSelected)
    )
    XCTAssertEqual(
      ContentHealthScope.currentArticle.resolved(selectedDraftID: nil),
      .wholeSite
    )
    XCTAssertEqual(ContentHealthScope.initial(selectedDraftID: nil), .wholeSite)
  }

  func testCurrentArticlePresentationOnlyCountsAndListsTheSelectedArticle() {
    let selectedID = UUID()
    let otherID = UUID()
    let snapshot = makeSnapshot(
      summaries: [
        summary(
          selectedID, title: "Current", path: "content/current.md", issues: [error("Current error")]
        ),
        summary(
          otherID, title: "Other", path: "content/other.md", issues: [warning("Other warning")]),
      ],
      siteIssues: [error("Site blocker")]
    )

    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .currentArticle(selectedID)
    )

    XCTAssertEqual(presentation.rows.map(\.draftID), [selectedID])
    XCTAssertEqual(presentation.scopeDraftCount, 1)
    XCTAssertEqual(presentation.scopeErrorCount, 1)
    XCTAssertEqual(presentation.scopeWarningCount, 0)
    XCTAssertEqual(presentation.wholeSiteErrorCount, 2)
    XCTAssertEqual(presentation.wholeSiteWarningCount, 1)
    XCTAssertEqual(presentation.globalBlockingSiteIssueCount, 1)
  }

  func testWholeSiteScopeKeepsSiteCountsAtTheBoundary() {
    let currentID = UUID()
    let snapshot = makeSnapshot(
      summaries: [
        summary(
          currentID, title: "Current", path: "content/current.md",
          issues: [warning("Draft warning")])
      ],
      siteIssues: [error("Site blocker"), warning("Site warning")]
    )

    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .wholeSite
    )

    XCTAssertEqual(presentation.scopeDraftCount, 1)
    XCTAssertEqual(presentation.scopeErrorCount, 1)
    XCTAssertEqual(presentation.scopeWarningCount, 2)
  }

  func testCurrentArticleCanBeClearWhileTheWholeSiteStillHasArticleErrors() {
    let selectedID = UUID()
    let snapshot = makeSnapshot(summaries: [
      summary(selectedID, title: "Clear", path: "content/clear.md", issues: []),
      summary(
        UUID(), title: "Elsewhere", path: "content/elsewhere.md", issues: [error("Elsewhere error")]
      ),
    ])

    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .currentArticle(selectedID)
    )

    XCTAssertTrue(presentation.rows.isEmpty)
    XCTAssertEqual(presentation.scopeErrorCount, 0)
    XCTAssertEqual(presentation.wholeSiteErrorCount, 1)
  }

  func testDuplicatePathIsComputedFromEntireSnapshotAndGroupsByPathAndReason() {
    let selectedID = UUID()
    let duplicateID = UUID()
    let path = "content/posts/shared.md"
    let snapshot = makeSnapshot(
      summaries: [
        summary(selectedID, title: "Current", path: path, issues: [warning("Current warning")]),
        summary(
          duplicateID, title: "Elsewhere", path: path, issues: [warning("Elsewhere warning")]),
      ]
    )
    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .currentArticle(selectedID)
    )

    XCTAssertEqual(presentation.duplicateMarkdownPaths, [path])
    let sitePresentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .wholeSite
    )
    let groups = ContentHealthRootCausePresentation.groups(
      rows: sitePresentation.rows,
      duplicateMarkdownPaths: sitePresentation.duplicateMarkdownPaths
    )
    XCTAssertEqual(
      groups.map(\.id),
      ["root-cause:duplicate-path.content/posts/shared.md|reason.markdown-path-collision"]
    )
    XCTAssertEqual(groups.first?.title, "重复发布路径：content/posts/shared.md")
    XCTAssertEqual(groups.first?.rows.map(\.draftID), [selectedID, duplicateID])
  }

  func testPresentationMatchRejectsAStaleSelectionScope() {
    let firstID = UUID()
    let secondID = UUID()
    let snapshot = makeSnapshot(summaries: [
      summary(firstID, title: "First", path: "content/first.md", issues: [warning("Warning")]),
      summary(secondID, title: "Second", path: "content/second.md", issues: [warning("Warning")]),
    ])
    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot,
      filter: .overview,
      severityFilter: .all,
      scope: .currentArticle(firstID)
    )

    XCTAssertFalse(
      presentation.matches(
        snapshotID: snapshot.id,
        filter: .overview,
        severityFilter: .all,
        scope: .currentArticle(secondID)
      )
    )
  }

  func testMaskedDisplayTextNeverBecomesADuplicateRepositoryPath() {
    let first = UUID()
    let second = UUID()
    let hidden = "内容已遮挡，打开文章或关闭私密遮挡后查看。"
    var snapshot = makeSnapshot(summaries: [
      summary(first, title: "Private A", path: hidden, issues: [error("Existing blocker")]),
      summary(second, title: "Private B", path: hidden, issues: [warning("Existing warning")]),
    ])
    snapshot.maskedDraftIDs = [first, second]
    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot, filter: .overview, severityFilter: .all
    )
    XCTAssertTrue(presentation.duplicateMarkdownPaths.isEmpty)
    XCTAssertEqual(presentation.rows.count, 2)
    XCTAssertEqual(presentation.scopeErrorCount, 1)
    XCTAssertEqual(presentation.scopeWarningCount, 1)
  }

  private func makeSnapshot(
    summaries: [DraftPreflightSummary],
    siteIssues: [PreflightIssue] = []
  ) -> ContentHealthSnapshot {
    ContentHealthSnapshot(
      id: UUID(),
      generatedAt: .now,
      profileID: UUID(),
      profileName: "Test",
      publicRiskDraftSummaries: summaries,
      aiFixQueueItems: [],
      sitePreflightIssues: siteIssues,
      contentHealthSummaries: summaries,
      slugChangeImpacts: [:],
      errorCount: summaries.flatMap(\.issues).filter { $0.severity == .error }.count
        + siteIssues.filter { $0.severity == .error }.count,
      warningCount: summaries.flatMap(\.issues).filter { $0.severity == .warning }.count
        + siteIssues.filter { $0.severity == .warning }.count,
      passingDraftCount: 0
    )
  }

  private func summary(
    _ id: UUID,
    title: String,
    path: String,
    issues: [PreflightIssue]
  ) -> DraftPreflightSummary {
    DraftPreflightSummary(draftID: id, draftTitle: title, markdownPath: path, issues: issues)
  }

  private func error(_ title: String) -> PreflightIssue {
    PreflightIssue(severity: .error, title: title, message: title)
  }

  private func warning(_ title: String) -> PreflightIssue {
    PreflightIssue(severity: .warning, title: title, message: title)
  }
}
