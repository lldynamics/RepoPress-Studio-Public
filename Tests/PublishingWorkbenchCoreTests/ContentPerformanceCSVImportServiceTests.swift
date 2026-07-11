import XCTest
@testable import PublishingWorkbenchCore

final class ContentPerformanceCSVImportServiceTests: XCTestCase {
  func testImportsQuotedMetricsAndMatchesMarkdownPath() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(siteProfileID: profile.id, title: "发布流程", slug: "publish-flow")
    let csv = "markdown_path,page_views,visitors,date\ncontent/posts/publish-flow.md,\"1,240\",800,2026-07-01\n"

    let report = try ContentPerformanceCSVImportService().import(
      data: try XCTUnwrap(csv.data(using: .utf8)),
      profile: profile,
      drafts: [draft]
    )

    XCTAssertEqual(report.importedSnapshots.count, 1)
    XCTAssertEqual(report.importedSnapshots[0].draftID, draft.id)
    XCTAssertEqual(report.importedSnapshots[0].pageViews, 1240)
    XCTAssertEqual(report.importedSnapshots[0].visitors, 800)
    XCTAssertEqual(report.importedSnapshots[0].sourceName, "CSV 导入")
    XCTAssertEqual(report.statusMessage, "CSV 导入：已导入 1 条内容表现快照。")
  }

  func testReportsUnmatchedAndInvalidRowsWithoutImportingThem() throws {
    let profile = SiteProfile.defaultProfile
    let csv = "title,views,users\n不存在文章,10,4\n坏数据,not-a-number,3\n"

    let report = try ContentPerformanceCSVImportService().import(
      data: try XCTUnwrap(csv.data(using: .utf8)),
      profile: profile,
      drafts: []
    )

    XCTAssertTrue(report.importedSnapshots.isEmpty)
    XCTAssertEqual(report.unmatchedRows, ["不存在文章"])
    XCTAssertEqual(report.skippedRowCount, 1)
    XCTAssertEqual(report.statusMessage, "CSV 导入：已导入 0 条内容表现快照，跳过 1 行，有 1 行未匹配到现有文章。")
  }

  func testImportsCSVFileAsynchronously() async throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Async Import", slug: "async-import")
    let csv = "title,views,users\nAsync Import,42,21\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("content-performance-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try csv.write(to: url, atomically: true, encoding: .utf8)

    let report = try await ContentPerformanceCSVImportService().importFile(
      at: url,
      profile: profile,
      drafts: [draft]
    )

    XCTAssertEqual(report.importedSnapshots.first?.pageViews, 42)
    XCTAssertEqual(report.importedSnapshots.first?.visitors, 21)
  }
}
