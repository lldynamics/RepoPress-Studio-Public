import XCTest

@testable import PublishingMarkdownCore

final class MarkdownSyntaxHighlightParserTests: XCTestCase {
  func testSnapshotKeepsStyleApplicationOrder() async throws {
    let markdown = "# **Title** [site](https://example.com)\n- item\n> quote\n*italic* and `code`"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(
      snapshot.runs.map(\.style),
      [.heading1, .link, .list, .quote, .bold, .italic, .inlineCode]
    )
  }

  func testATXHeadingLevelsProduceDistinctSemanticStyles() async throws {
    let levels = [2, 1, 6, 3, 5, 4]
    let markdown = levels.map { level in
      "\(String(repeating: "#", count: level)) Heading \(level)"
    }.joined(separator: "\n")
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)

    XCTAssertEqual(
      snapshot.runs.filter { $0.style.isSemanticHeading }.map(\.style),
      [.heading2, .heading1, .heading6, .heading3, .heading5, .heading4]
    )
  }

  func testStrikethroughUsesUTF16RangesAndRespectsBoundaries() async throws {
    let markdown = "before ~~删除🙂~~ after \\~~escaped~~\n~~not\npaired~~ `~~code~~`"
    let result = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(result)
    let runs = snapshot.runs.filter { $0.style == .strikethrough }

    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(
      (markdown as NSString).substring(with: try XCTUnwrap(runs.first).range),
      "~~删除🙂~~"
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
    let markdown =
      "```html\r\n<div>fenced</div>\r\n````\r\n    <mark>indented</mark>\n``<span>inline</span>``"
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
      NSRange(location: 10, length: 1),
    ]
    let excludedRanges = [
      NSRange(location: 2, length: 4),
      NSRange(location: 8, length: 0),
      NSRange(location: 9, length: 2),
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
        NSRange(location: 8, length: 1),
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
    XCTAssertEqual(heading.style, .heading1)
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
      source.substring(with: try XCTUnwrap(snapshot.runs.only(style: .heading2)).range)
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

  func testTreeSitterReusesThePreviousTreeForAnIncrementalEdit() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "# Title\n\nParagraph with **bold** text."
    let updated = "# Title\n\nParagraph with **bold and more** text."

    let initialSnapshot = await parser.snapshot(in: initial)
    let oldBoldRange = (initial as NSString).range(of: "bold")
    let updatedResult = await parser.snapshot(
      in: updated,
      edit: MarkdownSyntaxHighlightEdit(
        previousText: initial,
        replacedRange: oldBoldRange
      )
    )
    _ = try XCTUnwrap(initialSnapshot)
    let updatedSnapshot = try XCTUnwrap(updatedResult)
    let metrics = await parser.metrics()

    XCTAssertNil(metrics.lastFallbackReason)
    XCTAssertEqual(metrics.initialParseCount, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
    XCTAssertNotNil(metrics.lastChangedRange)
    XCTAssertEqual(updatedSnapshot.runs.filter { $0.style == .bold }.count, 1)
  }

  func testTreeSitterChangedRangeStaysLocalForLongDocumentEdit() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let repeatedParagraph = String(
      repeating: "plain paragraph with stable text.\n",
      count: 2_000
    )
    let initial = [
      "# Long document\n\n",
      repeatedParagraph,
      "middle **old** marker\n",
      repeatedParagraph,
      "tail\n",
    ].joined()
    let source = initial as NSString
    let oldRange = source.range(of: "old")
    XCTAssertGreaterThan(oldRange.location, 40_000)
    XCTAssertLessThan(oldRange.location, source.length - 40_000)
    let updated = source.replacingCharacters(in: oldRange, with: "new🙂")

    let initialSnapshot = await parser.snapshot(in: initial)
    _ = try XCTUnwrap(initialSnapshot)
    let updatedResult = await parser.snapshot(
      in: updated,
      edit: MarkdownSyntaxHighlightEdit(
        previousText: initial,
        replacedRange: oldRange
      )
    )
    let updatedSnapshot = try XCTUnwrap(updatedResult)
    let metrics = await parser.metrics()
    let changedRange = try XCTUnwrap(metrics.lastChangedRange)

    XCTAssertFalse(updatedSnapshot.runs.isEmpty)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
    XCTAssertLessThan(
      changedRange.length,
      4_096,
      "A local edit in a 100k+ UTF-16 document must not report a document-sized changed range."
    )
    XCTAssertLessThanOrEqual(changedRange.location, oldRange.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(changedRange), NSMaxRange(oldRange))

    let updatedSource = updated as NSString
    let requestedRange = updatedSource.lineRange(for: updatedSource.range(of: "new🙂"))
    let localSnapshot = await parser.snapshot(in: updated, range: requestedRange)
    let local = try XCTUnwrap(localSnapshot)
    XCTAssertFalse(local.runs.isEmpty)
    XCTAssertTrue(local.runs.allSatisfy { run in
      NSIntersectionRange(run.range, requestedRange) == run.range
    })
  }

  func testTreeSitterChangedRangeStaysLocalForMillionUTF16DocumentEdit() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let stableParagraph = "plain paragraph with stable text and no syntax markers.\n"
    let stableSegment = String(repeating: stableParagraph, count: 15_000)
    let initial = stableSegment + "middle **old** marker\n" + stableSegment
    let initialSource = initial as NSString
    XCTAssertGreaterThanOrEqual(initialSource.length, 1_000_000)

    let oldRange = initialSource.range(of: "old")
    XCTAssertGreaterThan(oldRange.location, 400_000)
    XCTAssertLessThan(oldRange.location, initialSource.length - 400_000)
    let updated = initialSource.replacingCharacters(in: oldRange, with: "new🙂")

    let initialSnapshot = await parser.snapshot(in: initial)
    _ = try XCTUnwrap(initialSnapshot)
    let updatedResult = await parser.snapshot(
      in: updated,
      edit: MarkdownSyntaxHighlightEdit(
        previousText: initial,
        replacedRange: oldRange
      )
    )
    let updatedSnapshot = try XCTUnwrap(updatedResult)
    let metrics = await parser.metrics()
    let changedRange = try XCTUnwrap(metrics.lastChangedRange)

    XCTAssertFalse(updatedSnapshot.runs.isEmpty)
    XCTAssertEqual(metrics.initialParseCount, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
    XCTAssertLessThan(
      changedRange.length,
      4_096,
      "A middle-line edit must keep Tree-sitter's changed range local in a 1M document."
    )
    XCTAssertLessThanOrEqual(changedRange.location, oldRange.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(changedRange), NSMaxRange(oldRange))

    let updatedSource = updated as NSString
    let requestedRange = updatedSource.lineRange(for: updatedSource.range(of: "new🙂"))
    let localResult = await parser.snapshot(in: updated, range: requestedRange)
    let localSnapshot = try XCTUnwrap(localResult)
    let referenceParser = MarkdownSyntaxHighlightParser()
    let referenceResult = await referenceParser.snapshot(
      in: updated,
      range: requestedRange
    )
    let referenceSnapshot = try XCTUnwrap(referenceResult)
    XCTAssertEqual(localSnapshot, referenceSnapshot)
    XCTAssertEqual(
      updatedSource.substring(with: try XCTUnwrap(localSnapshot.runs.only(style: .bold)).range),
      "**new🙂**"
    )
  }

  func testTreeSitterCapturePathMatchesFallbackForCoveredMarkdownStyles() async throws {
    let markdown = "# **Title🙂**\n\n- item with *italic* and `code`\n> [site](https://example.com)\n"
    let treeSitterParser = MarkdownSyntaxHighlightParser()
    let fallbackParser = MarkdownSyntaxHighlightParser(disablingTreeSitterForTesting: true)

    let treeSitterResult = await treeSitterParser.snapshot(in: markdown)
    let treeSitter = try XCTUnwrap(treeSitterResult)
    let fallbackResult = await fallbackParser.snapshot(in: markdown)
    let fallback = try XCTUnwrap(fallbackResult)
    let metrics = await treeSitterParser.metrics()

    XCTAssertGreaterThan(
      metrics.lastTreeSitterCaptureCount,
      0,
      "The synchronized fixture must exercise the packaged Markdown captures."
    )
    XCTAssertEqual(treeSitter, fallback)
  }

  func testMixedCapturedAndUnsupportedMarkdownKeepsFallbackSemantics() async throws {
    let markdown = "# **ATX**\nSetext\n======\n\n[inline](url) [reference][id]\n\n- item\n> quote\n***both*** ~~strike~~\n"
    let treeSitterResult = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let treeSitter = try XCTUnwrap(treeSitterResult)
    let fallbackResult = await MarkdownSyntaxHighlightParser(
      disablingTreeSitterForTesting: true
    ).snapshot(in: markdown)
    let fallback = try XCTUnwrap(fallbackResult)

    XCTAssertEqual(treeSitter, fallback)
    XCTAssertEqual(treeSitter.runs.filter { $0.style == .link }.count, 1)
    XCTAssertEqual(treeSitter.runs.filter { $0.style == .strikethrough }.count, 1)
  }

  func testTreeSitterFallbackMetricsExposeReasonAndRequestedRange() async throws {
    let parser = MarkdownSyntaxHighlightParser(disablingTreeSitterForTesting: true)
    let source = "# title\n\nparagraph with **bold**\n"
    let requestedRange = NSRange(location: 2, length: 7)

    let snapshotResult = await parser.snapshot(in: source, range: requestedRange)
    let snapshot = try XCTUnwrap(snapshotResult)
    XCTAssertEqual(snapshot.range, requestedRange)

    let afterSnapshot = await parser.metrics()
    XCTAssertEqual(afterSnapshot.fallbackParseCount, 1)
    XCTAssertEqual(afterSnapshot.lastFallbackReason, "tree-sitter-unavailable")
    XCTAssertEqual(afterSnapshot.lastFallbackRange, requestedRange)
    XCTAssertNil(afterSnapshot.lastChangedRange)

    let didSynchronize = await parser.synchronizeTree(in: source, revision: 1)
    XCTAssertFalse(didSynchronize)
    let afterSynchronization = await parser.metrics()
    XCTAssertEqual(afterSynchronization.fallbackParseCount, 2)
    XCTAssertEqual(
      afterSynchronization.lastFallbackReason,
      "tree-sitter-unavailable"
    )
    XCTAssertEqual(
      afterSynchronization.lastFallbackRange,
      NSRange(location: 0, length: (source as NSString).length)
    )
  }

  func testTreeSitterFallbackMetricsExposeFullMillionUTF16Range() async throws {
    let parser = MarkdownSyntaxHighlightParser(disablingTreeSitterForTesting: true)
    let markdown = String(
      repeating: "plain paragraph with **bold** and *italic*.\n",
      count: 25_000
    )
    let source = markdown as NSString
    XCTAssertGreaterThanOrEqual(source.length, 1_000_000)

    let snapshotResult = await parser.snapshot(in: markdown)
    let snapshot = try XCTUnwrap(snapshotResult)
    let metrics = await parser.metrics()

    XCTAssertEqual(snapshot.range, NSRange(location: 0, length: source.length))
    XCTAssertEqual(metrics.fallbackParseCount, 1)
    XCTAssertEqual(metrics.lastFallbackReason, "tree-sitter-unavailable")
    XCTAssertEqual(
      metrics.lastFallbackRange,
      NSRange(location: 0, length: source.length)
    )
    XCTAssertGreaterThan(snapshot.runs.count, 0)
  }

  func testMillionUTF16UnclosedFenceKeepsTrailingMarkupLiteral() async throws {
    let prefix = String(
      repeating: "stable paragraph before the fence.\n",
      count: 15_000
    )
    let fencedContent = String(
      repeating: "<div>literal fenced content</div>\n",
      count: 15_000
    )
    let markdown = prefix + "~~~html\n" + fencedContent
    let source = markdown as NSString
    XCTAssertGreaterThanOrEqual(source.length, 1_000_000)

    let snapshotResult = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(snapshotResult)
    let codeBlock = try XCTUnwrap(snapshot.runs.only(style: .codeBlock))

    XCTAssertEqual(codeBlock.range.location, prefix.utf16.count)
    XCTAssertEqual(NSMaxRange(codeBlock.range), source.length)
    XCTAssertTrue(snapshot.runs.filter { $0.style == .html }.isEmpty)
    XCTAssertTrue(
      snapshot.runs
        .filter { $0.style != .codeBlock }
        .allSatisfy { NSIntersectionRange($0.range, codeBlock.range).length == 0 }
    )
  }

  func testLightweightSnapshotMatchesSynchronizedOutputWithoutUpdatingTree() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = """
      # **Title**

      Paragraph with **bold** and *italic*, `code`, [link](url), ~~strike~~.
      - item
      > quote
      <details>html</details>
      ```swift
      let value = "literal"
      ```
      """
    let initialRevision: UInt64 = 10
    let initialSnapshot = await parser.snapshot(
      in: initial,
      revision: initialRevision,
      mode: .synchronized
    )
    _ = try XCTUnwrap(initialSnapshot)
    let before = await parser.metrics()

    let boldRange = (initial as NSString).range(of: "bold")
    let updated = (initial as NSString).replacingCharacters(
      in: boldRange,
      with: "bold🙂"
    )
    let lightweightResult = await parser.snapshot(
      in: updated,
      revision: initialRevision + 1,
      edit: MarkdownSyntaxHighlightEdit(
        previousText: initial,
        replacedRange: boldRange,
        previousRevision: initialRevision
      ),
      mode: .lightweight
    )
    let lightweight = try XCTUnwrap(lightweightResult)
    let after = await parser.metrics()
    let synchronizedResult = await MarkdownSyntaxHighlightParser().snapshot(
      in: updated,
      revision: initialRevision + 1,
      mode: .synchronized
    )
    let synchronized = try XCTUnwrap(synchronizedResult)

    XCTAssertEqual(lightweight, synchronized)
    XCTAssertEqual(after.initialParseCount, before.initialParseCount)
    XCTAssertEqual(after.incrementalParseCount, before.incrementalParseCount)
    XCTAssertEqual(after.editHintParseCount, before.editHintParseCount)
    XCTAssertEqual(after.fallbackParseCount, before.fallbackParseCount)
    XCTAssertGreaterThan(before.lastTreeSitterCaptureCount, 0)
    XCTAssertEqual(after.lastTreeSitterCaptureCount, 0)
    XCTAssertEqual(
      after.lightweightSnapshotCount,
      before.lightweightSnapshotCount + 1
    )
  }

  func testIdleTreeSynchronizationConsumesCoalescedLightweightEdits() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "# Title\r\n\r\nParagraph with **bold** and `token`.\r\n"
    let initialRevision: UInt64 = 41
    let initialSnapshot = await parser.snapshot(
      in: initial,
      revision: initialRevision,
      mode: .synchronized
    )
    _ = try XCTUnwrap(initialSnapshot)

    let markerRange = (initial as NSString).range(of: "bold")
    var currentText = initial
    var currentRevision = initialRevision
    var accumulator: MarkdownSyntaxHighlightEditAccumulator?
    for step in 0..<3 {
      let previousText = currentText
      let previousRevision = currentRevision
      let replacement = String((step + 1) % 10)
      currentText = (previousText as NSString).replacingCharacters(
        in: NSRange(location: markerRange.location, length: 1),
        with: replacement
      )
      currentRevision += 1

      if let existingAccumulator = accumulator {
        accumulator = try XCTUnwrap(
          existingAccumulator.accumulating(
            previousText: previousText,
            currentText: currentText,
            replacedRange: NSRange(location: markerRange.location, length: 1),
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      } else {
        accumulator = try XCTUnwrap(
          MarkdownSyntaxHighlightEditAccumulator(
            previousText: previousText,
            currentText: currentText,
            replacedRange: NSRange(location: markerRange.location, length: 1),
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      }

      let lightweightSnapshot = await parser.snapshot(
        in: currentText,
        revision: currentRevision,
        mode: .lightweight
      )
      _ = try XCTUnwrap(lightweightSnapshot)
    }

    let beforeSynchronization = await parser.metrics()
    let coalescedEdit = try XCTUnwrap(accumulator).parserEdit
    XCTAssertEqual(
      beforeSynchronization.incrementalParseCount,
      0
    )
    XCTAssertEqual(beforeSynchronization.editHintParseCount, 0)
    XCTAssertEqual(beforeSynchronization.lightweightSnapshotCount, 3)

    let didSynchronize = await parser.synchronizeTree(
      in: currentText,
      revision: currentRevision,
      edit: coalescedEdit
    )
    XCTAssertTrue(didSynchronize)
    let afterSynchronization = await parser.metrics()

    XCTAssertEqual(
      afterSynchronization.treeSynchronizationCount,
      beforeSynchronization.treeSynchronizationCount + 1
    )
    XCTAssertEqual(
      afterSynchronization.incrementalParseCount,
      beforeSynchronization.incrementalParseCount + 1
    )
    XCTAssertEqual(
      afterSynchronization.editHintParseCount,
      beforeSynchronization.editHintParseCount + 1
    )
    XCTAssertEqual(
      afterSynchronization.fallbackParseCount,
      beforeSynchronization.fallbackParseCount
    )
  }

  func testTreeSitterIncrementalEditKeepsEmojiUTF16Coordinates() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "😀 prefix\n`old` and [site](https://example.com)"
    let updated = "😀 prefix\n`new🙂` and [site](https://example.com)"

    let initialSnapshot = await parser.snapshot(in: initial)
    let oldCodeRange = (initial as NSString).range(of: "old")
    let updatedResult = await parser.snapshot(
      in: updated,
      edit: MarkdownSyntaxHighlightEdit(
        previousText: initial,
        replacedRange: oldCodeRange
      )
    )
    _ = try XCTUnwrap(initialSnapshot)
    let snapshot = try XCTUnwrap(updatedResult)
    let inlineCode = try XCTUnwrap(snapshot.runs.only(style: .inlineCode))
    let metrics = await parser.metrics()

    XCTAssertEqual(
      (updated as NSString).substring(with: inlineCode.range),
      "`new🙂`"
    )
    XCTAssertNil(metrics.lastFallbackReason)
    XCTAssertEqual(metrics.initialParseCount, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
  }

  func testEditAccumulatorCoalescesTenSequentialEditsIntoOneTreeSitterHint() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "# Title\r\n\r\nParagraph with **bold** and `token`.\r\n"
    let initialRevision: UInt64 = 41
    let initialSnapshot = await parser.snapshot(in: initial, revision: initialRevision)
    _ = try XCTUnwrap(initialSnapshot)

    let markerRange = (initial as NSString).range(of: "bold")
    XCTAssertEqual(markerRange.length, 4)
    var currentText = initial
    var currentRevision = initialRevision
    var accumulator: MarkdownSyntaxHighlightEditAccumulator?

    for step in 0..<10 {
      let previousText = currentText
      let previousRevision = currentRevision
      let replacement = String((step + 1) % 10)
      currentText = (previousText as NSString).replacingCharacters(
        in: NSRange(location: markerRange.location, length: 1),
        with: replacement
      )
      currentRevision += 1

      if let existingAccumulator = accumulator {
        accumulator = try XCTUnwrap(
          existingAccumulator.accumulating(
            previousText: previousText,
            currentText: currentText,
            replacedRange: NSRange(location: markerRange.location, length: 1),
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      } else {
        accumulator = try XCTUnwrap(
          MarkdownSyntaxHighlightEditAccumulator(
            previousText: previousText,
            currentText: currentText,
            replacedRange: NSRange(location: markerRange.location, length: 1),
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      }
    }

    let accumulatedEdit = try XCTUnwrap(accumulator)
    XCTAssertEqual(accumulatedEdit.baseText, initial)
    XCTAssertEqual(accumulatedEdit.baseRevision, initialRevision)
    XCTAssertEqual(accumulatedEdit.currentRevision, initialRevision + 10)
    XCTAssertEqual(
      accumulatedEdit.replacedRange,
      NSRange(location: markerRange.location, length: 1)
    )
    XCTAssertEqual(
      accumulatedEdit.replacementRange,
      NSRange(location: markerRange.location, length: 1)
    )

    let incrementalResult = await parser.snapshot(
      in: currentText,
      revision: accumulatedEdit.currentRevision,
      edit: accumulatedEdit.parserEdit
    )
    let incrementalSnapshot = try XCTUnwrap(incrementalResult)
    let fullResult = await MarkdownSyntaxHighlightParser().snapshot(
      in: currentText,
      revision: accumulatedEdit.currentRevision
    )
    let fullSnapshot = try XCTUnwrap(fullResult)
    let metrics = await parser.metrics()

    XCTAssertEqual(incrementalSnapshot, fullSnapshot)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
  }

  func testEditAccumulatorMergesDistantEditsAndMatchesFullParse() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "# **标题🙂**\r\n\r\nfirst **one** line\r\nsecond [two](url)\r\nthird"
    let initialRevision: UInt64 = 7
    let initialSnapshot = await parser.snapshot(in: initial, revision: initialRevision)
    _ = try XCTUnwrap(initialSnapshot)

    let initialSource = initial as NSString
    let firstRange = initialSource.range(of: "one")
    let afterFirst = initialSource.replacingCharacters(in: firstRange, with: "ONE🙂")
    let secondRange = (afterFirst as NSString).range(of: "two")
    let finalText = (afterFirst as NSString).replacingCharacters(
      in: secondRange,
      with: "TWO"
    )

    let firstRevision = initialRevision + 1
    let finalRevision = firstRevision + 1
    let accumulator = try XCTUnwrap(
      MarkdownSyntaxHighlightEditAccumulator(
        previousText: initial,
        currentText: afterFirst,
        replacedRange: firstRange,
        previousRevision: initialRevision,
        currentRevision: firstRevision
      )
    )
    let merged = try XCTUnwrap(
      accumulator.accumulating(
        previousText: afterFirst,
        currentText: finalText,
        replacedRange: secondRange,
        previousRevision: firstRevision,
        currentRevision: finalRevision
      )
    )

    let originalSecondRange = initialSource.range(of: "two")
    XCTAssertEqual(merged.replacedRange.location, firstRange.location)
    XCTAssertEqual(NSMaxRange(merged.replacedRange), NSMaxRange(originalSecondRange))
    XCTAssertEqual(merged.replacementRange.location, firstRange.location)
    XCTAssertEqual(NSMaxRange(merged.replacementRange), NSMaxRange(secondRange))

    let incrementalResult = await parser.snapshot(
      in: finalText,
      revision: finalRevision,
      edit: merged.parserEdit
    )
    let incrementalSnapshot = try XCTUnwrap(incrementalResult)
    let fullResult = await MarkdownSyntaxHighlightParser().snapshot(
      in: finalText,
      revision: finalRevision
    )
    let fullSnapshot = try XCTUnwrap(fullResult)
    let metrics = await parser.metrics()

    XCTAssertEqual(incrementalSnapshot, fullSnapshot)
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
  }

  func testEditAccumulatorPreservesEmojiAndCRLFUTF16Coordinates() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "😀 prefix\r\n## **标题🙂**\r\nsuffix"
    let initialRevision: UInt64 = 100
    let initialSnapshot = await parser.snapshot(in: initial, revision: initialRevision)
    _ = try XCTUnwrap(initialSnapshot)

    let initialSource = initial as NSString
    let emojiRange = initialSource.range(of: "🙂")
    XCTAssertEqual(emojiRange.length, 2)
    let afterEmoji = initialSource.replacingCharacters(in: emojiRange, with: "🚀")
    let suffixRange = (afterEmoji as NSString).range(of: "suffix")
    let finalText = (afterEmoji as NSString).replacingCharacters(
      in: suffixRange,
      with: "后缀🙂"
    )

    let firstRevision = initialRevision + 1
    let finalRevision = firstRevision + 1
    let accumulator = try XCTUnwrap(
      MarkdownSyntaxHighlightEditAccumulator(
        previousText: initial,
        currentText: afterEmoji,
        replacedRange: emojiRange,
        previousRevision: initialRevision,
        currentRevision: firstRevision
      )
    )
    let merged = try XCTUnwrap(
      accumulator.accumulating(
        previousText: afterEmoji,
        currentText: finalText,
        replacedRange: suffixRange,
        previousRevision: firstRevision,
        currentRevision: finalRevision
      )
    )

    XCTAssertEqual(merged.replacedRange.location, emojiRange.location)
    XCTAssertEqual(merged.replacementRange.location, emojiRange.location)
    XCTAssertEqual(
      (finalText as NSString).substring(with: merged.replacementRange),
      "🚀**\r\n后缀🙂"
    )

    let incrementalResult = await parser.snapshot(
      in: finalText,
      revision: finalRevision,
      edit: merged.parserEdit
    )
    let incrementalSnapshot = try XCTUnwrap(incrementalResult)
    let fullResult = await MarkdownSyntaxHighlightParser().snapshot(
      in: finalText,
      revision: finalRevision
    )
    let fullSnapshot = try XCTUnwrap(fullResult)
    let heading = try XCTUnwrap(incrementalSnapshot.runs.only(style: .heading2))
    let metrics = await parser.metrics()

    XCTAssertEqual(incrementalSnapshot, fullSnapshot)
    XCTAssertEqual(
      (finalText as NSString).substring(with: heading.range).trimmingCharacters(
        in: .newlines
      ),
      "## **标题🚀**"
    )
    XCTAssertEqual(metrics.editHintParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
  }

  func testStaleEditRevisionSkipsHintAndSafelyUsesComputedDiff() async throws {
    let parser = MarkdownSyntaxHighlightParser()
    let initial = "before\r\n## **标题🙂**\r\nafter [link](url)"
    let initialRevision: UInt64 = 200
    let initialSnapshot = await parser.snapshot(in: initial, revision: initialRevision)
    _ = try XCTUnwrap(initialSnapshot)

    let source = initial as NSString
    let editRange = source.range(of: "标题")
    let updated = source.replacingCharacters(in: editRange, with: "新标题")
    let staleEdit = MarkdownSyntaxHighlightEdit(
      previousText: initial,
      replacedRange: editRange,
      previousRevision: initialRevision - 1
    )
    let incrementalResult = await parser.snapshot(
      in: updated,
      revision: initialRevision + 1,
      edit: staleEdit
    )
    let result = try XCTUnwrap(incrementalResult)
    let fullResult = await MarkdownSyntaxHighlightParser().snapshot(
      in: updated,
      revision: initialRevision + 1
    )
    let fullSnapshot = try XCTUnwrap(fullResult)
    let metrics = await parser.metrics()

    XCTAssertEqual(result, fullSnapshot)
    XCTAssertEqual(metrics.editHintParseCount, 0)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.fallbackParseCount, 0)
    XCTAssertNil(metrics.lastFallbackReason)
  }

  func testInvalidRangeReturnsNil() async {
    let snapshot = await MarkdownSyntaxHighlightParser().snapshot(
      in: "content",
      range: NSRange(location: 99, length: 1)
    )

    XCTAssertNil(snapshot)
  }
}

extension Array where Element == MarkdownSyntaxHighlightRun {
  fileprivate func only(style: MarkdownSyntaxHighlightStyle) -> MarkdownSyntaxHighlightRun? {
    let matching = filter { $0.style == style }
    return matching.count == 1 ? matching[0] : nil
  }
}

extension MarkdownSyntaxHighlightStyle {
  fileprivate var isSemanticHeading: Bool {
    switch self {
    case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
      return true
    default:
      return false
    }
  }
}
