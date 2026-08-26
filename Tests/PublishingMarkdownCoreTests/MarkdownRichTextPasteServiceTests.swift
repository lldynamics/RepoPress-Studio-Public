import XCTest
@testable import PublishingMarkdownCore

final class MarkdownRichTextPasteServiceTests: XCTestCase {
  private let service = MarkdownRichTextPasteService()

  func testConvertsHeadingsFormattingListsLinksAndRemovesTrackingParameters() throws {
    let html = """
    <main style="font-family: Comic Sans">
      <h2>发布说明</h2>
      <p>请阅读 <strong>完整</strong> <a href="https://example.com/guide?id=42&amp;utm_source=mail&amp;fbclid=secret">指南</a>。</p>
      <ol start="3"><li>检查草稿</li><li>发布站点<ul><li>确认状态</li></ul></li></ol>
      <script>steal()</script>
    </main>
    """

    let conversion = try XCTUnwrap(service.conversion(fromHTML: html))

    XCTAssertEqual(
      conversion.markdown,
      """
      ## 发布说明

      请阅读 **完整** [指南](https://example.com/guide?id=42)。

      3. 检查草稿
      4. 发布站点
        - 确认状态
      """
    )
    XCTAssertEqual(conversion.removedTrackingParameterCount, 2)
    XCTAssertFalse(conversion.markdown.contains("font-family"))
    XCTAssertFalse(conversion.markdown.contains("steal"))
  }

  func testConvertsTableCodeBlockAndImage() throws {
    let html = """
    <table>
      <tr><th align="left">名称</th><th style="text-align: right">数量</th></tr>
      <tr><td>苹果 | 梨</td><td>2</td></tr>
    </table>
    <pre><code class="language-swift">let value = `raw`</code></pre>
    <p><img src="https://example.com/image.png?utm_campaign=spring" alt="结构图"></p>
    """

    let conversion = try XCTUnwrap(service.conversion(fromHTML: html))

    XCTAssertTrue(conversion.markdown.contains("| 名称 | 数量 |"))
    XCTAssertTrue(conversion.markdown.contains("| :--- | ---: |"))
    XCTAssertTrue(conversion.markdown.contains(#"| 苹果 \| 梨 | 2 |"#))
    XCTAssertTrue(conversion.markdown.contains("```swift\nlet value = `raw`\n```"))
    XCTAssertTrue(conversion.markdown.contains("![结构图](https://example.com/image.png)"))
    XCTAssertEqual(conversion.removedTrackingParameterCount, 1)
  }

  func testResolvesRelativeDestinationsAndRejectsUnsafeSchemes() throws {
    let html = """
    <p><a href="guide/page.html?utm_medium=copy#intro">相对链接</a></p>
    <p><a href="javascript:alert(1)">不安全链接</a></p>
    """

    let conversion = try XCTUnwrap(service.conversion(
      fromHTML: html,
      baseURL: URL(string: "https://example.com/docs/")
    ))

    XCTAssertTrue(conversion.markdown.contains("[相对链接](https://example.com/docs/guide/page.html#intro)"))
    XCTAssertTrue(conversion.markdown.contains("不安全链接"))
    XCTAssertFalse(conversion.markdown.contains("javascript:"))
  }

  func testBuildsSelectionReplacementEdit() throws {
    let markdown = "保留 旧内容 结尾"
    let range = (markdown as NSString).range(of: "旧内容")
    let conversion = try XCTUnwrap(service.conversion(
      fromHTML: "<p><em>新内容</em></p>"
    ))
    let edit = try XCTUnwrap(service.edit(
      in: markdown,
      selectedRange: range,
      conversion: conversion
    ))

    XCTAssertEqual(
      (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement),
      "保留 *新内容* 结尾"
    )
    XCTAssertEqual(edit.selectedRange, NSRange(location: 8, length: 0))
  }
}
