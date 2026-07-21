import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownHTMLRenderingServiceTests: XCTestCase {
  func testPreservesGuideArticleBlockStructure() {
    let markdown = """
    # 开始使用

    这是第一段。

    ## 推荐顺序

    1. 连接站点
    2. 编辑文章

    - **编辑**：集中输入。
    - **预览**：检查结果。
    """

    let html = MarkdownHTMLRenderingService.renderBody(markdown)

    XCTAssertTrue(html.contains("<h1>开始使用</h1>"))
    XCTAssertTrue(html.contains("<p>这是第一段。</p>"))
    XCTAssertTrue(html.contains("<h2>推荐顺序</h2>"))
    XCTAssertTrue(html.contains("<ol>"))
    XCTAssertTrue(html.contains("<li><p>连接站点</p>"))
    XCTAssertTrue(html.contains("<ul>"))
    XCTAssertTrue(html.contains("<strong>预览</strong>"))
  }

  func testRendersHardBreakAndKeepsParagraphsSeparate() {
    let html = MarkdownHTMLRenderingService.renderBody(
      "第一行  \n第二行\n\n新段落"
    )

    XCTAssertTrue(html.contains("第一行<br>\n第二行"))
    XCTAssertTrue(html.contains("</p>\n<p>新段落</p>"))
  }

  func testRendersCodeQuoteTableAndSafeLinks() {
    let markdown = """
    > 引用

    | 名称 | 值 |
    | --- | --- |
    | A | 1 |

    ```swift
    let value = "<safe>"
    ```

    [安全](https://example.com) [危险](javascript:alert(1))
    """

    let html = MarkdownHTMLRenderingService.renderBody(markdown)

    XCTAssertTrue(html.contains("<blockquote>"))
    XCTAssertTrue(html.contains("<table>"))
    XCTAssertTrue(html.contains("<th>名称</th>"))
    XCTAssertTrue(html.contains(#"<pre><code class="language-swift">"#))
    XCTAssertTrue(html.contains("&lt;safe&gt;"))
    XCTAssertTrue(html.contains(#"href="https://example.com""#))
    XCTAssertFalse(html.contains("javascript:"))
  }

  func testEscapesRawHTML() {
    let html = MarkdownHTMLRenderingService.renderBody(
      "<script>alert('preview')</script>"
    )

    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
  }

  func testExplicitPreviewRendererAllowsSanitizedDetailsButNotScript() {
    let markdown = """
    <details open><summary>查看详情</summary><mark>安全内容</mark></details>

    <script>alert('unsafe')</script>
    """

    let html = MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(markdown)

    XCTAssertTrue(html.contains("<details open><summary>查看详情</summary><mark>安全内容</mark></details>"))
    XCTAssertFalse(html.contains("<p><details"))
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
  }
}
