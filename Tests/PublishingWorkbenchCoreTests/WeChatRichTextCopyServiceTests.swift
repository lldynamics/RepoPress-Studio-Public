import XCTest

@testable import PublishingWorkbenchCore

final class WeChatRichTextCopyServiceTests: XCTestCase {
  func testRenderHTMLEmbedsInlineStylesForHeadingsAndParagraphs() {
    let markdown = """
    ## 二级标题

    这是一段测试文本，带有 **加粗** 和 `行内代码`。
    """
    let html = WeChatRichTextCopyService.renderHTML(markdown: markdown, title: "文章总标题")

    XCTAssertTrue(html.contains("font-family: -apple-system"))
    XCTAssertTrue(html.contains("border-bottom: 2px solid"))
    XCTAssertTrue(html.contains("border-left: 4px solid"))
    XCTAssertTrue(html.contains("二级标题"))
    XCTAssertTrue(html.contains("<strong style=\"font-weight: 700;"))
    XCTAssertTrue(html.contains("<code style=\"background-color: #f1f2f4;"))
  }

  func testRenderHTMLEmbedsStylesForQuotesAndCodeBlocks() {
    let markdown = """
    > 这是一句精选引文。

    ```swift
    print("Hello WeChat")
    ```
    """
    let html = WeChatRichTextCopyService.renderHTML(markdown: markdown)

    XCTAssertTrue(html.contains("<blockquote style=\"margin: 18px 0;"))
    XCTAssertTrue(html.contains("<pre style=\"background-color: #282c34;"))
    XCTAssertTrue(html.contains("Hello WeChat"))
  }

  func testRenderHTMLEmbedsStylesForTables() {
    let markdown = """
    | 平台 | 支持状态 |
    | --- | --- |
    | 微信公众号 | 完美支持 |
    | 知乎专栏 | 完美支持 |
    """
    let html = WeChatRichTextCopyService.renderHTML(markdown: markdown)

    XCTAssertTrue(html.contains("<table style=\"border-collapse: collapse;"))
    XCTAssertTrue(html.contains("<th style=\"background-color: #f6f8fa;"))
    XCTAssertTrue(html.contains("<td style=\"padding: 9px 14px;"))
  }
}
