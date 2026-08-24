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

  func testPreviewSourceLineAnchorsTrackVariableHeightBlocksAndFenceBlankLines() {
    let markdown =
      "# 标题\n\n第一段。\n\n![图片](https://example.com/large.png)\n\n```swift\nlet first = 1\n\nlet last = 3\n```\n\n## 结尾"

    let html =
      MarkdownHTMLRenderingService
      .renderPreviewBodyWithSourceLineAnchorsAllowingSanitizedHTML(markdown)

    XCTAssertTrue(html.contains(#"<h1 data-source-line="1">标题</h1>"#))
    XCTAssertTrue(html.contains(#"<p data-source-line="3">第一段。</p>"#))
    XCTAssertTrue(html.contains(#"<p data-source-line="5"><img"#))
    XCTAssertTrue(html.contains(#"<pre data-source-line="7"><code class="language-swift">"#))
    XCTAssertTrue(html.contains("let first = 1\n\nlet last = 3"))
    XCTAssertTrue(html.contains(#"<h2 data-source-line="13">结尾</h2>"#))
  }

  func testPreviewSourceLineAnchorsCoverListsTablesQuotesAndThematicBreaks() {
    let markdown = "\n\n- 第一项\n- 第二项\n\n| 名称 | 值 |\n| --- | --- |\n| A | 1 |\n\n> 引用\n\n---"

    let html =
      MarkdownHTMLRenderingService
      .renderPreviewBodyWithSourceLineAnchorsAllowingSanitizedHTML(markdown)

    XCTAssertTrue(html.contains(#"<ul data-source-line="3">"#))
    XCTAssertTrue(html.contains(#"<table data-source-line="6">"#))
    XCTAssertTrue(html.contains(#"<blockquote data-source-line="10">"#))
    XCTAssertTrue(html.contains(#"<hr data-source-line="12">"#))
  }

  func testSourceLineAnchorsArePreviewOnlyAndHonorStartingLine() {
    let markdown = "# 标题\n\n正文"

    let anchoredPreview =
      MarkdownHTMLRenderingService
      .renderPreviewBodyWithSourceLineAnchorsAllowingSanitizedHTML(
        markdown,
        startingAtLine: 41
      )
    let ordinaryBody = MarkdownHTMLRenderingService.renderBody(markdown)
    let ordinaryPreview =
      MarkdownHTMLRenderingService
      .renderPreviewBodyAllowingSanitizedHTML(markdown)

    XCTAssertTrue(anchoredPreview.contains(#"<h1 data-source-line="41">"#))
    XCTAssertTrue(anchoredPreview.contains(#"<p data-source-line="43">"#))
    XCTAssertFalse(ordinaryBody.contains("data-source-line"))
    XCTAssertFalse(ordinaryPreview.contains("data-source-line"))
  }
}
