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
        ),
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
    let rows = [
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

    let partitionedIDs = queue.blockingRows.map(\.draftID)
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
      issueScope: .all,
      severityFilter: .errors
    )

    XCTAssertEqual(snapshot.errorCount, 1)
    XCTAssertEqual(snapshot.warningCount, 1)
    XCTAssertEqual(snapshot.passingDraftCount, 1)
    XCTAssertEqual(presentation.rows.map(\.draftID), [draftID])
    XCTAssertEqual(presentation.rows.first?.issues, [error])
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
}
