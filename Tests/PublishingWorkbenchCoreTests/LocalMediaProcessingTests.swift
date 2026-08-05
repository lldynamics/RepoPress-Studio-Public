import PublishingWorkbenchCore
import XCTest

final class LocalProcessingAndPreviewTests: XCTestCase {
  func testLocalKaTeXPreviewRendersCommonFormulaAndKeepsCodeLiteral() {
    let html = MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(
      #"""
      公式 $\frac{a}{b}+\alpha^2$。

      ```
      $\frac{not}{rendered}$
      ```
      """#
    )
    XCTAssertTrue(html.contains("local-katex-inline"))
    XCTAssertTrue(html.contains("math-fraction"))
    XCTAssertTrue(html.contains("α"))
    XCTAssertTrue(html.contains("\\frac{not}"))
    XCTAssertFalse(html.contains("<script"))
  }
}
