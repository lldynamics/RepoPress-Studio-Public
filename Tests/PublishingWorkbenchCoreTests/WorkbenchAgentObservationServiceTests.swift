import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchAgentObservationServiceTests: XCTestCase {
  private let profileID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1))

  func testDraftSearchDeduplicatesAndClampsOutput() {
    let draftID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 2))
    let older = makeDraft(
      id: draftID,
      title: String(repeating: "旧标题 ", count: 200),
      body: "Swift 旧内容",
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = makeDraft(
      id: draftID,
      title: "Swift 新标题",
      body: String(repeating: "正文 ", count: 10_000) + "Swift",
      updatedAt: Date(timeIntervalSince1970: 20)
    )
    let results = WorkbenchAgentDraftSearchService().search(
      query: String(repeating: "Swift ", count: 200),
      drafts: [older, newer],
      limit: 0
    )

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.draftID, draftID)
    XCTAssertEqual(results.first?.title, "Swift 新标题")
    XCTAssertEqual(results.first?.field, "title")
    XCTAssertLessThanOrEqual(results.first?.snippet.count ?? .max, WorkbenchAgentDraftSearchService.maximumOutputTextLength)
  }

  func testDraftSearchLimitNeverExceedsTwenty() {
    let drafts = (0..<30).map { index in
      makeDraft(title: "Swift 文章 " + String(index), body: "内容")
    }

    let results = WorkbenchAgentDraftSearchService().search(
      query: "Swift",
      drafts: drafts,
      limit: 10_000
    )

    XCTAssertEqual(results.count, 20)
    XCTAssertEqual(Set(results.map(\.draftID)).count, results.count)
  }

  func testContentAuditReportsCurrentSnapshotWithoutRepairClaim() throws {
    let body = String(repeating: "内容 ", count: 12_000)
    let draft = makeDraft(
      title: "短",
      summary: "",
      body: body
    )

    let summary = try XCTUnwrap(
      WorkbenchAgentContentAuditService().audit(
        draft: draft,
        profile: SiteProfile.defaultProfile
      )
    )

    XCTAssertEqual(summary.draftID, draft.id)
    XCTAssertEqual(summary.status, .warning)
    XCTAssertEqual(summary.repairStatus, .notPerformed)
    XCTAssertTrue(summary.observationNote.contains("未执行修改或修复"))
    XCTAssertTrue(summary.isPartial)
    XCTAssertLessThanOrEqual(
      summary.bodyCharacterCount,
      WorkbenchAgentContentAuditService.maximumArticleTextLength
    )
    XCTAssertLessThanOrEqual(
      summary.findings.count,
      WorkbenchAgentContentAuditService.maximumFindingCount
    )
  }

  func testStaticLinkInspectionSeparatesSyntaxFromReachability() throws {
    let markdown = """
    [Swift](https://example.com/docs "文档")
    ![封面](images/cover.png)
    ![]()
    [未闭合](relative/path
    ```markdown
    [代码中的链接](https://example.com/ignored)
    ```
    """

    let inspection = try XCTUnwrap(
      WorkbenchAgentStaticLinkInspectionService().inspect(markdown: markdown)
    )

    XCTAssertEqual(inspection.discoveredLinkCount, 2)
    XCTAssertEqual(inspection.discoveredImageCount, 2)
    XCTAssertTrue(inspection.references.contains { $0.destination == "https://example.com/docs" })
    XCTAssertTrue(inspection.references.contains { $0.kind == .image && $0.destination == "" })
    XCTAssertTrue(inspection.diagnostics.contains { $0.kind == .emptyLabel })
    XCTAssertTrue(inspection.diagnostics.contains { $0.kind == .emptyDestination })
    XCTAssertTrue(inspection.diagnostics.contains { $0.kind == .unclosedDestination })
    XCTAssertEqual(inspection.reachability, .notVerified)
    XCTAssertFalse(inspection.networkWasVerified)
  }

  func testStaticLinkInspectionBoundsHugeInput() throws {
    let markdown = String(repeating: "[link](https://example.com)\n", count: 10_000)
    let inspection = try XCTUnwrap(
      WorkbenchAgentStaticLinkInspectionService().inspect(markdown: markdown)
    )

    XCTAssertTrue(inspection.inputWasTruncated)
    XCTAssertLessThanOrEqual(
      inspection.scannedCharacterCount,
      WorkbenchAgentStaticLinkInspectionService.maximumInputLength
    )
    XCTAssertLessThanOrEqual(
      inspection.references.count,
      WorkbenchAgentStaticLinkInspectionService.maximumReferenceCount
    )
  }

  func testImageReportFormatterNeverFabricatesMissingReport() {
    let unavailable = WorkbenchAgentImageReportFormatter.summary(for: nil)

    XCTAssertEqual(unavailable.availability, .unavailable)
    XCTAssertNil(unavailable.draftID)
    XCTAssertTrue(unavailable.unavailableReason?.contains("没有真实") == true)
    XCTAssertEqual(unavailable.repairStatus, .notPerformed)
  }

  func testImageReportFormatterUsesBoundedRealIssues() {
    let draftID = UUID()
    let item = ImageWorkbenchItem(
      attachmentID: UUID(),
      originalFilename: "cover.jpg",
      relativePublishPath: "images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      sourceFilePath: nil,
      byteSize: 10,
      dimensions: ImageDimensions(width: 100, height: 100),
      fileExists: false,
      isCover: true,
      isReferencedInMarkdown: true,
      missingAltText: true,
      missingCaption: false,
      canOptimizeJPEG: true
    )
    let issues = (0..<30).map { index in
      ImageWorkbenchIssue(
        severity: index.isMultiple(of: 2) ? .warning : .error,
        kind: .missingAltText,
        title: "问题 (index)",
        message: String(repeating: "详情 ", count: 500)
      )
    }
    let report = ImageWorkbenchReport(
      draftID: draftID,
      generatedAt: Date(timeIntervalSince1970: 100),
      items: [item],
      coverStatus: ImageCoverPublishStatus(
        state: .missingSource,
        frontMatterFieldPath: "extra.cover"
      ),
      issues: issues
    )

    let summary = WorkbenchAgentImageReportFormatter.summary(
      for: report,
      maximumIssues: 100
    )

    XCTAssertEqual(summary.availability, .available)
    XCTAssertEqual(summary.draftID, draftID)
    XCTAssertEqual(summary.imageCount, 1)
    XCTAssertEqual(summary.issueCount, 30)
    XCTAssertEqual(summary.errorCount, 15)
    XCTAssertEqual(summary.missingAltTextCount, 1)
    XCTAssertEqual(summary.coverState, "missingSource")
    XCTAssertEqual(summary.issues.count, WorkbenchAgentImageReportFormatter.maximumIssueCount)
    XCTAssertEqual(summary.omittedIssueCount, 10)
    XCTAssertTrue(summary.issues.allSatisfy { $0.message.count <= WorkbenchAgentImageReportFormatter.maximumOutputTextLength })
    XCTAssertEqual(summary.repairStatus, .notPerformed)
  }

  private func makeDraft(
    id: UUID = UUID(),
    title: String,
    summary: String = "摘要",
    body: String,
    updatedAt: Date = Date(timeIntervalSince1970: 100)
  ) -> ArticleDraft {
    ArticleDraft(
      id: id,
      siteProfileID: profileID,
      title: title,
      summary: summary,
      bodyMarkdown: body,
      updatedAt: updatedAt
    )
  }
}
