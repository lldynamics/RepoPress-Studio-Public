import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class MarkdownEmbeddedHTMLServiceTests: XCTestCase {
  func testAllowsCommonFormattingHTMLWithoutChangingSourceSemantics() throws {
    let markdown = """
    开始

    <details open class="note">
    <summary>更多信息</summary>
    <mark>重点</mark>
    </details>
    """

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)

    XCTAssertEqual(prepared.replacements.count, 1)
    let replacement = try XCTUnwrap(prepared.replacements.first)
    XCTAssertTrue(replacement.isBlock)
    XCTAssertTrue(replacement.html.contains("<details open class=\"note\">"))
    XCTAssertTrue(replacement.html.contains("<summary>更多信息</summary>"))
    XCTAssertFalse(prepared.markdown.contains("<details"))
    XCTAssertTrue(prepared.issues.isEmpty)
  }

  func testRemovesEventStyleAndUnsafeURLAttributes() throws {
    let markdown = #"<a href="javascript:alert(1)" onclick="run()" style="color:red">链接</a>"#

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)
    let opening = try XCTUnwrap(prepared.replacements.first)

    XCTAssertEqual(opening.html, "<a>链接</a>")
    XCTAssertTrue(prepared.issues.contains {
      $0.severity == .error && $0.title == CoreL10n.text("HTML 链接已拦截")
    })
    XCTAssertTrue(prepared.issues.contains { $0.severity == .error && $0.message.contains("onclick") })
    XCTAssertTrue(prepared.issues.contains { $0.severity == .warning && $0.message.contains("style") })
  }

  func testUnsupportedExecutableTagRemainsEscapedByMarkdownRenderer() {
    let markdown = #"<script>alert("x")</script>"#

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(rendered.contains("&lt;script&gt;"))
    XCTAssertFalse(rendered.contains("<script>"))
    XCTAssertTrue(prepared.issues.contains { $0.severity == .error })
  }

  func testHTMLInsideFencedAndInlineCodeIsNotPrepared() {
    let markdown = """
    `<mark>inline</mark>`

    ```html
    <details><summary>code</summary></details>
    ```
    """

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)

    XCTAssertEqual(prepared.markdown, markdown)
    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.isEmpty)
  }

  func testHTMLInsideFourBacktickAndTildeFencesIsNotPrepared() {
    let markdown = """
    ````html
    <mark>four backticks</mark>
    ````

    ~~~html
    <details><summary>tilde fence</summary></details>
    ~~~
    """

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)

    XCTAssertEqual(prepared.markdown, markdown)
    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.isEmpty)
  }

  func testCommonMarkCodeVariantsNeverRestoreEmbeddedHTML() {
    let markdown = """
    ```html\r
    <mark>closing fence may be longer</mark>\r
    ````\r

        <img src=\"https://example.com/code.png\">

    ``<a href=\"https://example.com\">inline across delimiters</a>``
    """

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)

    XCTAssertEqual(prepared.markdown, markdown)
    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.isEmpty)
  }

  func testUnclosedFenceProtectsCodeThroughEndOfDocument() {
    let markdown = """
    ~~~html
    <details><summary>literal source</summary></details>
    """

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)

    XCTAssertEqual(prepared.markdown, markdown)
    XCTAssertTrue(prepared.replacements.isEmpty)
  }

  func testUnquotedEmojiAttributeDoesNotCrashParser() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<span title=🙂>正文</span>"
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)

    XCTAssertTrue(replacement.html.contains("title=\"🙂\""))
  }

  func testSafeLinksAndAccessibilityAttributesArePreserved() throws {
    let markdown = #"<a href="https://example.com" target="_blank" aria-label="示例">站点</a>"#

    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)
    let opening = try XCTUnwrap(prepared.replacements.first)

    XCTAssertTrue(opening.html.contains("href=\"https://example.com\""))
    XCTAssertTrue(opening.html.contains("target=\"_blank\""))
    XCTAssertTrue(opening.html.contains("aria-label=\"示例\""))
    XCTAssertTrue(opening.html.contains("rel=\"noopener noreferrer\""))
  }

  func testUppercaseBlankTargetIsNormalizedAndRelIsReplaced() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: #"<a href="https://example.com" target="_BLANK" rel="opener">站点</a>"#
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)

    XCTAssertTrue(replacement.html.contains("target=\"_blank\""))
    XCTAssertTrue(replacement.html.contains("rel=\"noopener noreferrer\""))
    XCTAssertFalse(replacement.html.contains("rel=\"opener\""))
  }

  func testInlineTokenInsideGeneratedAttributeRestoresAsEscapedText() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "![<mark>说明</mark>](image.png)"
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)
    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: rendered,
      replacements: prepared.replacements
    )

    XCTAssertFalse(restored.contains(replacement.token))
    XCTAssertFalse(restored.contains("alt=\"<mark>"))
    XCTAssertTrue(restored.contains("&lt;mark&gt;说明&lt;/mark&gt;"))
  }

  func testAnchorTokenInsideMarkdownLinkDoesNotCreateNestedAnchor() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: #"[<a href="https://inner.example">内部</a>](https://outer.example)"#
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)
    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: MarkdownHTMLRenderingService.renderBody(prepared.markdown),
      replacements: prepared.replacements
    )

    XCTAssertFalse(restored.contains(replacement.token))
    XCTAssertEqual(restored.components(separatedBy: "<a ").count - 1, 1)
    XCTAssertTrue(restored.contains("&lt;a href="))
  }

  func testRestoreTreatsInlineTokenInsideCodeAsLiteralSource() {
    let replacement = MarkdownEmbeddedHTMLReplacement(
      token: "PSPHTMLINLINETESTTOKEN",
      html: "<mark>源码</mark>",
      isBlock: false
    )

    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: "<pre><code>\(replacement.token)</code></pre>",
      replacements: [replacement]
    )

    XCTAssertEqual(restored, "<pre><code>&lt;mark&gt;源码&lt;/mark&gt;</code></pre>")
  }

  func testBlockRestoreOnlyReplacesExactMarkdownParagraphWrapper() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<details><summary>说明</summary>正文</details>"
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)
    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: rendered,
      replacements: prepared.replacements
    )

    XCTAssertTrue(restored.contains("<details><summary>说明</summary>正文</details>"))
    XCTAssertFalse(restored.contains("<p><details>"))
    XCTAssertFalse(restored.contains(replacement.token))
  }

  func testBlockRestoreDoesNotReplaceTokenEmbeddedInAnotherParagraph() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<details><summary>说明</summary>正文</details>"
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)
    let rendered = "<p>prefix\(replacement.token)suffix</p>"

    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: rendered,
      replacements: prepared.replacements
    )

    XCTAssertEqual(restored, rendered)
  }

  func testForgedLegacyTokenCannotRestoreTrustedHTML() throws {
    let forgedToken = "PSPHTMLINLINE0TOKEN"
    let markdown = "\(forgedToken) <mark>重点</mark>"
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)
    let replacement = try XCTUnwrap(prepared.replacements.first)
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)
    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: rendered,
      replacements: prepared.replacements
    )

    XCTAssertNotEqual(replacement.token, forgedToken)
    XCTAssertTrue(restored.contains(forgedToken))
    XCTAssertTrue(restored.contains("<mark>重点</mark>"))
  }

  func testDiagnosticRangesUseUTF16CoordinatesAfterEmoji() throws {
    let markdown = #"🙂正文 <img src="javascript:alert(1)" onerror="run()">"#
    let source = markdown as NSString
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: markdown)
    let URLIssue = try XCTUnwrap(prepared.issues.first { $0.id.hasPrefix("html-url-") })
    let attributeIssue = try XCTUnwrap(
      prepared.issues.first { $0.id.hasPrefix("html-attribute-") }
    )

    XCTAssertEqual(URLIssue.range, source.range(of: #"src="javascript:alert(1)""#))
    XCTAssertEqual(attributeIssue.range, source.range(of: #"onerror="run()""#))
  }

  func testUnbalancedClosingTagIsNeverRestored() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: "</div>正文")
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)
    let restored = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: rendered,
      replacements: prepared.replacements
    )

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertFalse(restored.contains("</div>"))
    XCTAssertTrue(restored.contains("&lt;/div&gt;"))
  }

  func testUnsafeNestedTagPreventsWholeBlockRestoration() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<div><script>alert(1)</script><mark>内容</mark></div>"
    )

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.contains { $0.severity == .error })
  }

  func testMisnestedAllowedTagsPreventWholeFragmentRestoration() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<div><span>内容</div></span>"
    )

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.contains { $0.id.hasPrefix("html-unbalanced-") })
  }

  func testNonVoidSelfClosingTagIsNotRestored() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: "<div />")
    let rendered = MarkdownHTMLRenderingService.renderBody(prepared.markdown)

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.contains { $0.id.hasPrefix("html-unbalanced-") })
    XCTAssertTrue(rendered.contains("&lt;div /&gt;"))
  }

  func testUnparsedMarkupPreventsWholeFragmentRestoration() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<div><?unsafe?></div>"
    )

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.contains { $0.id.hasPrefix("html-malformed-") })
  }

  func testBlockHTMLRequiresWhitespaceAfterClosingTag() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: "<details><summary>内容</summary></details>tail"
    )

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertTrue(prepared.issues.contains { $0.id.hasPrefix("html-block-placement-") })
  }

  func testCommentIsNotRestoredAsTrustedHTML() {
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: "<!-- user -->正文")

    XCTAssertTrue(prepared.replacements.isEmpty)
    XCTAssertEqual(prepared.markdown, "<!-- user -->正文")
  }

  func testSVGDataURLIsRejected() throws {
    let prepared = MarkdownEmbeddedHTMLService.prepare(
      markdown: #"<img src="data:image/svg+xml,&lt;svg/&gt;" alt="图">"#
    )
    let replacement = try XCTUnwrap(prepared.replacements.first)

    XCTAssertFalse(replacement.html.contains("src="))
    XCTAssertTrue(prepared.issues.contains {
      $0.title == CoreL10n.text("HTML 链接已拦截")
    })
  }
}
