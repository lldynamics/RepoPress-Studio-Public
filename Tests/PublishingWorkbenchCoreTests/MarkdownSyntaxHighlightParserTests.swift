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

  func testInvalidRangeReturnsNil() async {
    let snapshot = await MarkdownSyntaxHighlightParser().snapshot(
      in: "content",
      range: NSRange(location: 99, length: 1)
    )

    XCTAssertNil(snapshot)
  }
}
