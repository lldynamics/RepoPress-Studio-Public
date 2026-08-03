import Foundation
import XCTest

@testable import PublishingWorkbenchCore

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
}
