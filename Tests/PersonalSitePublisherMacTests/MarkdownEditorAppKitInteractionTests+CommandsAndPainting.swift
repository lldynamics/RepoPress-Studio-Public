import AppKit
import PublishingMarkdownCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionCommandAndPaintingTests:
  MarkdownEditorAppKitInteractionTestCase
{
  func testSlashCommandTextUsesUTF16OffsetsForEmojiAndComposedCharacters() {
    let emojiBody = "😀\n/ti"
    let emojiCaret = (emojiBody as NSString).length
    XCTAssertEqual(
      MarkdownSlashCommandText.query(in: emojiBody, caretUTF16Location: emojiCaret),
      "ti"
    )
    XCTAssertEqual(
      MarkdownSlashCommandText.replacementRange(
        in: emojiBody,
        caretUTF16Location: emojiCaret
      ),
      NSRange(location: 3, length: 3)
    )

    let composedBody = "e\u{301}\n/h"
    let composedCaret = (composedBody as NSString).length
    XCTAssertEqual(
      MarkdownSlashCommandText.query(in: composedBody, caretUTF16Location: composedCaret),
      "h"
    )
    XCTAssertEqual(
      MarkdownSlashCommandText.replacementRange(
        in: composedBody,
        caretUTF16Location: composedCaret
      ),
      NSRange(location: 3, length: 2)
    )
  }

  func testSlashCommandTextRejectsOutOfBoundsCaret() {
    let body = "正文/"
    let length = (body as NSString).length
    XCTAssertNil(MarkdownSlashCommandText.query(in: body, caretUTF16Location: length + 1))
    XCTAssertNil(MarkdownSlashCommandText.replacementRange(in: body, caretUTF16Location: 0))
  }

  func testSlashCommandKeyRoutingDoesNotFallThroughToTextEditing() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let downEvent = try XCTUnwrap(makeKeyEvent(keyCode: 125))
    let returnEvent = try XCTUnwrap(makeKeyEvent(keyCode: 36))
    textView.keyDown(with: downEvent)
    textView.keyDown(with: returnEvent)

    XCTAssertEqual(receivedKeys, [.moveDown, .select])
    XCTAssertEqual(textView.string, "原文")
  }

  func testSlashCommandKeyRoutingConsumesUpAndEscapeWithoutEditing() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let upEvent = try XCTUnwrap(makeKeyEvent(keyCode: 126))
    let escapeEvent = try XCTUnwrap(makeKeyEvent(keyCode: 53))
    textView.keyDown(with: upEvent)
    textView.keyDown(with: escapeEvent)

    XCTAssertEqual(receivedKeys, [.moveUp, .dismiss])
    XCTAssertEqual(textView.string, "原文")
  }

  func testSlashCommandSelectionWrapsAtBoundariesAndHandlesEmptyLists() {
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 0,
        itemCount: 3,
        direction: .moveUp
      ),
      2
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 2,
        itemCount: 3,
        direction: .moveDown
      ),
      0
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 99,
        itemCount: 3,
        direction: .moveDown
      ),
      0
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: -1,
        itemCount: 3,
        direction: .moveUp
      ),
      2
    )
    XCTAssertEqual(
      MarkdownSlashCommandSelection.move(
        currentIndex: 0,
        itemCount: 0,
        direction: .moveDown
      ),
      0
    )
  }

  func testSlashCommandFilteringKeepsSelectedIndexWithinBounds() {
    let items = [
      SlashCommandItem(id: "h1", title: "一级标题", subtitle: "#", systemImage: "textformat") {},
      SlashCommandItem(id: "quote", title: "引用块", subtitle: ">", systemImage: "text.quote") {},
    ]
    XCTAssertEqual(
      MarkdownSlashCommandMenu.filteredItems(from: items, matching: "quote").map(\.id),
      ["quote"]
    )
    XCTAssertTrue(
      MarkdownSlashCommandMenu.filteredItems(from: items, matching: "missing").isEmpty
    )
  }

  func testSlashCommandKeyRoutingLeavesModifiedKeysToTextView() throws {
    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    var receivedKeys: [MarkdownSlashCommandKey] = []
    textView.slashCommandKeyHandler = { key in
      receivedKeys.append(key)
      return true
    }

    let commandDown = try XCTUnwrap(
      makeKeyEvent(keyCode: 125, modifiers: [.command])
    )
    textView.keyDown(with: commandDown)

    XCTAssertTrue(receivedKeys.isEmpty)
    XCTAssertEqual(
      MarkdownSlashCommandKey.from(keyCode: 125, modifiers: [.function]),
      .moveDown
    )
    XCTAssertEqual(
      MarkdownSlashCommandKey.from(keyCode: 76, modifiers: [.numericPad]),
      .select
    )
  }

  func testInlineAIRequestShortcutInvokesHandlerAndConsumesOptionBackslash() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var requestCount = 0
    textView.inlineAIRequestHandler = {
      requestCount += 1
    }

    let event = try XCTUnwrap(
      makeKeyEvent(
        keyCode: 0x2A,
        modifiers: [.option],
        characters: "«",
        charactersIgnoringModifiers: "\\"
      )
    )
    textView.keyDown(with: event)

    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(textView.string, "原文")
  }

  func testRepeatedInlineAIRequestShortcutIsConsumedWithoutRequestingAgain() throws {
    let textView = makeTextView()
    textView.string = "原文"
    var requestCount = 0
    textView.inlineAIRequestHandler = {
      requestCount += 1
    }

    let event = try XCTUnwrap(
      makeKeyEvent(
        keyCode: 0x2A,
        modifiers: [.option],
        characters: "«",
        charactersIgnoringModifiers: "\\",
        isARepeat: true
      )
    )
    textView.keyDown(with: event)

    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(textView.string, "原文")
  }

  func testPlainAndExtraModifiedBackslashDoNotRequestInlineAI() throws {
    let textView = makeTextView()
    var requestCount = 0
    textView.inlineAIRequestHandler = {
      requestCount += 1
    }

    let plainEvent = try XCTUnwrap(
      makeKeyEvent(
        keyCode: 0x2A,
        characters: "\\",
        charactersIgnoringModifiers: "\\"
      )
    )
    let shiftedOptionEvent = try XCTUnwrap(
      makeKeyEvent(
        keyCode: 0x2A,
        modifiers: [.shift, .option],
        characters: "»",
        charactersIgnoringModifiers: "\\"
      )
    )
    textView.keyDown(with: plainEvent)
    textView.keyDown(with: shiftedOptionEvent)

    XCTAssertEqual(requestCount, 0)
  }

  func testTabWithGhostTextKeepsAcceptanceRouteSeparateFromInlineAIRequest() throws {
    let textView = makeTextView()
    var acceptedCount = 0
    var requestCount = 0
    textView.ghostTextAcceptHandler = {
      acceptedCount += 1
      return true
    }
    textView.inlineAIRequestHandler = {
      requestCount += 1
    }

    let tabEvent = try XCTUnwrap(
      makeKeyEvent(
        keyCode: 48,
        characters: "\t",
        charactersIgnoringModifiers: "\t"
      )
    )
    textView.keyDown(with: tabEvent)

    XCTAssertEqual(acceptedCount, 1)
    XCTAssertEqual(requestCount, 0)
  }

  func testComfortDefaultsIncludeParagraphSpotlightReset() {
    XCTAssertFalse(MarkdownEditorComfortConfiguration.defaultParagraphSpotlightEnabled)
  }

  func testSelectionInvalidationOnlyIncludesMarkersWhoseActiveRunChanged() {
    let source = "**first** plain **second**"
    let sourceValue = source as NSString
    let firstRun = sourceValue.range(of: "**first**")
    let secondRun = sourceValue.range(of: "**second**")
    let index = MarkdownSyntaxHighlightRunIndex(runs: [
      MarkdownSyntaxHighlightRun(style: .bold, range: firstRun),
      MarkdownSyntaxHighlightRun(style: .bold, range: secondRun),
    ])

    let ranges = MarkdownSyntaxSelectionInvalidationPlan.ranges(
      in: source,
      runIndex: index,
      previousSelection: NSRange(location: firstRun.location + 3, length: 0),
      currentSelection: NSRange(location: secondRun.location + 3, length: 0),
      paintedRange: NSRange(location: 0, length: sourceValue.length)
    )

    XCTAssertEqual(
      ranges,
      [
        NSRange(location: firstRun.location, length: 2),
        NSRange(location: NSMaxRange(firstRun) - 2, length: 2),
        NSRange(location: secondRun.location, length: 2),
        NSRange(location: NSMaxRange(secondRun) - 2, length: 2),
      ]
    )
    XCTAssertLessThan(
      ranges.reduce(0) { $0 + $1.length },
      sourceValue.length
    )
  }

  func testSelectionMovingInsideSameRunDoesNotInvalidateMarkerAttributes() {
    let source = "prefix **first** suffix"
    let run = (source as NSString).range(of: "**first**")
    let index = MarkdownSyntaxHighlightRunIndex(runs: [
      MarkdownSyntaxHighlightRun(style: .bold, range: run)
    ])

    XCTAssertTrue(
      MarkdownSyntaxSelectionInvalidationPlan.ranges(
        in: source,
        runIndex: index,
        previousSelection: NSRange(location: run.location + 2, length: 0),
        currentSelection: NSRange(location: run.location + 5, length: 0),
        paintedRange: NSRange(location: 0, length: (source as NSString).length)
      ).isEmpty
    )
  }

  func testSelectionInvalidationClipsLongSelectionToPaintedViewport() {
    let source = "**first** " + String(repeating: "x", count: 10_000) + " **last**"
    let sourceValue = source as NSString
    let firstRun = sourceValue.range(of: "**first**")
    let lastRun = sourceValue.range(of: "**last**")
    let index = MarkdownSyntaxHighlightRunIndex(runs: [
      MarkdownSyntaxHighlightRun(style: .bold, range: firstRun),
      MarkdownSyntaxHighlightRun(style: .bold, range: lastRun),
    ])

    let ranges = MarkdownSyntaxSelectionInvalidationPlan.ranges(
      in: source,
      runIndex: index,
      previousSelection: NSRange(location: 0, length: sourceValue.length),
      currentSelection: NSRange(location: firstRun.location + 3, length: 0),
      paintedRange: NSRange(location: 0, length: 128)
    )

    XCTAssertTrue(ranges.allSatisfy { NSMaxRange($0) <= 128 })
    XCTAssertFalse(ranges.contains { NSIntersectionRange($0, lastRun).length > 0 })
  }

  func testPaintedRangesShiftAcrossLocalUTF16EditAndDropTouchedMarkers() {
    let previous = "a🙂 **bold** tail"
    let previousValue = previous as NSString
    let replacementRange = previousValue.range(of: "a")
    let current = previousValue.replacingCharacters(in: replacementRange, with: "added")
    let markerRange = previousValue.range(of: "**")
    let trailingRange = previousValue.range(of: "tail")
    let markerDeletedLength = previousValue.length - markerRange.length

    XCTAssertEqual(
      MarkdownSyntaxPaintedRangeTransform.range(
        trailingRange,
        previousLength: previousValue.length,
        currentLength: (current as NSString).length,
        replacedRange: replacementRange
      ),
      NSRange(location: trailingRange.location + 4, length: trailingRange.length)
    )
    XCTAssertEqual(
      MarkdownSyntaxPaintedRangeTransform.retainedMarkerRanges(
        [markerRange, trailingRange],
        previousLength: previousValue.length,
        currentLength: markerDeletedLength,
        replacedRange: markerRange
      ),
      [
        NSRange(
          location: trailingRange.location - markerRange.length,
          length: trailingRange.length
        )
      ]
    )
    XCTAssertEqual(
      MarkdownSyntaxPaintedRangeTransform.selectionRange(
        NSRange(location: trailingRange.location, length: 0),
        previousLength: previousValue.length,
        currentLength: (current as NSString).length,
        replacedRange: replacementRange
      ),
      NSRange(location: trailingRange.location + 4, length: 0)
    )
  }

  func testStableLocalEditPreservesPaintedViewportForDirtyRangeRepaint() throws {
    let previous = "**bold**\nplain text\nlast line\n"
    let editRange = (previous as NSString).range(of: "plain")
    let current = (previous as NSString).replacingCharacters(in: editRange, with: "updated")
    let edit = MarkdownTextEdit(previousText: previous, replacedRange: editRange)
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: previous,
      currentText: current,
      replacedRange: editRange,
      knownCodeBlockRanges: []
    )
    let coordinator = makeCoordinator(
      source: previous,
      bodyMarkdown: previous,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = current
    coordinator.syntaxParsedSnapshotCache = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: (previous as NSString).length),
      runs: []
    )
    coordinator.syntaxParsedDocumentRevision = 0
    coordinator.syntaxPaintedDocumentRevision = 0
    coordinator.paintedSyntaxViewportRange = NSRange(
      location: 0,
      length: (previous as NSString).length
    )
    coordinator.paintedSyntaxSelectionRange = NSRange(
      location: (previous as NSString).range(of: "last").location,
      length: 0
    )
    coordinator.syntaxDocumentRevision = 1
    coordinator.pendingSyntaxParserEdit = try XCTUnwrap(
      MarkdownSyntaxHighlightEditAccumulator(
        previousText: previous,
        currentText: current,
        replacedRange: editRange,
        previousRevision: 0,
        currentRevision: 1
      )
    )

    XCTAssertTrue(
      coordinator.reconcilePaintedSyntaxState(
        after: edit,
        plan: plan,
        previousRevision: 0,
        currentText: current,
        in: textView
      )
    )
    XCTAssertEqual(coordinator.syntaxPaintedDocumentRevision, 1)
    XCTAssertEqual(
      coordinator.paintedSyntaxViewportRange,
      NSRange(location: 0, length: (current as NSString).length)
    )
    XCTAssertEqual(
      coordinator.paintedSyntaxSelectionRange,
      NSRange(
        location: (current as NSString).range(of: "last").location,
        length: 0
      )
    )
  }

  func testFullDocumentPlanDiscardsPaintedStateForStructuralFallback() {
    let previous = "```swift\ncode\n```\nparagraph\n"
    let markerRange = (previous as NSString).range(of: "```")
    let current = (previous as NSString).replacingCharacters(in: markerRange, with: "``")
    let coordinator = makeCoordinator(
      source: previous,
      bodyMarkdown: previous,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = current
    coordinator.syntaxParsedSnapshotCache = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: (previous as NSString).length),
      runs: []
    )
    coordinator.syntaxParsedDocumentRevision = 0
    coordinator.syntaxPaintedDocumentRevision = 0
    coordinator.paintedSyntaxViewportRange = NSRange(
      location: 0,
      length: (previous as NSString).length
    )
    coordinator.syntaxDocumentRevision = 1

    XCTAssertFalse(
      coordinator.reconcilePaintedSyntaxState(
        after: MarkdownTextEdit(previousText: previous, replacedRange: markerRange),
        plan: .fullDocument(for: current),
        previousRevision: 0,
        currentText: current,
        in: textView
      )
    )
    XCTAssertNil(coordinator.syntaxPaintedDocumentRevision)
    XCTAssertNil(coordinator.paintedSyntaxViewportRange)
  }

  func testStartingEditRestoresCollapsedMarkerLayoutFont() throws {
    let source = "**bold**"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = NSTextView()
    textView.string = source
    let markerRange = NSRange(location: 0, length: 2)
    textView.textStorage?.addAttribute(
      .font,
      value: coordinator.syntaxHighlightPalette.inactiveMarkerLayoutFont,
      range: markerRange
    )
    coordinator.collapsedSyntaxMarkerRanges = [markerRange]
    coordinator.syntaxPaintedDocumentRevision = coordinator.syntaxDocumentRevision
    coordinator.paintedSyntaxViewportRange = NSRange(location: 0, length: source.utf16.count)

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: NSRange(location: 2, length: 0),
        replacementString: "x"
      )
    )

    let restoredFont = try XCTUnwrap(
      textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    )
    XCTAssertEqual(
      restoredFont.pointSize,
      coordinator.syntaxHighlightPalette.baseFont.pointSize,
      accuracy: 0.01
    )
    XCTAssertTrue(coordinator.collapsedSyntaxMarkerRanges.isEmpty)
    XCTAssertEqual(textView.string, source)
  }

  func testStartingEditPreservesPaintOnlyBlockMarkerUntilViewportDiff() throws {
    let source = "- [ ] first\nparagraph\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    let initialSubviewCount = textView.subviews.count
    let markerRange = (source as NSString).range(of: "- [ ] ")
    let marker = MarkdownSyntaxMarker(
      range: markerRange,
      presentation: .taskList(isChecked: false)
    )
    coordinator.applyBlockMarkerDrawings([marker], in: textView)
    let originalDrawing = try XCTUnwrap(textView.markdownBlockMarkerDrawings.first)
    coordinator.syntaxPaintedDocumentRevision = coordinator.syntaxDocumentRevision
    coordinator.paintedSyntaxViewportRange = NSRange(
      location: 0,
      length: (source as NSString).length
    )

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: NSRange(location: (source as NSString).length, length: 0),
        replacementString: "x"
      )
    )

    XCTAssertEqual(textView.markdownBlockMarkerDrawings, [originalDrawing])
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
  }

  func testFullRepaintCleanupRestoresHiddenMarkerAttributes() throws {
    let source = "**bold**"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    let markerRange = NSRange(location: 0, length: 2)
    textView.textStorage?.addAttribute(
      .font,
      value: coordinator.syntaxHighlightPalette.inactiveMarkerLayoutFont,
      range: markerRange
    )
    coordinator.collapsedSyntaxMarkerRanges = [markerRange]
    coordinator.syntaxPaintedDocumentRevision = coordinator.syntaxDocumentRevision
    coordinator.paintedSyntaxViewportRange = NSRange(
      location: 0,
      length: source.utf16.count
    )

    coordinator.removePaintedSyntaxAttributes(in: textView)

    let restoredFont = try XCTUnwrap(
      textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    )
    XCTAssertEqual(
      restoredFont.pointSize,
      coordinator.syntaxHighlightPalette.baseFont.pointSize,
      accuracy: 0.01
    )
    XCTAssertTrue(coordinator.collapsedSyntaxMarkerRanges.isEmpty)
    XCTAssertNil(coordinator.paintedSyntaxViewportRange)
  }

}
