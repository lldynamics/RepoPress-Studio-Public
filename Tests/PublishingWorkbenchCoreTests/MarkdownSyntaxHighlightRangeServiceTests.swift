import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownSyntaxHighlightRangeServiceTests: XCTestCase {
  func testInsertionHighlightsOnlyAffectedLine() {
    let previous = "one\ntwo\nthree"
    let current = "one\ntXwo\nthree"

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: 5, length: 0),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(plan.range, NSRange(location: 4, length: 5))
  }

  func testDeletingLineBreakHighlightsMergedLine() {
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "one\ntwo",
      currentText: "onetwo",
      replacedRange: NSRange(location: 3, length: 1),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(plan.range, NSRange(location: 0, length: 6))
  }

  func testReplacementUsesUTF16Coordinates() {
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "a\n🙂\nz",
      currentText: "a\n🚀x\nz",
      replacedRange: NSRange(location: 2, length: 2),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(plan.range, NSRange(location: 2, length: 4))
  }

  func testRapidEditsAccumulateDirtyRangeInCurrentCoordinates() {
    let firstCurrent = "xa\nb\nc"
    let firstPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "a\nb\nc",
      currentText: firstCurrent,
      replacedRange: NSRange(location: 0, length: 0),
      knownCodeBlockRanges: []
    )
    let secondCurrent = "xa\nb\nyc"
    let secondPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: firstPlan,
      previousText: firstCurrent,
      currentText: secondCurrent,
      replacedRange: NSRange(location: 5, length: 0),
      knownCodeBlockRanges: firstPlan.codeBlockRanges
    )

    XCTAssertEqual(secondPlan.range, NSRange(location: 0, length: 7))
  }

  func testEditingInsideCodeBlockExpandsToWholeBlock() throws {
    let previous = "before\n```swift\nlet x = 1\n```\nafter"
    let digitRange = try XCTUnwrap(previous.range(of: "1"))
    let location = previous.utf16.distance(
      from: previous.utf16.startIndex,
      to: digitRange.lowerBound.samePosition(in: previous.utf16)!
    )
    let current = previous.replacingCharacters(in: digitRange, with: "2")
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: location, length: 1),
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let highlighted = (current as NSString).substring(with: plan.range)

    XCTAssertEqual(highlighted, "```swift\nlet x = 2\n```")
  }

  func testChangingCodeFenceOrReceivingInvalidRangeFallsBackToFullDocument() {
    let fenceCurrent = "before\n```\nafter"
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.plan(
        accumulating: nil,
        previousText: "before\n\nafter",
        currentText: fenceCurrent,
        replacedRange: NSRange(location: 7, length: 0),
        knownCodeBlockRanges: []
      ),
      .fullDocument(for: fenceCurrent)
    )

    let current = "content"
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.plan(
        accumulating: nil,
        previousText: "content",
        currentText: current,
        replacedRange: NSRange(location: 99, length: 0),
        knownCodeBlockRanges: []
      ),
      .fullDocument(for: current)
    )
  }

  func testInlineCodeAndMidParagraphTildesRemainLocalEdits() throws {
    let inlinePrevious = "before\ninline `code` here\nafter"
    let inlineRange = (inlinePrevious as NSString).range(of: "code")
    let inlineCurrent = (inlinePrevious as NSString).replacingCharacters(
      in: NSRange(location: inlineRange.location, length: 1),
      with: "C"
    )
    let inlinePlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: inlinePrevious,
      currentText: inlineCurrent,
      replacedRange: NSRange(location: inlineRange.location, length: 1),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(
      (inlineCurrent as NSString).substring(with: inlinePlan.range),
      "inline `Code` here\n"
    )

    let tildePrevious = "before\ntext ~~~ marker\nafter"
    let tildeRange = (tildePrevious as NSString).range(of: "marker")
    let tildeCurrent = (tildePrevious as NSString).replacingCharacters(
      in: NSRange(location: tildeRange.location, length: 1),
      with: "M"
    )
    let tildePlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: tildePrevious,
      currentText: tildeCurrent,
      replacedRange: NSRange(location: tildeRange.location, length: 1),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(
      (tildeCurrent as NSString).substring(with: tildePlan.range),
      "text ~~~ Marker\n"
    )
    XCTAssertFalse(MarkdownCodeRangeScanner.containsFenceLine(in: "text ~~~ marker"))
    XCTAssertFalse(MarkdownCodeRangeScanner.containsFenceLine(in: "    ```swift"))
    XCTAssertTrue(MarkdownCodeRangeScanner.containsFenceLine(in: "   ~~~~ swift"))
  }

  func testPaddedVisibleRangeAddsRequestedContextLines() {
    let markdown = (0...120)
      .map { String(format: "line-%03d", $0) }
      .joined(separator: "\n")
    let visibleRange = (markdown as NSString).range(of: "line-060")

    let paddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: markdown,
      visibleRange: visibleRange,
      contextLineCount: 50
    )
    let padded = (markdown as NSString).substring(with: paddedRange)

    XCTAssertTrue(padded.hasPrefix("line-010\n"))
    XCTAssertTrue(padded.contains("line-060"))
    XCTAssertTrue(padded.hasSuffix("line-110\n"))
    XCTAssertFalse(padded.contains("line-009"))
    XCTAssertFalse(padded.contains("line-111"))
  }

  func testPaddedVisibleRangePreservesCRLFAndUTF16Coordinates() {
    let markdown = "甲\r\n🙂\r\n乙\r\n丁"
    let visibleRange = (markdown as NSString).range(of: "🙂")
    let paddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: markdown,
      visibleRange: visibleRange,
      contextLineCount: 1
    )

    XCTAssertEqual(
      (markdown as NSString).substring(with: paddedRange),
      "甲\r\n🙂\r\n乙\r\n"
    )
  }

  func testPaddedVisibleRangeClampsAtDocumentEdgesAndRejectsInvalidRanges() {
    let markdown = "one\ntwo\nthree"
    let source = markdown as NSString

    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.paddedLineRange(
        in: markdown,
        visibleRange: source.range(of: "one"),
        contextLineCount: 50
      ),
      NSRange(location: 0, length: source.length)
    )
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.paddedLineRange(
        in: markdown,
        visibleRange: NSRange(location: source.length, length: 0),
        contextLineCount: 1
      ),
      NSUnionRange(
        source.lineRange(for: source.range(of: "two")),
        source.lineRange(for: source.range(of: "three"))
      )
    )
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.paddedLineRange(
        in: markdown,
        visibleRange: NSRange(location: source.length + 1, length: 0)
      ),
      NSRange(location: 0, length: 0)
    )
  }

  func testResolvingUnknownCodeBlockRangesBuildsReusableCache() {
    let markdown = "before\n```swift\nlet x = 1\n```\nafter"
    let unresolved = MarkdownSyntaxHighlightPlan.fullDocument(for: markdown)
    let resolved = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: markdown,
      plan: unresolved
    )

    XCTAssertNil(unresolved.codeBlockRanges)
    XCTAssertEqual(resolved.codeBlockRanges?.count, 1)
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
        in: markdown,
        plan: resolved
      ),
      resolved
    )
  }

  func testEditBeforeCodeBlockShiftsCachedRangeWithoutInvalidatingIt() throws {
    let previous = "intro\n```swift\nlet x = 1\n```\nafter"
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let current = "new\n" + previous

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: 0, length: 0),
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let shiftedRange = try XCTUnwrap(plan.codeBlockRanges?.first)

    XCTAssertEqual(
      (current as NSString).substring(with: shiftedRange),
      "```swift\nlet x = 1\n```"
    )
    XCTAssertEqual(
      shiftedRange.location,
      try XCTUnwrap(initialPlan.codeBlockRanges?.first).location + 4
    )
  }

  func testUnknownCacheAndFenceEditRequireBackgroundResolution() {
    let current = "one!\ntwo"
    let unknownPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "one\ntwo",
      currentText: current,
      replacedRange: NSRange(location: 3, length: 0),
      knownCodeBlockRanges: nil
    )
    XCTAssertEqual(unknownPlan.range, NSRange(location: 0, length: 8))
    XCTAssertNil(unknownPlan.codeBlockRanges)

    let fenced = "one\n```\ntwo"
    let fencePlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "one\n\ntwo",
      currentText: fenced,
      replacedRange: NSRange(location: 4, length: 0),
      knownCodeBlockRanges: []
    )
    XCTAssertEqual(fencePlan, .fullDocument(for: fenced))
    XCTAssertNil(fencePlan.codeBlockRanges)
  }

  func testSchedulingPolicyUsesShortDelayForSmallCachedPartialPlan() {
    let plan = MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 20, length: 4_096),
      codeBlockRanges: []
    )

    XCTAssertEqual(
      MarkdownSyntaxHighlightSchedulingPolicy.delay(
        for: plan,
        documentUTF16Length: 100_000
      ),
      MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay,
      accuracy: 0.000_001
    )
  }

  func testSchedulingPolicyKeepsExpensiveDelayForFullDocumentOrUnknownCache() {
    let fullDocumentPlan = MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 0, length: 100_000),
      codeBlockRanges: []
    )
    let unknownCachePlan = MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 20, length: 100)
    )

    for plan in [fullDocumentPlan, unknownCachePlan] {
      XCTAssertEqual(
        MarkdownSyntaxHighlightSchedulingPolicy.delay(
          for: plan,
          documentUTF16Length: 100_000
        ),
        MarkdownSyntaxHighlightSchedulingPolicy.expensiveEditDelay,
        accuracy: 0.000_001
      )
    }
  }

  func testSchedulingPolicyKeepsExpensiveDelayForLargeOrInvalidDirtyRange() {
    let largePlan = MarkdownSyntaxHighlightPlan(
      range: NSRange(
        location: 20,
        length: MarkdownSyntaxHighlightSchedulingPolicy.maximumLocalEditUTF16Length + 1
      ),
      codeBlockRanges: []
    )
    let invalidPlan = MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 99_990, length: 20),
      codeBlockRanges: []
    )

    for plan in [largePlan, invalidPlan] {
      XCTAssertEqual(
        MarkdownSyntaxHighlightSchedulingPolicy.delay(
          for: plan,
          documentUTF16Length: 100_000
        ),
        MarkdownSyntaxHighlightSchedulingPolicy.expensiveEditDelay,
        accuracy: 0.000_001
      )
    }
  }
}
