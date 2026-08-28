import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionSyntaxAndAttachmentTests:
  MarkdownEditorAppKitInteractionTestCase
{
  func testOrdinaryEditSynchronizesIncrementalTreeOnImmediateHighlightPath() async throws {
    let initial = "# Title\n\nParagraph with **bold** text.\n\n```swift\nlet value = 1\n```\n"
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = initial
    coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: initial)
    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()

    XCTAssertEqual(coordinator.syntaxTreeDocumentRevision, 0)
    let editRange = (initial as NSString).range(of: "bold")
    let updated = (initial as NSString).replacingCharacters(in: editRange, with: "strong")
    let revision: UInt64 = 1
    coordinator.syntaxDocumentRevision = revision
    coordinator.pendingSyntaxParserEdit = try XCTUnwrap(
      MarkdownSyntaxHighlightEditAccumulator(
        previousText: initial,
        currentText: updated,
        replacedRange: editRange,
        previousRevision: 0,
        currentRevision: revision
      )
    )
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: initial,
      currentText: updated,
      replacedRange: editRange,
      knownCodeBlockRanges: coordinator.syntaxCodeBlockRanges
    )
    textView.string = updated
    coordinator.scheduleMarkdownSyntaxHighlighting(
      for: textView,
      text: updated,
      plan: plan
    )

    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()
    let fastPathMetrics = await coordinator.syntaxHighlightParser.metrics()
    XCTAssertEqual(coordinator.syntaxParsedDocumentRevision, revision)
    XCTAssertEqual(coordinator.syntaxTreeDocumentRevision, revision)
    XCTAssertNil(coordinator.pendingSyntaxParserEdit)
    XCTAssertEqual(fastPathMetrics.lightweightSnapshotCount, 0)
    XCTAssertEqual(fastPathMetrics.incrementalParseCount, 1)
    XCTAssertEqual(fastPathMetrics.editHintParseCount, 1)
    XCTAssertEqual(
      coordinator.syntaxTreeSynchronizationDebouncer.metrics.scheduledRequestCount,
      0
    )
  }

  func testTextDidChangeInfersMissingEditHintAndKeepsIncrementalTreePath() async throws {
    let initial = (0..<200).map { index in
      index == 100 ? "second token\n" : "line \(index)\n"
    }.joined()
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = initial
    coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: initial)
    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()

    let tokenRange = (initial as NSString).range(of: "token")
    let updated = (initial as NSString).replacingCharacters(
      in: tokenRange,
      with: "value"
    )
    textView.string = updated
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertNil(coordinator.pendingTextEdit)
    XCTAssertEqual(coordinator.pendingSyntaxParserEdit?.replacedRange, tokenRange)
    XCTAssertLessThan(
      try XCTUnwrap(coordinator.pendingSyntaxHighlightPlan).range.length,
      (updated as NSString).length
    )

    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()
    let metrics = await coordinator.syntaxHighlightParser.metrics()
    XCTAssertEqual(coordinator.syntaxTreeDocumentRevision, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.editHintParseCount, 1)
  }

  func testTextDidChangePassesConsumedEditToIncrementalStatistics() {
    let initial = "正文 with a small word edit."
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    coordinator.statistics = MarkdownEditorStatistics.make(for: initial)
    coordinator.statisticsText = initial
    coordinator.statisticsFullScanCount = 0
    coordinator.statisticsIncrementalUpdateCount = 0

    let textView = NSTextView()
    textView.string = initial
    let editRange = (initial as NSString).range(of: "small")
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: editRange,
        replacementString: "tiny"
      )
    )
    let updated = (initial as NSString).replacingCharacters(in: editRange, with: "tiny")
    textView.string = updated
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertNil(coordinator.pendingTextEdit)
    XCTAssertEqual(coordinator.statisticsIncrementalUpdateCount, 1)
    XCTAssertEqual(coordinator.statisticsFullScanCount, 0)
    XCTAssertEqual(coordinator.statistics, MarkdownEditorStatistics.make(for: updated))
  }

  func testMultipleIMEPreeditCallbacksInferOneCumulativeUTF16Edit() throws {
    let initial = "**A** 正文"
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    let textView = NSTextView()
    textView.string = initial

    let firstRange = (textView.string as NSString).range(of: "A")
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: firstRange,
        replacementString: "你"
      )
    )
    textView.replaceCharacters(in: firstRange, with: "你")
    let secondRange = (textView.string as NSString).range(of: "你")
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: secondRange,
        replacementString: "😀"
      )
    )
    textView.replaceCharacters(in: secondRange, with: "😀")
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    let accumulated = try XCTUnwrap(coordinator.pendingSyntaxParserEdit)
    XCTAssertEqual(accumulated.baseText, initial)
    XCTAssertEqual(accumulated.replacedRange, firstRange)
    XCTAssertEqual(accumulated.replacementRange.length, ("😀" as NSString).length)
    XCTAssertFalse(coordinator.pendingTextEditRequiresInference)
    XCTAssertNil(coordinator.pendingTextEdit)
  }

  func testStatisticsFallsBackToFullScanForLargeOrStaleEdits() {
    let initial = String(repeating: "a", count: 5_000)
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    coordinator.statistics = MarkdownEditorStatistics.make(for: initial)
    coordinator.statisticsText = initial
    coordinator.statisticsFullScanCount = 0
    coordinator.statisticsIncrementalUpdateCount = 0

    let largePaste = String(repeating: "b", count: 5_000)
    coordinator.updateStatistics(
      afterEditing: initial + largePaste,
      edit: MarkdownTextEdit(
        previousText: initial,
        replacedRange: NSRange(location: initial.utf16.count, length: 0)
      )
    )

    coordinator.updateStatistics(
      afterEditing: "replacement",
      edit: MarkdownTextEdit(
        previousText: initial,
        replacedRange: NSRange(location: 0, length: initial.utf16.count)
      )
    )

    coordinator.updateStatistics(
      afterEditing: "stale edit",
      edit: MarkdownTextEdit(
        previousText: "different baseline",
        replacedRange: NSRange(location: 0, length: 0)
      )
    )

    XCTAssertEqual(coordinator.statisticsIncrementalUpdateCount, 0)
    XCTAssertEqual(coordinator.statisticsFullScanCount, 3)
  }

  func testStatisticsFullScanDelayPolicyDefersOnlyEditedLongDocuments() {
    let shortDocument = String(repeating: "a", count: 5_000)
    let longDocument = String(repeating: "a", count: 5_001)

    XCTAssertEqual(
      MarkdownEditorStatisticsDelayPolicy.fullScanDelay(
        for: shortDocument,
        isInitialLoad: false
      ),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      MarkdownEditorStatisticsDelayPolicy.fullScanDelay(
        for: longDocument,
        isInitialLoad: true
      ),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      MarkdownEditorStatisticsDelayPolicy.fullScanDelay(
        for: longDocument,
        isInitialLoad: false
      ),
      2.5,
      accuracy: 0.001
    )
  }

  func testFenceEditSynchronizesTreeOnStrictHighlightPath() async throws {
    let initial = "before\n```swift\nlet value = 1\n```\nafter\n"
    let coordinator = makeCoordinator(
      source: initial,
      bodyMarkdown: initial,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = initial
    coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: initial)
    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()

    let editRange = NSRange(location: (initial as NSString).range(of: "```").location, length: 1)
    let updated = (initial as NSString).replacingCharacters(in: editRange, with: "~")
    let plan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: initial,
      currentText: updated,
      replacedRange: editRange,
      knownCodeBlockRanges: coordinator.syntaxCodeBlockRanges
    )
    XCTAssertTrue(plan.requiresCodeBlockResynchronization)
    coordinator.syntaxDocumentRevision = 1
    textView.string = updated
    coordinator.scheduleMarkdownSyntaxHighlighting(
      for: textView,
      text: updated,
      plan: plan
    )
    await coordinator.syntaxHighlightDebouncer.waitUntilIdle()

    let metrics = await coordinator.syntaxHighlightParser.metrics()
    XCTAssertEqual(coordinator.syntaxParsedDocumentRevision, 1)
    XCTAssertEqual(coordinator.syntaxTreeDocumentRevision, 1)
    XCTAssertEqual(metrics.incrementalParseCount, 1)
    XCTAssertEqual(metrics.lightweightSnapshotCount, 0)
    XCTAssertEqual(
      coordinator.syntaxTreeSynchronizationDebouncer.metrics.scheduledRequestCount,
      0
    )
  }

  func testMarkdownEditorFactoryBuildsTextKit2Network() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )

    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    XCTAssertTrue(layoutManager.textContentManager is NSTextContentStorage)
    XCTAssertNotNil(textView.textStorage)
    XCTAssertNotNil(textView.textContainer)
  }

  func testNativeTaskToggleMutatesOnlyCheckboxStateCharacter() {
    let source = "- [ ] first\n  - [x] nested"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    textView.delegate = coordinator
    let selection = NSRange(location: (source as NSString).length, length: 0)
    textView.setSelectedRange(selection)

    coordinator.setTaskMarker(
      (source as NSString).range(of: "- [ ] "),
      checked: true,
      in: textView
    )

    XCTAssertEqual(textView.string, "- [x] first\n  - [x] nested")
    XCTAssertEqual(textView.selectedRange(), selection)
  }

  func testTaskMarkerClickUsesSingleTextViewHitProxyAndPreservesSelection() {
    let source = "- [ ] first\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      containerSize: NSSize(width: 320, height: 180)
    )
    let initialSubviewCount = textView.subviews.count
    textView.string = source
    let markerRange = (source as NSString).range(of: "- [ ] ")
    let selection = NSRange(location: source.utf16.count, length: 0)
    textView.setSelectedRange(selection)
    textView.markdownBlockMarkerDrawings = [
      MarkdownBlockMarkerDrawing(
        marker: MarkdownSyntaxMarker(
          range: markerRange,
          presentation: .taskList(isChecked: false)
        ),
        frame: NSRect(x: 8, y: 8, width: 18, height: 18),
        taskHitFrame: NSRect(x: 8, y: 8, width: 18, height: 18)
      )
    ]
    textView.markdownBlockMarkerTaskToggleHandler = { range, checked in
      coordinator.setTaskMarker(range, checked: checked, in: textView)
    }

    XCTAssertTrue(
      textView.handleMarkdownBlockMarkerClick(at: NSPoint(x: 14, y: 14))
    )

    XCTAssertEqual(textView.string, "- [x] first\n")
    XCTAssertEqual(textView.selectedRange(), selection)
    XCTAssertEqual(
      textView.markdownBlockMarkerDrawings.first?.marker.presentation,
      .taskList(isChecked: true)
    )
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
  }

  func testPaintedTaskMarkerVendsAccessibilityCheckboxWithoutChildView() throws {
    let source = "- [ ] first\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      containerSize: NSSize(width: 320, height: 180)
    )
    let initialSubviewCount = textView.subviews.count
    textView.string = source
    let markerRange = (source as NSString).range(of: "- [ ] ")
    let markerFrame = NSRect(x: 8, y: 8, width: 18, height: 18)
    textView.markdownBlockMarkerDrawings = [
      MarkdownBlockMarkerDrawing(
        marker: MarkdownSyntaxMarker(
          range: markerRange,
          presentation: .taskList(isChecked: false)
        ),
        frame: markerFrame,
        taskHitFrame: markerFrame
      )
    ]
    textView.markdownBlockMarkerTaskToggleHandler = { range, checked in
      coordinator.setTaskMarker(range, checked: checked, in: textView)
    }

    let checkbox = try XCTUnwrap(
      textView.markdownTaskCheckboxAccessibilityElements.first
    )
    XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
    XCTAssertEqual(checkbox.accessibilityLabel(), "标记任务为已完成")
    XCTAssertEqual(checkbox.accessibilityValue() as? NSNumber, NSNumber(value: false))
    XCTAssertEqual(checkbox.accessibilityFrameInParentSpace(), markerFrame)
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
    XCTAssertTrue(
      textView.accessibilityChildren()?.contains {
        ($0 as AnyObject) === checkbox
      } == true
    )

    let selection = NSRange(location: source.utf16.count, length: 0)
    textView.setSelectedRange(selection)
    XCTAssertTrue(checkbox.performAccessibilityPress())
    XCTAssertEqual(textView.string, "- [x] first\n")
    XCTAssertEqual(textView.selectedRange(), selection)
    let updatedCheckbox = try XCTUnwrap(
      textView.markdownTaskCheckboxAccessibilityElements.first
    )
    XCTAssertEqual(updatedCheckbox.accessibilityValue() as? NSNumber, NSNumber(value: true))
  }

  func testTextKit2RangeAdapterRoundTripsUTF16Ranges() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = "A😀B"
    let emojiRange = NSRange(location: 1, length: 2)

    let textRange = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.textRange(for: emojiRange, in: textView)
    )
    XCTAssertEqual(
      MarkdownTextKit2RangeAdapter.range(for: textRange, in: textView),
      emojiRange
    )
    XCTAssertNil(
      MarkdownTextKit2RangeAdapter.textRange(
        for: NSRange(location: 5, length: 1),
        in: textView
      )
    )
  }

  func testTextKit2RangeResolverUsesViewportRelativeUTF16Ranges() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = String(repeating: "prefix ", count: 15_000) + "A😀B"
    let source = textView.string as NSString
    let baseRange = NSRange(location: source.length - 100, length: 100)
    let emojiRange = source.range(of: "😀")
    let resolver = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rangeResolver(for: baseRange, in: textView)
    )
    let resolvedRange = try XCTUnwrap(resolver.textRange(for: emojiRange))

    XCTAssertEqual(
      MarkdownTextKit2RangeAdapter.range(for: resolvedRange, in: textView),
      emojiRange
    )
    XCTAssertNil(
      resolver.textRange(for: NSRange(location: baseRange.location - 1, length: 1))
    )
  }

  func testSyntaxRenderingDoesNotWriteSemanticAttributesIntoTextStorage() throws {
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = "# title\nbody outside viewport"
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: 7),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 0, length: 7)
        )
      ]
    )

    let appliedRunCount = MarkdownTextKit2RangeAdapter.applySyntaxHighlighting(
      snapshot,
      defaultAttributes: [.foregroundColor: NSColor.labelColor],
      styleAttributes: [.heading: [.foregroundColor: NSColor.systemBlue]],
      in: textView
    )

    XCTAssertEqual(appliedRunCount, 1)
    let textStorage = try XCTUnwrap(textView.textStorage)
    XCTAssertNotEqual(
      textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor,
      NSColor.systemBlue
    )
    XCTAssertNotEqual(
      textStorage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor,
      NSColor.systemBlue
    )
  }

  func testInlineAttachmentPlanningUsesLiveTextKitDocumentBeforeBindingCatchesUp() {
    let staleBody = "旧正文"
    let liveBody = "正文\n\n$$\nE = mc^2\n$$\n"
    let coordinator = makeCoordinator(
      source: staleBody,
      bodyMarkdown: staleBody,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = liveBody
    textView.setSelectedRange(NSRange(location: 0, length: 0))

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: NSRange(location: 0, length: (liveBody as NSString).length)
    )

    XCTAssertEqual(coordinator.inlineAttachmentPaintedRanges.count, 1)
    XCTAssertEqual(coordinator.inlineAttachmentDrawingDescriptors.count, 1)
    XCTAssertGreaterThan(
      (textView.textStorage?.attribute(
        .paragraphStyle,
        at: 10,
        effectiveRange: nil
      ) as? NSParagraphStyle)?.minimumLineHeight ?? 0,
      0
    )
    XCTAssertEqual(textView.string, liveBody)
    XCTAssertEqual(coordinator.bodyMarkdown, staleBody)
    coordinator.clearInlineAttachmentDrawings(in: textView)
    textView.setSelectedRange(NSRange(location: 10, length: 0))
    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: NSRange(location: 0, length: (liveBody as NSString).length)
    )

    XCTAssertTrue(coordinator.inlineAttachmentDrawingDescriptors.isEmpty)
    XCTAssertTrue(coordinator.inlineAttachmentPaintedRanges.isEmpty)
    XCTAssertEqual(
      (textView.textStorage?.attribute(
        .paragraphStyle,
        at: 10,
        effectiveRange: nil
      ) as? NSParagraphStyle)?.minimumLineHeight ?? 0,
      0
    )
    XCTAssertNotEqual(
      textView.textStorage?.attribute(
        .foregroundColor,
        at: 10,
        effectiveRange: nil
      ) as? NSColor,
      NSColor.clear
    )
  }

  func testOrdinaryEditIncrementallyReusesInlineAttachmentPlan() throws {
    let previous = "开头正文\n\n$$\nE = mc^2\n$$\n"
    let coordinator = makeCoordinator(
      source: previous,
      bodyMarkdown: previous,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = previous
    textView.setSelectedRange(NSRange(location: (previous as NSString).length, length: 0))
    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: NSRange(location: 0, length: (previous as NSString).length)
    )
    XCTAssertEqual(coordinator.inlineAttachmentPlanComputationCount, 1)

    let insertionRange = NSRange(location: 2, length: 0)
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: insertionRange,
        replacementString: "新增"
      )
    )
    textView.replaceCharacters(in: insertionRange, with: "新增")
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    let current = textView.string

    XCTAssertEqual(coordinator.inlineAttachmentPlanIncrementalUpdateCount, 1)
    XCTAssertEqual(coordinator.inlineAttachmentPlanComputationCount, 1)
    XCTAssertEqual(
      coordinator.inlineAttachmentPlan,
      MarkdownInlineAttachmentPlanService.plan(in: current)
    )
  }

  func testBlockMarkerViewportSyncUsesPaintOnlyDrawings() throws {
    let source = "- [ ] first\n- [x] second\n"
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

    let firstRange = (source as NSString).range(of: "- [ ] ")
    let secondRange = (source as NSString).range(of: "- [x] ")
    let firstMarker = MarkdownSyntaxMarker(
      range: firstRange,
      presentation: .taskList(isChecked: false)
    )
    let secondMarker = MarkdownSyntaxMarker(
      range: secondRange,
      presentation: .taskList(isChecked: true)
    )

    coordinator.applyBlockMarkerDrawings([firstMarker], in: textView)
    let firstDrawing = try XCTUnwrap(textView.markdownBlockMarkerDrawings.first)
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)

    coordinator.applyBlockMarkerDrawings(
      [firstMarker, secondMarker],
      in: textView
    )
    XCTAssertEqual(textView.markdownBlockMarkerDrawings.count, 2)
    XCTAssertEqual(
      textView.markdownBlockMarkerDrawings.first?.marker,
      firstDrawing.marker
    )
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)

    coordinator.applyBlockMarkerDrawings([secondMarker], in: textView)
    XCTAssertEqual(textView.markdownBlockMarkerDrawings.count, 1)
    XCTAssertEqual(
      textView.markdownBlockMarkerDrawings.first?.marker,
      secondMarker
    )
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
  }

  func testInlineAttachmentViewportSyncReusesFormulaAndImageTask() async throws {
    let fixtureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownInlineAttachmentViewport-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 16,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: fixtureURL, options: .atomic)

    let source = "$$\nE = mc^2\n$$\n\n![cover](cover.png)\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    coordinator.attachments = [
      DraftAttachment(
        originalFilename: "cover.png",
        relativePublishPath: "cover.png",
        repositoryPath: "cover.png",
        sourceFilePath: fixtureURL.path
      )
    ]
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    let applicationRange = NSRange(location: 0, length: source.utf16.count)
    let initialSubviewCount = textView.subviews.count

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange
    )
    let planComputationCount = coordinator.inlineAttachmentPlanComputationCount

    let formulaRange = (source as NSString).range(of: "$$\nE = mc^2\n$$")
    let imageRange = (source as NSString).range(of: "![cover](cover.png)")
    let formulaKey = "attachment:\(formulaRange.location)"
    let imageKey = "attachment:\(imageRange.location)"
    let formulaDrawing = try XCTUnwrap(
      coordinator.inlineAttachmentDrawingDescriptors[formulaKey]
    )
    let imageDrawing = try XCTUnwrap(
      coordinator.inlineAttachmentDrawingDescriptors[imageKey]
    )
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
    XCTAssertEqual(textView.markdownInlineAttachmentDrawings.count, 2)
    XCTAssertEqual(textView.markdownInlineAttachmentAccessibilityElements.count, 2)
    XCTAssertEqual(
      textView.markdownInlineAttachmentAccessibilityElements.map { $0.accessibilityRole() },
      [.staticText, .image]
    )
    XCTAssertNotNil(coordinator.inlineAttachmentImageTasks[imageKey])

    coordinator.inlineAttachmentImageTasks[imageKey]?.cancel()
    let probe = MarkdownInlineAttachmentTaskCancellationProbe()
    let sentinel: Task<Void, Never> = Task { @MainActor in
      probe.started = true
      while !Task.isCancelled {
        await Task.yield()
      }
      probe.cancelled = true
    }
    coordinator.inlineAttachmentImageTasks[imageKey] = sentinel
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(probe.started)

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange,
      preservingExisting: true
    )

    XCTAssertTrue(
      coordinator.inlineAttachmentDrawingDescriptors[formulaKey] == formulaDrawing
    )
    XCTAssertTrue(
      coordinator.inlineAttachmentDrawingDescriptors[imageKey] == imageDrawing
    )
    XCTAssertEqual(textView.subviews.count, initialSubviewCount)
    XCTAssertTrue(coordinator.inlineAttachmentImageTasks[imageKey] != nil)
    XCTAssertEqual(
      coordinator.inlineAttachmentPlanComputationCount,
      planComputationCount
    )
    for _ in 0..<4 { await Task.yield() }
    XCTAssertFalse(probe.cancelled)

    textView.setSelectedRange(NSRange(location: formulaRange.location + 1, length: 0))
    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange,
      preservingExisting: true
    )
    XCTAssertNil(coordinator.inlineAttachmentDrawingDescriptors[formulaKey])
    XCTAssertEqual(
      coordinator.inlineAttachmentDrawingDescriptors[imageKey],
      imageDrawing
    )
    XCTAssertNotNil(coordinator.inlineAttachmentImageTasks[imageKey])
    XCTAssertFalse(probe.cancelled)
    XCTAssertNotEqual(
      textView.textStorage?.attribute(
        .foregroundColor,
        at: formulaRange.location,
        effectiveRange: nil
      ) as? NSColor,
      NSColor.clear
    )

    sentinel.cancel()
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(probe.cancelled)
    coordinator.clearInlineAttachmentDrawings(in: textView)
  }

  func testInlineAttachmentViewportLeavingCancelsImageTaskAndReenters() async throws {
    let fixtureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownInlineAttachmentViewportLeave-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 16,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: fixtureURL, options: .atomic)

    let source = "$$\nE = mc^2\n$$\n\n![cover](cover.png)\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    coordinator.attachments = [
      DraftAttachment(
        originalFilename: "cover.png",
        relativePublishPath: "cover.png",
        repositoryPath: "cover.png",
        sourceFilePath: fixtureURL.path
      )
    ]
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))

    let formulaRange = (source as NSString).range(of: "$$\nE = mc^2\n$$")
    let imageRange = (source as NSString).range(of: "![cover](cover.png)")
    let formulaOnlyRange = NSRange(
      location: formulaRange.location,
      length: formulaRange.length
    )
    let applicationRange = NSRange(location: 0, length: source.utf16.count)
    let imageKey = "attachment:\(imageRange.location)"

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange
    )
    let firstImageDrawing = try XCTUnwrap(
      coordinator.inlineAttachmentDrawingDescriptors[imageKey]
    )
    let firstFormulaDrawing = try XCTUnwrap(
      coordinator.inlineAttachmentDrawingDescriptors["attachment:\(formulaRange.location)"]
    )
    coordinator.inlineAttachmentImageTasks[imageKey]?.cancel()

    let probe = MarkdownInlineAttachmentTaskCancellationProbe()
    let sentinel: Task<Void, Never> = Task { @MainActor in
      probe.started = true
      while !Task.isCancelled {
        await Task.yield()
      }
      probe.cancelled = true
    }
    coordinator.inlineAttachmentImageTasks[imageKey] = sentinel
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(probe.started)

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: formulaOnlyRange
    )
    XCTAssertNotNil(
      coordinator.inlineAttachmentDrawingDescriptors["attachment:\(formulaRange.location)"]
    )
    XCTAssertNil(coordinator.inlineAttachmentDrawingDescriptors[imageKey])
    XCTAssertNil(coordinator.inlineAttachmentImageTasks[imageKey])
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(probe.cancelled)

    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange
    )
    let reenteredImageDrawing = try XCTUnwrap(
      coordinator.inlineAttachmentDrawingDescriptors[imageKey]
    )
    XCTAssertEqual(reenteredImageDrawing.content, firstImageDrawing.content)
    XCTAssertEqual(
      coordinator.inlineAttachmentDrawingDescriptors[
        "attachment:\(formulaRange.location)"
      ]?.content,
      firstFormulaDrawing.content
    )
    XCTAssertNotNil(coordinator.inlineAttachmentImageTasks[imageKey])
    coordinator.clearInlineAttachmentDrawings(in: textView)
  }

  func testParagraphHighlightSkipsUnchangedViewportAndRefreshesOnlyInvalidatedIntersection() throws
  {
    let source = "first paragraph\nsecond paragraph\n"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source
    textView.setSelectedRange(NSRange(location: 2, length: 0))

    XCTAssertTrue(
      coordinator.updateCurrentParagraphHighlight(in: textView, force: true)
    )
    XCTAssertNil(
      textView.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil)
    )
    let paragraphRange = (source as NSString).paragraphRange(
      for: NSRange(location: 2, length: 0)
    )
    let paragraphTextRange = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.textRange(for: paragraphRange, in: textView)
    )
    var hasBackgroundRenderingAttribute = false
    textView.textLayoutManager?.enumerateRenderingAttributes(
      from: paragraphTextRange.location,
      reverse: false
    ) { _, attributes, renderingRange in
      guard
        let fullRenderingRange = MarkdownTextKit2RangeAdapter.range(
          for: renderingRange,
          in: textView
        )
      else {
        return true
      }
      let intersection = NSIntersectionRange(fullRenderingRange, paragraphRange)
      if intersection.length > 0, attributes[.backgroundColor] != nil {
        hasBackgroundRenderingAttribute = true
        return false
      }
      return NSMaxRange(fullRenderingRange) < NSMaxRange(paragraphRange)
    }
    XCTAssertFalse(hasBackgroundRenderingAttribute)
    XCTAssertNotNil(textView.markdownParagraphHighlightRect)
    XCTAssertFalse(
      coordinator.updateCurrentParagraphHighlight(in: textView)
    )

    let secondParagraphRange = (source as NSString).range(of: "second paragraph")
    XCTAssertFalse(
      coordinator.updateCurrentParagraphHighlight(
        in: textView,
        invalidatedRanges: [secondParagraphRange]
      )
    )
    XCTAssertTrue(
      coordinator.updateCurrentParagraphHighlight(
        in: textView,
        invalidatedRanges: [NSRange(location: 2, length: 1)]
      )
    )
    XCTAssertTrue(
      coordinator.updateCurrentParagraphHighlight(in: textView, force: true)
    )
  }

  func testDiagnosticViewportDeltaRemovesLeavingRetainsOverlapAndAppliesEntering() {
    let source = "left middle right outside"
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: source,
      bodyUTF16Offset: 0
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = source

    let leftRange = (source as NSString).range(of: "left")
    let middleRange = (source as NSString).range(of: "middle")
    let rightRange = (source as NSString).range(of: "right")
    let outsideRange = (source as NSString).range(of: "outside")
    let leftDiagnostic = MarkdownInlineDiagnostic(
      id: "left",
      severity: .warning,
      title: "左侧诊断",
      message: "left",
      range: leftRange
    )
    let middleDiagnostic = MarkdownInlineDiagnostic(
      id: "middle",
      severity: .error,
      title: "重叠诊断",
      message: "middle",
      range: middleRange
    )
    let rightDiagnostic = MarkdownInlineDiagnostic(
      id: "right",
      severity: .warning,
      title: "进入诊断",
      message: "right",
      range: rightRange
    )
    let outsideDiagnostic = MarkdownInlineDiagnostic(
      id: "outside",
      severity: .error,
      title: "视口外诊断",
      message: "outside",
      range: outsideRange
    )
    coordinator.diagnostics = [
      leftDiagnostic,
      middleDiagnostic,
      rightDiagnostic,
      outsideDiagnostic,
    ]

    let firstApplicationRange = NSRange(
      location: 0,
      length: NSMaxRange(middleRange)
    )
    let firstMetrics = coordinator.updateDiagnosticOverlays(
      in: textView,
      applicationRange: firstApplicationRange,
      force: true
    )
    XCTAssertEqual(
      firstMetrics,
      MarkdownDiagnosticOverlayUpdateMetrics(removedCount: 0, appliedCount: 2)
    )
    XCTAssertEqual(
      coordinator.appliedDiagnosticOverlays,
      [
        MarkdownEditorDiagnosticOverlay(
          range: leftRange,
          severity: .warning
        ),
        MarkdownEditorDiagnosticOverlay(
          range: middleRange,
          severity: .error
        ),
      ]
    )

    XCTAssertEqual(
      coordinator.updateDiagnosticOverlays(
        in: textView,
        applicationRange: firstApplicationRange
      ),
      .unchanged
    )

    let secondApplicationRange = NSRange(
      location: middleRange.location,
      length: NSMaxRange(rightRange) - middleRange.location
    )
    let secondMetrics = coordinator.updateDiagnosticOverlays(
      in: textView,
      applicationRange: secondApplicationRange
    )
    XCTAssertEqual(
      secondMetrics,
      MarkdownDiagnosticOverlayUpdateMetrics(removedCount: 1, appliedCount: 1)
    )
    XCTAssertEqual(
      coordinator.appliedDiagnosticOverlays,
      [
        MarkdownEditorDiagnosticOverlay(
          range: middleRange,
          severity: .error
        ),
        MarkdownEditorDiagnosticOverlay(
          range: rightRange,
          severity: .warning
        ),
      ]
    )
    XCTAssertFalse(
      coordinator.appliedDiagnosticOverlays.contains {
        $0.range == outsideRange
      }
    )

    let fullRepaintMetrics = coordinator.updateDiagnosticOverlays(
      in: textView,
      applicationRange: secondApplicationRange,
      force: true
    )
    XCTAssertEqual(
      fullRepaintMetrics,
      MarkdownDiagnosticOverlayUpdateMetrics(removedCount: 2, appliedCount: 2)
    )
  }

  func testInlineAttachmentImageCacheDecodesIsolatedDemoFixture() async throws {
    let fixtureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownInlineAttachmentImageCache-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 16,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: fixtureURL, options: .atomic)

    let payload = await MarkdownInlineAttachmentImageCache.shared.image(
      at: fixtureURL,
      maximumPixelSize: 128
    )

    let image = try XCTUnwrap(payload?.image)
    XCTAssertGreaterThan(image.width, 0)
    XCTAssertGreaterThan(image.height, 0)
    XCTAssertLessThanOrEqual(max(image.width, image.height), 128)
  }

  func testInlineAttachmentImageCacheEvictsByDecodedByteBudget() async throws {
    let firstURL = try makeInlineAttachmentImageFixture(width: 32, height: 32)
    let secondURL = try makeInlineAttachmentImageFixture(width: 64, height: 32)
    defer {
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
    }

    let sizingCache = MarkdownInlineAttachmentImageCache(
      decodedByteBudget: 1 * 1_024 * 1_024
    )
    let firstPayload = await sizingCache.image(at: firstURL, maximumPixelSize: 128)
    let secondPayload = await sizingCache.image(at: secondURL, maximumPixelSize: 128)
    let first = try XCTUnwrap(firstPayload)
    let second = try XCTUnwrap(secondPayload)
    let budget = first.decodedByteCount + second.decodedByteCount - 1
    let cache = MarkdownInlineAttachmentImageCache(decodedByteBudget: budget)

    let firstResult = await cache.image(at: firstURL, maximumPixelSize: 128)
    let secondResult = await cache.image(at: secondURL, maximumPixelSize: 128)
    let containsFirst = await cache.containsCachedImage(at: firstURL)
    let containsSecond = await cache.containsCachedImage(at: secondURL)
    let cachedByteCount = await cache.cachedDecodedByteCount
    XCTAssertNotNil(firstResult)
    XCTAssertNotNil(secondResult)
    XCTAssertFalse(containsFirst)
    XCTAssertTrue(containsSecond)
    XCTAssertEqual(cachedByteCount, second.decodedByteCount)
  }

  func testInlineAttachmentImageCacheRefreshesLRUOnHit() async throws {
    let firstURL = try makeInlineAttachmentImageFixture(width: 48, height: 48)
    let secondURL = try makeInlineAttachmentImageFixture(width: 48, height: 48)
    let thirdURL = try makeInlineAttachmentImageFixture(width: 48, height: 48)
    defer {
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
      try? FileManager.default.removeItem(at: thirdURL)
    }

    let sizingCache = MarkdownInlineAttachmentImageCache(
      decodedByteBudget: 1 * 1_024 * 1_024
    )
    let firstPayload = await sizingCache.image(at: firstURL, maximumPixelSize: 128)
    let first = try XCTUnwrap(firstPayload)
    let cache = MarkdownInlineAttachmentImageCache(
      decodedByteBudget: first.decodedByteCount * 2,
      maximumEntryCount: 24
    )

    let firstResult = await cache.image(at: firstURL, maximumPixelSize: 128)
    let secondResult = await cache.image(at: secondURL, maximumPixelSize: 128)
    let firstHitResult = await cache.image(at: firstURL, maximumPixelSize: 128)
    let thirdResult = await cache.image(at: thirdURL, maximumPixelSize: 128)
    let containsFirst = await cache.containsCachedImage(at: firstURL)
    let containsSecond = await cache.containsCachedImage(at: secondURL)
    let containsThird = await cache.containsCachedImage(at: thirdURL)

    XCTAssertNotNil(firstResult)
    XCTAssertNotNil(secondResult)
    XCTAssertNotNil(firstHitResult)
    XCTAssertNotNil(thirdResult)
    XCTAssertTrue(containsFirst)
    XCTAssertFalse(containsSecond)
    XCTAssertTrue(containsThird)
  }

  func testInlineAttachmentImageCacheDoesNotRetainOversizedSingleItem() async throws {
    let fixtureURL = try makeInlineAttachmentImageFixture(width: 64, height: 64)
    defer { try? FileManager.default.removeItem(at: fixtureURL) }

    let sizingCache = MarkdownInlineAttachmentImageCache(
      decodedByteBudget: 1 * 1_024 * 1_024
    )
    let sizingPayload = await sizingCache.image(at: fixtureURL, maximumPixelSize: 128)
    let payload = try XCTUnwrap(sizingPayload)
    let cache = MarkdownInlineAttachmentImageCache(
      decodedByteBudget: max(1, payload.decodedByteCount - 1)
    )

    let returnedPayload = await cache.image(at: fixtureURL, maximumPixelSize: 128)
    let returned = try XCTUnwrap(returnedPayload)
    XCTAssertEqual(returned.decodedByteCount, payload.decodedByteCount)
    let count = await cache.count
    let cachedByteCount = await cache.cachedDecodedByteCount
    let containsFixture = await cache.containsCachedImage(at: fixtureURL)
    XCTAssertEqual(count, 0)
    XCTAssertEqual(cachedByteCount, 0)
    XCTAssertFalse(containsFixture)
  }

  private func makeInlineAttachmentImageFixture(width: Int, height: Int) throws -> URL {
    let fixtureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownInlineAttachmentImageCache-\(UUID().uuidString).png")
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: fixtureURL, options: .atomic)
    return fixtureURL
  }

}
