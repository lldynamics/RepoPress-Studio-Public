import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownPreviewTitleServiceTests: XCTestCase {
  func testRemovesLeadingATXHeadingWhenItMatchesArticleTitle() {
    let markdown = "# 未命名文章\n\n从这里开始写作。"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "未命名文章", markdown: markdown),
      "从这里开始写作。"
    )
  }

  func testMatchesCommonInlineMarkdownFormattingInHeading() {
    let markdown = "# **Mac 编辑器** #\n\n正文"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "Mac 编辑器", markdown: markdown),
      "正文"
    )
  }

  func testRemovesLegacyBoldWrappedHeadingMarker() {
    let markdown = "**# 未命名文章**\n\n从这里开始写作。"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "未命名文章", markdown: markdown),
      "从这里开始写作。"
    )
  }

  func testRemovesMatchingSetextHeading() {
    let markdown = "写作工作流\n====\n\n正文"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "写作工作流", markdown: markdown),
      "正文"
    )
  }

  func testKeepsHeadingWhenItDoesNotMatchArticleTitle() {
    let markdown = "# 不同的章节标题\n\n正文"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "文章标题", markdown: markdown),
      markdown
    )
  }

  func testKeepsMatchingHeadingWhenItIsNotTheFirstContentBlock() {
    let markdown = "导语\n\n# 文章标题\n\n正文"

    XCTAssertEqual(
      MarkdownPreviewTitleService.bodyMarkdown(title: "文章标题", markdown: markdown),
      markdown
    )
  }
}
