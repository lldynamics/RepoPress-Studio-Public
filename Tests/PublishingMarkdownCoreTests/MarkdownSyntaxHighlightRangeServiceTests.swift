import XCTest
@testable import PublishingMarkdownCore

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

  func testEditingCodeFenceInfoStringKeepsLocalRangeAndReusableCache() throws {
    let previous = "intro\n```swift\nlet value = 1\n```\noutro\n"
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let infoRange = previousSource.range(of: "swift")
    let current = previousSource.replacingCharacters(
      in: infoRange,
      with: "markdown"
    )

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: infoRange,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let currentSource = current as NSString
    let currentBlockRange = try XCTUnwrap(plan.codeBlockRanges?.first)

    XCTAssertEqual(plan.codeBlockRanges?.count, 1)
    XCTAssertEqual(
      currentSource.substring(with: currentBlockRange),
      "```markdown\nlet value = 1\n```"
    )
    XCTAssertEqual(plan.range.location, currentBlockRange.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(plan.range), NSMaxRange(currentBlockRange))
    XCTAssertLessThan(NSMaxRange(plan.range), currentSource.length)
    XCTAssertNotEqual(
      plan.range,
      NSRange(location: 0, length: currentSource.length),
      "An info-string edit must not schedule a full-document highlight."
    )
  }

  func testAddingOpeningFenceResynchronizesFromMarkerLineToDocumentEnd() {
    let previous = "intro\nplain paragraph\noutro\n"
    let previousSource = previous as NSString
    let insertionLocation = previousSource.range(of: "plain paragraph").location
    let current = previousSource.replacingCharacters(
      in: NSRange(location: insertionLocation, length: 0),
      with: "```swift\n"
    )
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: insertionLocation, length: 0),
      knownCodeBlockRanges: []
    )

    XCTAssertEqual(
      plan.range.location,
      insertionLocation,
      "A newly inserted opening marker is the earliest state that can change."
    )
    XCTAssertEqual(NSMaxRange(plan.range), (current as NSString).length)
    XCTAssertGreaterThan(plan.range.location, 0)
    XCTAssertNotEqual(plan.range.location, 0)

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
  }

  func testDeletingClosingFenceResynchronizesThroughLaterMatchingClosingFence() throws {
    let previous = "intro\n```swift\nlet first = 1\n```\nmiddle\n```python\nprint(2)\n```\nbetween\n```json\n{\"value\": 3}\n```\ntail\n"
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let firstBlockRange = try XCTUnwrap(initialPlan.codeBlockRanges?.first)
    XCTAssertEqual(initialPlan.codeBlockRanges?.count, 3)
    let firstClosingLocation = previousSource.range(
      of: "```",
      options: [],
      range: NSRange(
        location: NSMaxRange(firstBlockRange) - 3,
        length: previousSource.length - (NSMaxRange(firstBlockRange) - 3)
      )
    ).location
    let current = previousSource.replacingCharacters(
      in: NSRange(location: firstClosingLocation, length: 3),
      with: ""
    )

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: firstClosingLocation, length: 3),
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )

    XCTAssertEqual(plan.range.location, firstBlockRange.location)
    XCTAssertGreaterThan(plan.range.location, 0)

    let currentSource = current as NSString
    let secondOpening = try XCTUnwrap(
      currentSource.range(of: "```python").location == NSNotFound
        ? nil
        : currentSource.range(of: "```python")
    )
    let secondOpeningLine = currentSource.lineRange(for: secondOpening)
    let secondClosing = currentSource.range(
      of: "```",
      options: [],
      range: NSRange(
        location: NSMaxRange(secondOpeningLine),
        length: currentSource.length - NSMaxRange(secondOpeningLine)
      )
    )
    XCTAssertNotEqual(secondClosing.location, NSNotFound)
    let recoveryLine = currentSource.lineRange(for: secondClosing)
    let rescanRange = try XCTUnwrap(plan.codeBlockRescanRange)
    XCTAssertEqual(rescanRange.location, firstBlockRange.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(rescanRange), NSMaxRange(recoveryLine))
    XCTAssertLessThan(
      NSMaxRange(rescanRange),
      currentSource.length,
      "Once the old and new fence states are both outside, the suffix must remain cached."
    )

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
    XCTAssertEqual(resolvedPlan.codeBlockRanges?.count, 2)
  }

  func testStructuralMarkerEditConvergesAtSecondBlockAndPreservesSurroundingCache() throws {
    let previous = [
      "前🙂\r\n",
      "```swift\r\n",
      "let first = 1\r\n",
      "```\r\n",
      "middle\r\n",
      "```python\r\n",
      "print(2)\r\n",
      "```\r\n",
      "between\r\n",
      "```json\r\n",
      "{\"value\": 3}\r\n",
      "```\r\n",
      "tail\r\n",
    ].joined()
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let blocks = try XCTUnwrap(initialPlan.codeBlockRanges)
    XCTAssertEqual(blocks.count, 3)

    let secondBlock = blocks[1]
    let secondOpening = previousSource.range(of: "```python")
    XCTAssertEqual(secondBlock.location, secondOpening.location)
    let secondOpeningLine = previousSource.lineRange(for: secondOpening)
    let secondClosing = previousSource.range(
      of: "```",
      options: [],
      range: NSRange(
        location: NSMaxRange(secondOpeningLine),
        length: previousSource.length - NSMaxRange(secondOpeningLine)
      )
    )
    XCTAssertNotEqual(secondClosing.location, NSNotFound)
    let current = previousSource.replacingCharacters(
      in: secondClosing,
      with: "````"
    )

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: secondClosing,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let rescanRange = try XCTUnwrap(plan.codeBlockRescanRange)
    let currentSource = current as NSString
    let currentClosing = currentSource.range(
      of: "````",
      options: [],
      range: NSRange(
        location: secondClosing.location,
        length: currentSource.length - secondClosing.location
      )
    )
    let recoveryLine = currentSource.lineRange(for: currentClosing)

    XCTAssertGreaterThanOrEqual(rescanRange.location, blocks[0].location)
    XCTAssertLessThanOrEqual(rescanRange.location, secondBlock.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(rescanRange), NSMaxRange(recoveryLine))
    XCTAssertLessThan(
      NSMaxRange(rescanRange),
      currentSource.length,
      "The old and new states both become outside-code at the edited closing fence."
    )
    XCTAssertLessThan(
      NSMaxRange(plan.range),
      currentSource.length,
      "Marker edits between complete fences must not schedule the document tail."
    )

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
    XCTAssertEqual(resolvedPlan.codeBlockRanges?.count, 3)

    let resolvedBlocks = try XCTUnwrap(resolvedPlan.codeBlockRanges)
    XCTAssertEqual(
      currentSource.substring(with: resolvedBlocks[0]),
      "```swift\r\nlet first = 1\r\n```"
    )
    XCTAssertEqual(
      currentSource.substring(with: resolvedBlocks[2]),
      "```json\r\n{\"value\": 3}\r\n```"
    )
  }

  func testPendingStructuralEditAfterConvergedBoundaryStaysBounded() throws {
    let previous = [
      "prefix\n",
      "```swift\n",
      "let first = 1\n",
      "```\n",
      "middle\n",
      "```python\n",
      "print(2)\n",
      "```\n",
      "between\n",
      "```json\n",
      "{\"value\": 3}\n",
      "```\n",
      "tail\n",
    ].joined()
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let blocks = try XCTUnwrap(initialPlan.codeBlockRanges)
    XCTAssertEqual(blocks.count, 3)

    let secondClosingLine = previousSource.lineRange(
      for: NSRange(location: NSMaxRange(blocks[1]) - 1, length: 0)
    )
    let secondClosing = try XCTUnwrap(
      previousSource.range(of: "```", options: [], range: secondClosingLine).location
        == NSNotFound
        ? nil
        : previousSource.range(of: "```", options: [], range: secondClosingLine)
    )
    let firstCurrent = previousSource.replacingCharacters(in: secondClosing, with: "````")
    let firstPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: firstCurrent,
      replacedRange: secondClosing,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let firstRescanRange = try XCTUnwrap(firstPlan.codeBlockRescanRange)
    XCTAssertLessThan(NSMaxRange(firstRescanRange), (firstCurrent as NSString).length)

    let firstSource = firstCurrent as NSString
    let thirdOpening = firstSource.range(of: "```json")
    let thirdOpeningLine = firstSource.lineRange(for: thirdOpening)
    let thirdClosingSearchRange = NSRange(
      location: NSMaxRange(thirdOpeningLine),
      length: firstSource.length - NSMaxRange(thirdOpeningLine)
    )
    let thirdClosingLine = firstSource.lineRange(
      for: firstSource.range(
        of: "```",
        options: [],
        range: thirdClosingSearchRange
      )
    )
    let thirdClosing = try XCTUnwrap(
      firstSource.range(of: "```", options: [], range: thirdClosingLine).location
        == NSNotFound
        ? nil
        : firstSource.range(of: "```", options: [], range: thirdClosingLine)
    )
    let secondCurrent = firstSource.replacingCharacters(in: thirdClosing, with: "````")
    let secondPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: firstPlan,
      previousText: firstCurrent,
      currentText: secondCurrent,
      replacedRange: thirdClosing,
      knownCodeBlockRanges: firstPlan.codeBlockRanges
    )
    let secondSource = secondCurrent as NSString
    let secondRescanRange = try XCTUnwrap(secondPlan.codeBlockRescanRange)
    XCTAssertLessThan(
      NSMaxRange(secondPlan.range),
      secondSource.length,
      "A later structural edit after the pending convergence boundary must not rescan the document tail."
    )
    XCTAssertLessThan(
      NSMaxRange(secondRescanRange),
      secondSource.length,
      "The unresolved window and the later edit should share one finite rescan window."
    )

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: secondCurrent,
      plan: secondPlan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: secondCurrent,
      plan: .fullDocument(for: secondCurrent)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
  }

  func testPendingStructuralEditInsideUnresolvedWindowStillUsesEOFFallback() throws {
    let previous = [
      "prefix\n",
      "```swift\n",
      "let first = 1\n",
      "```\n",
      "middle\n",
      "```python\n",
      "print(2)\n",
      "```\n",
      "between\n",
      "```json\n",
      "{\"value\": 3}\n",
      "```\n",
      "tail\n",
    ].joined()
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let blocks = try XCTUnwrap(initialPlan.codeBlockRanges)
    let secondClosingLine = previousSource.lineRange(
      for: NSRange(location: NSMaxRange(blocks[1]) - 1, length: 0)
    )
    let secondClosing = try XCTUnwrap(
      previousSource.range(of: "```", options: [], range: secondClosingLine).location
        == NSNotFound
        ? nil
        : previousSource.range(of: "```", options: [], range: secondClosingLine)
    )
    let firstCurrent = previousSource.replacingCharacters(in: secondClosing, with: "````")
    let firstPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: firstCurrent,
      replacedRange: secondClosing,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let pendingRange = try XCTUnwrap(firstPlan.codeBlockRescanRange)
    let firstSource = firstCurrent as NSString
    let editLocation = firstSource.range(of: "````").location
    XCTAssertGreaterThan(editLocation, pendingRange.location)
    XCTAssertLessThan(editLocation, NSMaxRange(pendingRange))
    let secondCurrent = firstSource.replacingCharacters(
      in: NSRange(location: editLocation, length: 3),
      with: "~~~~"
    )

    let secondPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: firstPlan,
      previousText: firstCurrent,
      currentText: secondCurrent,
      replacedRange: NSRange(location: editLocation, length: 3),
      knownCodeBlockRanges: firstPlan.codeBlockRanges
    )
    let secondSource = secondCurrent as NSString
    XCTAssertEqual(
      NSMaxRange(try XCTUnwrap(secondPlan.codeBlockRescanRange)),
      secondSource.length,
      "An edit inside the unresolved window cannot safely reuse the old convergence boundary."
    )
    XCTAssertEqual(
      secondPlan.range,
      try XCTUnwrap(secondPlan.codeBlockRescanRange),
      "An overlapping structural edit must apply through the same conservative EOF window."
    )
  }

  func testPendingEOFWindowAndEarlierStructuralEditRescanConservativelyToEOF() throws {
    let previous = "prefix\nplain paragraph\ntrailing text\n"
    let previousSource = previous as NSString
    let insertionLocation = previousSource.range(of: "plain paragraph").location
    let firstCurrent = previousSource.replacingCharacters(
      in: NSRange(location: insertionLocation, length: 0),
      with: "```swift\n"
    )
    let firstPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: firstCurrent,
      replacedRange: NSRange(location: insertionLocation, length: 0),
      knownCodeBlockRanges: []
    )
    let firstSource = firstCurrent as NSString
    let pendingRange = try XCTUnwrap(firstPlan.codeBlockRescanRange)
    XCTAssertEqual(
      NSMaxRange(pendingRange),
      firstSource.length,
      "The newly opened fence has no closing boundary and must remain pending to EOF."
    )

    let prefixRange = firstSource.range(of: "prefix")
    let secondCurrent = firstSource.replacingCharacters(
      in: prefixRange,
      with: "~~~"
    )
    let secondPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: firstPlan,
      previousText: firstCurrent,
      currentText: secondCurrent,
      replacedRange: prefixRange,
      knownCodeBlockRanges: firstPlan.codeBlockRanges
    )
    let secondSource = secondCurrent as NSString
    let conservativeRange = try XCTUnwrap(secondPlan.codeBlockRescanRange)

    XCTAssertEqual(
      conservativeRange,
      NSRange(location: 0, length: secondSource.length),
      "A structural edit before an EOF-pending window has no safe splice point."
    )
    XCTAssertEqual(secondPlan.range, conservativeRange)

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: secondCurrent,
      plan: secondPlan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: secondCurrent,
      plan: .fullDocument(for: secondCurrent)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
  }

  func testChangingFenceMarkerResynchronizesFromAffectedFenceWithMultipleBlocks() throws {
    let previous = "prefix\n```swift\nlet first = 1\n```\nseparator\n~~~python\nprint(2)\n~~~\nsuffix\n"
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let blocks = try XCTUnwrap(initialPlan.codeBlockRanges)
    XCTAssertEqual(blocks.count, 2)
    let secondOpening = previousSource.range(of: "~~~python")
    let current = previousSource.replacingCharacters(
      in: NSRange(location: secondOpening.location, length: 3),
      with: "~~~~"
    )

    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: secondOpening.location, length: 3),
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )

    XCTAssertEqual(plan.range.location, secondOpening.location)
    XCTAssertEqual(NSMaxRange(plan.range), (current as NSString).length)
    XCTAssertGreaterThan(plan.range.location, blocks[0].location)
    XCTAssertNotEqual(plan.range.location, 0)

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
    XCTAssertEqual(resolvedPlan.codeBlockRanges?.first, blocks[0])
  }

  func testUnclosedTildeFenceUsesUTF16CoordinatesForInfoAndMarkerEdits() throws {
    let previous = "前🙂\nintro\n~~~swift\nlet value = 1\n尾\n"
    let previousSource = previous as NSString
    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let openingRange = previousSource.range(of: "~~~swift")
    let infoRange = NSRange(location: openingRange.location + 3, length: 5)
    let current = previousSource.replacingCharacters(
      in: infoRange,
      with: "markdown"
    )
    let infoPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: infoRange,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )

    XCTAssertEqual(infoPlan.range.location, openingRange.location)
    XCTAssertEqual(NSMaxRange(infoPlan.range), (current as NSString).length)
    XCTAssertEqual(infoPlan.codeBlockRanges?.count, 1)
    XCTAssertNil(infoPlan.codeBlockRescanRange)
    XCTAssertEqual(
      openingRange.location,
      previous.utf16.distance(
        from: previous.utf16.startIndex,
        to: previous.range(of: "~~~swift")!.lowerBound.samePosition(in: previous.utf16)!
      )
    )
    XCTAssertGreaterThan(openingRange.location, 0)

    let markerCurrent = previousSource.replacingCharacters(
      in: NSRange(location: openingRange.location, length: 3),
      with: "~~~~"
    )
    let markerPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: markerCurrent,
      replacedRange: NSRange(location: openingRange.location, length: 3),
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )

    XCTAssertEqual(markerPlan.range.location, openingRange.location)
    XCTAssertEqual(NSMaxRange(markerPlan.range), (markerCurrent as NSString).length)
    XCTAssertNotEqual(markerPlan.range.location, 0)

    let resolvedMarkerPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: markerCurrent,
      plan: markerPlan
    )
    let fullyResolvedMarkerPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: markerCurrent,
      plan: .fullDocument(for: markerCurrent)
    )
    XCTAssertNil(resolvedMarkerPlan.codeBlockRescanRange)
    XCTAssertEqual(
      resolvedMarkerPlan.codeBlockRanges,
      fullyResolvedMarkerPlan.codeBlockRanges
    )
  }

  func testChangingCodeFenceResynchronizesFromMarkerAndInvalidRangeStillFallsBack() {
    let fenceCurrent = "before\n```\nafter"
    let fencePlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: "before\n\nafter",
      currentText: fenceCurrent,
      replacedRange: NSRange(location: 7, length: 0),
      knownCodeBlockRanges: []
    )
    XCTAssertEqual(fencePlan.range, NSRange(location: 7, length: 9))
    XCTAssertEqual(fencePlan.codeBlockRanges, [])
    XCTAssertEqual(fencePlan.codeBlockRescanRange, fencePlan.range)
    let resolvedFencePlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: fenceCurrent,
      plan: fencePlan
    )
    let fullyResolvedFencePlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: fenceCurrent,
      plan: .fullDocument(for: fenceCurrent)
    )
    XCTAssertNil(resolvedFencePlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedFencePlan.codeBlockRanges, fullyResolvedFencePlan.codeBlockRanges)

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

  func testUnknownCacheFallsBackWhileFenceEditRequiresBackgroundResolution() {
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
    XCTAssertEqual(fencePlan.range, NSRange(location: 4, length: 7))
    XCTAssertEqual(fencePlan.codeBlockRanges, [])
    XCTAssertEqual(fencePlan.codeBlockRescanRange, fencePlan.range)
    XCTAssertEqual(
      MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
        in: fenced,
        plan: fencePlan
      ).codeBlockRanges,
      MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
        in: fenced,
        plan: .fullDocument(for: fenced)
      ).codeBlockRanges
    )
  }

  func testMillionUTF16UnknownCodeBlockCacheUsesFullDocumentPlan() {
    let markdown = String(
      repeating: "stable paragraph without a fence or inline marker.\n",
      count: 25_000
    )
    let source = markdown as NSString
    XCTAssertGreaterThanOrEqual(source.length, 1_000_000)

    let editLocation = source.length / 2
    let current = source.replacingCharacters(
      in: NSRange(location: editLocation, length: 0),
      with: "🙂"
    )
    let currentSource = current as NSString
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: markdown,
      currentText: current,
      replacedRange: NSRange(location: editLocation, length: 0),
      knownCodeBlockRanges: nil
    )

    XCTAssertEqual(
      plan,
      .fullDocument(for: current),
      "An unknown cache must conservatively cover the complete million-unit document."
    )
    XCTAssertEqual(plan.range, NSRange(location: 0, length: currentSource.length))
    XCTAssertNil(plan.codeBlockRanges)
    XCTAssertNil(plan.codeBlockRescanRange)
  }

  func testMillionUTF16CachedCodeBlockEditStaysInsideBlockAndMatchesFullResolution() throws {
    let stableSegment = String(
      repeating: "stable paragraph with no syntax markers.\n",
      count: 15_000
    )
    let previous = stableSegment
      + "```swift\nlet value = 1\n```\n"
      + stableSegment
    let previousSource = previous as NSString
    XCTAssertGreaterThanOrEqual(previousSource.length, 1_000_000)

    let initialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: previous,
      plan: .fullDocument(for: previous)
    )
    let initialBlocks = try XCTUnwrap(initialPlan.codeBlockRanges)
    XCTAssertEqual(initialBlocks.count, 1)
    let initialBlock = try XCTUnwrap(initialBlocks.first)
    let valueRange = previousSource.range(of: "1")
    let current = previousSource.replacingCharacters(in: valueRange, with: "2")
    let currentSource = current as NSString
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: valueRange,
      knownCodeBlockRanges: initialPlan.codeBlockRanges
    )
    let currentBlocks = try XCTUnwrap(plan.codeBlockRanges)
    XCTAssertEqual(currentBlocks.count, 1)
    let currentBlock = try XCTUnwrap(currentBlocks.first)

    XCTAssertEqual(
      currentSource.substring(with: currentBlock),
      "```swift\nlet value = 2\n```"
    )
    XCTAssertEqual(plan.range, currentBlock)
    XCTAssertLessThan(
      plan.range.length,
      MarkdownSyntaxHighlightSchedulingPolicy.maximumLocalEditUTF16Length
    )
    XCTAssertGreaterThan(plan.range.location, 400_000)
    XCTAssertLessThan(NSMaxRange(plan.range), currentSource.length - 400_000)

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
    XCTAssertEqual(
      currentBlock.location,
      initialBlock.location,
      "An edit inside the block must not move its opening fence in UTF-16 coordinates."
    )
  }

  func testMillionUTF16UnclosedFenceResynchronizesToEOFAndResolvesCorrectly() throws {
    let prefix = String(
      repeating: "stable paragraph before the fence.\n",
      count: 15_000
    )
    let suffix = String(
      repeating: "<div>literal fenced content</div>\n",
      count: 15_000
    )
    let previous = prefix + "insert here\n" + suffix
    let previousSource = previous as NSString
    XCTAssertGreaterThanOrEqual(previousSource.length, 1_000_000)
    let insertionLocation = previousSource.range(of: "insert here").location
    let current = previousSource.replacingCharacters(
      in: NSRange(location: insertionLocation, length: 0),
      with: "~~~html\n"
    )
    let currentSource = current as NSString
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: NSRange(location: insertionLocation, length: 0),
      knownCodeBlockRanges: []
    )
    let pendingRange = try XCTUnwrap(plan.codeBlockRescanRange)

    XCTAssertEqual(pendingRange.location, insertionLocation)
    XCTAssertEqual(NSMaxRange(pendingRange), currentSource.length)
    XCTAssertEqual(plan.range, pendingRange)

    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: plan
    )
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: current,
      plan: .fullDocument(for: current)
    )
    XCTAssertNil(resolvedPlan.codeBlockRescanRange)
    XCTAssertEqual(resolvedPlan.codeBlockRanges, fullyResolvedPlan.codeBlockRanges)
    XCTAssertEqual(resolvedPlan.codeBlockRanges?.count, 1)
    XCTAssertEqual(
      NSMaxRange(try XCTUnwrap(resolvedPlan.codeBlockRanges?.first)),
      currentSource.length
    )
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

  func testSchedulingPolicyKeepsExpensiveDelayWhileFenceStateIsRescanned() {
    let plan = MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 20, length: 100),
      codeBlockRanges: [],
      codeBlockRescanRange: NSRange(location: 20, length: 100)
    )

    XCTAssertEqual(
      MarkdownSyntaxHighlightSchedulingPolicy.delay(
        for: plan,
        documentUTF16Length: 100_000
      ),
      MarkdownSyntaxHighlightSchedulingPolicy.expensiveEditDelay,
      accuracy: 0.000_001
    )
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
