import Foundation
import PublishingCoreSupport
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownInlineDiagnosticEnhancementTests: XCTestCase {
  func testFindsBareURLButIgnoresMarkdownLinkAndCode() {
    let markdown = """
      正文 https://example.com/a
      [官网](https://example.com/b)
      `https://example.com/c`
      """

    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)
      .filter { $0.id.hasPrefix("bare-url-") }

    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics.first?.replacement, "[链接](https://example.com/a)")
  }

  func testFindsUnclosedFenceAndChineseOrderedListGap() {
    let markdown = """
      1、第一项
      3、第三项

      ```swift
      print("hello")
      """

    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("ordered-list-sequence-") })
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("unclosed-code-fence-") })
  }

  func testFindsMissingInternalArticleButIgnoresKnownTargetAndCode() {
    let markdown = """
      [[已有文章]]
      [[不存在]]
      `[[代码示例]]`
      """
    let context = MarkdownInlineDiagnosticContext(
      knownArticleTitles: ["已有文章"]
    )

    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(
      in: markdown,
      context: context
    ).filter { $0.id.hasPrefix("missing-internal-link-") }

    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertTrue(diagnostics.first?.message.contains("不存在") == true)
  }

  func testInlineDiagnosticsOfferSafeHeadingAndImageFixes() throws {
    let markdown = "# 标题\n\n### 跳级\n\n![](images/cover-photo.png)\n\n引用[^missing]"
    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)

    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("heading-jump") })
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("image-alt") })
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("missing-footnote") && $0.severity == .error })

    let image = try XCTUnwrap(diagnostics.first { $0.id.hasPrefix("image-alt") })
    let edit = try XCTUnwrap(MarkdownInlineDiagnosticService.quickFix(for: image, in: markdown))
    let fixed = (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
    XCTAssertTrue(fixed.contains("![cover photo](images/cover-photo.png)"))
  }

  func testInlineDiagnosticsReportUnsafeEmbeddedHTML() {
    let markdown = #"正文 <img src="javascript:alert(1)" onerror="run()">"#

    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)

    XCTAssertTrue(diagnostics.contains { $0.title == CoreL10n.text("HTML 链接已拦截") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("onerror") && $0.severity == .error })
  }
}
