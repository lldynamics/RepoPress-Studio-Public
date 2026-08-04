import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownSyntaxHighlightParserTests: XCTestCase {
  func testSnapshotKeepsStyleApplicationOrder() async throws {
    let markdown = "# **Title** [site](https://example.com)\n- item\n> quote\n*italic* and `code`"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(
      snapshot.runs.map(\.style),
      [.heading, .link, .list, .quote, .bold, .italic, .inlineCode]
    )
  }

  func testInlineStylesAreExcludedFromCodeBlocks() async throws {
    let markdown = "before\n```swift\n**bold** [link](target) `code`\n```\nafter"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let codeBlock = try XCTUnwrap(snapshot.runs.first { $0.style == .codeBlock })

    XCTAssertEqual(
      (markdown as NSString).substring(with: codeBlock.range),
      "```swift\n**bold** [link](target) `code`\n```"
    )
    XCTAssertFalse(
      snapshot.runs.contains { run in
        run.style != .codeBlock
          && NSIntersectionRange(run.range, codeBlock.range).length > 0
      }
    )
  }

  func testEmbeddedHTMLIsHighlightedOutsideCodeOnly() async throws {
    let markdown = "<details open>正文</details> `<mark>code</mark>`\n```html\n<div>code</div>\n```"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let htmlRuns = snapshot.runs.filter { $0.style == .html }

    XCTAssertEqual(htmlRuns.count, 2)
    XCTAssertEqual(
      htmlRuns.map { (markdown as NSString).substring(with: $0.range) },
      ["<details open>", "</details>"]
    )
  }

  func testEmbeddedHTMLIsNotHighlightedInsideFourBacktickOrTildeFences() async throws {
    let markdown = """
    ````html
    <div>four backticks</div>
    ````
    ~~~html
    <mark>tilde fence</mark>
    ~~~
    """
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.runs.filter { $0.style == .codeBlock }.count, 2)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .html }.isEmpty)
  }

  func testCommonMarkCodeRangesHandleCRLFLongerClosingAndIndentedCode() async throws {
    let markdown = "```html\r\n<div>fenced</div>\r\n````\r\n    <mark>indented</mark>\n``<span>inline</span>``"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.runs.filter { $0.style == .codeBlock }.count, 2)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .inlineCode }.count, 1)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .html }.isEmpty)
  }

  func testUnclosedFenceProtectsHTMLToEndOfDocument() async throws {
    let markdown = "~~~html\n<div>literal</div>\n"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.runs.filter { $0.style == .codeBlock }.count, 1)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .html }.isEmpty)
  }

  func testMultilineHTMLCommentUsesUTF16DocumentRange() async throws {
    let markdown = "before\r\n<!-- 注释🙂\r\nsecond line -->\r\nafter"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let html = try XCTUnwrap(snapshot.runs.only(style: .html))

    XCTAssertEqual(
      (markdown as NSString).substring(with: html.range),
      "<!-- 注释🙂\r\nsecond line -->"
    )
  }

  func testNestedBoldAndItalicProduceOverlappingRuns() async throws {
    let markdown = "- item **outer *inner🙂* end**"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let bold = try XCTUnwrap(snapshot.runs.only(style: .bold))
    let italic = try XCTUnwrap(snapshot.runs.only(style: .italic))

    XCTAssertEqual((markdown as NSString).substring(with: bold.range), "**outer *inner🙂* end**")
    XCTAssertEqual((markdown as NSString).substring(with: italic.range), "*inner🙂*")
    XCTAssertEqual(snapshot.runs.filter { $0.style == .list }.count, 1)
  }

  func testTripleAsterisksProduceOverlappingBoldAndItalicRuns() async throws {
    let markdown = "before ***both🙂*** after"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let bold = try XCTUnwrap(snapshot.runs.only(style: .bold))
    let italic = try XCTUnwrap(snapshot.runs.only(style: .italic))

    XCTAssertEqual((markdown as NSString).substring(with: bold.range), "***both🙂***")
    XCTAssertEqual((markdown as NSString).substring(with: italic.range), "***both🙂***")
  }

  func testEscapedMarkersDoNotProduceEmphasisOrLinkRuns() async throws {
    let markdown = #"\*not italic\* \*\*not bold\*\* \[not](url) [yes](url)"#
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertTrue(snapshot.runs.filter { $0.style == .italic }.isEmpty)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .bold }.isEmpty)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .link }.count, 1)
    XCTAssertEqual(
      (markdown as NSString).substring(with: try XCTUnwrap(snapshot.runs.only(style: .link)).range),
      "[yes](url)"
    )
  }

  func testInlineCodeExcludesOtherInlineStyles() async throws {
    let markdown = "`**bold** *italic* [link](url) <mark>` **outside**"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.runs.filter { $0.style == .inlineCode }.count, 1)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .bold }.count, 1)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .italic }.isEmpty)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .link }.isEmpty)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .html }.isEmpty)
  }

  func testMultipleCodeBlocksExcludeOnlyTheirOverlappingStyles() async throws {
    let markdown = """
    **outside one**
    ```markdown
    **inside one** [inside](target)
    ```
    [between](target)
    ```markdown
    `inside two`
    ```
    *outside two*
    """
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.runs.filter { $0.style == .codeBlock }.count, 2)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .bold }.count, 1)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .link }.count, 1)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .inlineCode }.count, 0)
    XCTAssertEqual(snapshot.runs.filter { $0.style == .italic }.count, 1)
  }

  func testOrderedRangeExclusionPreservesAdjacentAndZeroLengthRanges() {
    let matchingRanges = [
      NSRange(location: 0, length: 2),
      NSRange(location: 2, length: 0),
      NSRange(location: 2, length: 1),
      NSRange(location: 5, length: 1),
      NSRange(location: 6, length: 2),
      NSRange(location: 8, length: 1),
      NSRange(location: 10, length: 1)
    ]
    let excludedRanges = [
      NSRange(location: 2, length: 4),
      NSRange(location: 8, length: 0),
      NSRange(location: 9, length: 2)
    ]

    XCTAssertEqual(
      MarkdownSyntaxHighlightParser.excludingOverlaps(
        from: matchingRanges,
        excludedBy: excludedRanges
      ),
      [
        NSRange(location: 0, length: 2),
        NSRange(location: 2, length: 0),
        NSRange(location: 6, length: 2),
        NSRange(location: 8, length: 1)
      ]
    )
  }

  func testRequestedRangeProducesDocumentCoordinates() async throws {
    let markdown = "before\n# 标题🙂\nafter"
    let source = markdown as NSString
    let requestedRange = source.lineRange(for: source.range(of: "标题"))
    let result = await MarkdownSyntaxHighlightParser().snapshot(
      in: markdown,
      range: requestedRange
    )
    let snapshot = try XCTUnwrap(result)
    let heading = try XCTUnwrap(snapshot.runs.first)

    XCTAssertEqual(snapshot.range, requestedRange)
    XCTAssertEqual(heading.style, .heading)
    XCTAssertEqual(
      source.substring(with: heading.range).trimmingCharacters(in: .newlines),
      "# 标题🙂"
    )
  }

  func testRequestedCRLFRangeKeepsNestedEmojiCoordinates() async throws {
    let markdown = "prefix🙂\r\n## **标题 *nested🚀* end** [site](https://example.com)\r\nsuffix"
    let source = markdown as NSString
    let requestedRange = source.lineRange(for: source.range(of: "nested"))
    let result = await MarkdownSyntaxHighlightParser().snapshot(
      in: markdown,
      range: requestedRange
    )
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(snapshot.range, requestedRange)
    XCTAssertEqual(
      source.substring(with: try XCTUnwrap(snapshot.runs.only(style: .heading)).range)
        .trimmingCharacters(in: .newlines),
      "## **标题 *nested🚀* end** [site](https://example.com)"
    )
    XCTAssertEqual(
      source.substring(with: try XCTUnwrap(snapshot.runs.only(style: .link)).range),
      "[site](https://example.com)"
    )
    XCTAssertEqual(
      source.substring(with: try XCTUnwrap(snapshot.runs.only(style: .bold)).range),
      "**标题 *nested🚀* end**"
    )
    XCTAssertEqual(
      source.substring(with: try XCTUnwrap(snapshot.runs.only(style: .italic)).range),
      "*nested🚀*"
    )
  }

  func testInvalidRangeReturnsNil() async {
    let snapshot = await MarkdownSyntaxHighlightParser().snapshot(
      in: "content",
      range: NSRange(location: 99, length: 1)
    )

    XCTAssertNil(snapshot)
  }
}

private extension Array where Element == MarkdownSyntaxHighlightRun {
  func only(style: MarkdownSyntaxHighlightStyle) -> MarkdownSyntaxHighlightRun? {
    let matching = filter { $0.style == style }
    return matching.count == 1 ? matching[0] : nil
  }
}
