import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class HTMLSourceDiagnosticServiceTests: XCTestCase {
  func testReportsMismatchedAndUnclosedTagsWithUTF16Location() throws {
    let source = "🙂\n<div><span>内容</div>"
    let diagnostics = HTMLSourceDiagnosticService.diagnostics(in: source)
    let mismatch = try XCTUnwrap(diagnostics.first { $0.severity == .error })

    XCTAssertEqual(mismatch.line, 2)
    XCTAssertEqual(
      (source as NSString).substring(with: mismatch.range),
      "</div>"
    )
    XCTAssertTrue(diagnostics.contains { $0.title.contains("没有闭合") })
  }

  func testIgnoresVoidTagsCommentsScriptsAndTemplateExpressions() {
    let source = """
    <!doctype html>
    <!-- <div> -->
    <img src="cover.png"><br>
    <script>const value = "<div>";</script>
    {% if page %}<main>{{ page.title }}</main>{% endif %}
    """

    XCTAssertTrue(HTMLSourceDiagnosticService.diagnostics(in: source).isEmpty)
  }

  func testBalancedDocumentHasNoDiagnostics() {
    let source = "<html><body><main><p>正文</p></main></body></html>"
    XCTAssertTrue(HTMLSourceDiagnosticService.diagnostics(in: source).isEmpty)
  }
}
