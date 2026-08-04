import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownEditorAnalysisServiceTests: XCTestCase {
  private let markdown = """
  # 标题

  ### 跳级章节
  ![](images/cover-photo.png)

  ## 风险章节
  api_key = "abcdefghijklmnopqrstuvwxyz"

  引用[^missing]
  """

  func testBuildsDiagnosticsAndOutlineInOneSnapshot() {
    let snapshot = MarkdownEditorAnalysisService().analyze(markdown)

    XCTAssertTrue(snapshot.diagnostics.contains { $0.id.hasPrefix("heading-jump") })
    XCTAssertTrue(snapshot.diagnostics.contains { $0.id.hasPrefix("image-alt") })
    XCTAssertTrue(snapshot.diagnostics.contains { $0.id.hasPrefix("missing-footnote") })
    XCTAssertEqual(snapshot.outlineItems.map(\.title), ["跳级章节", "风险章节"])
    XCTAssertEqual(snapshot.outlineItems.last?.publicRiskSummary.errorCount, 1)
  }

  func testTypingAnalysisCanSkipOutlineWork() {
    let snapshot = MarkdownEditorAnalysisService().analyze(
      markdown,
      includeOutline: false
    )

    XCTAssertFalse(snapshot.diagnostics.isEmpty)
    XCTAssertTrue(snapshot.outlineItems.isEmpty)
  }

  func testBackgroundAnalysisMatchesSynchronousSnapshot() async {
    let service = MarkdownEditorAnalysisService()
    let expected = service.analyze(markdown)
    let background = await service.analyzeInBackground(markdown)

    XCTAssertEqual(background.diagnostics, expected.diagnostics)
    XCTAssertEqual(background.outlineItems.map(\.level), expected.outlineItems.map(\.level))
    XCTAssertEqual(background.outlineItems.map(\.title), expected.outlineItems.map(\.title))
    XCTAssertEqual(
      background.outlineItems.map(\.sectionRange),
      expected.outlineItems.map(\.sectionRange)
    )
    XCTAssertEqual(
      background.outlineItems.map(\.publicRiskSummary.errorCount),
      expected.outlineItems.map(\.publicRiskSummary.errorCount)
    )
  }
}
