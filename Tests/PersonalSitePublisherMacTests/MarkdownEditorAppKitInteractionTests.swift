import AppKit
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorAppKitInteractionTests: XCTestCase {
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
    let initial = (0 ..< 200).map { index in
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

  func testParagraphHighlightSkipsUnchangedViewportAndRefreshesOnlyInvalidatedIntersection() throws {
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
      guard let fullRenderingRange = MarkdownTextKit2RangeAdapter.range(
        for: renderingRange,
        in: textView
      ) else {
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

  func testEquivalentAppKitSelectionDoesNotRepublishSwiftUIBindings() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: {
          selectionWriteCount += 1
          selectedRange = $0
        }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: {
          frontMatterWriteCount += 1
          isFrontMatterSelection = $0
        }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.setSelectedRange(selectedRange)

    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 0)
  }

  func testLiveEditsCoalesceBindingsButCallLiveBodyObserverImmediately() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: {
          selectionWriteCount += 1
          selectedRange = $0
        }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: {
          frontMatterWriteCount += 1
          isFrontMatterSelection = $0
        }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text

    for updatedText in ["正文一", "正文二"] {
      textView.string = updatedText
      coordinator.textDidChange(
        Notification(name: NSText.didChangeNotification, object: textView)
      )
    }
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(text, "正文")
    XCTAssertEqual(selectedRange, NSRange(location: 0, length: 0))
    XCTAssertEqual(textWriteCount, 0)
    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 0)
    XCTAssertEqual(
      liveBodyChanges.map { $0.0 },
      ["正文", "正文一"]
    )
    XCTAssertEqual(
      liveBodyChanges.map { $0.1 },
      ["正文一", "正文二"]
    )

    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "正文二")
    XCTAssertEqual(selectedRange, NSRange(location: 2, length: 0))
    XCTAssertEqual(textWriteCount, 1)
    XCTAssertEqual(selectionWriteCount, 1)
    XCTAssertEqual(frontMatterWriteCount, 0)
  }

  func testMarkedTextCompositionSkipsPairingAndStagesCommittedBodyWithoutStaleBindingEcho() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // This models an IME preedit. The delegate must not turn a marked "(" into
    // "()" while the input method is still composing.
    textView.setMarkedText(
      "n",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 1))
    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: textView.markedRange(),
        replacementString: "("
      )
    )
    XCTAssertEqual(textView.string, "n正文")
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(liveBodyChanges.last?.1, "n正文")
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    // Committing the preedit replaces only its marked range and clears the
    // marked state. textDidChange must publish this committed body immediately
    // to the live channel while the SwiftUI binding remains coalesced.
    textView.insertText("你", replacementRange: textView.markedRange())
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(liveBodyChanges.last?.1, "你正文")
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    coordinator.flushPendingBindingWrites()
    XCTAssertEqual(text, "你正文")
    XCTAssertEqual(textWriteCount, 1)
  }

  func testSimulatedIMEPreeditUpdatesReplacePreviousMarkedTextAndCommitSelection() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    var liveBodyChanges: [(String, String)] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onLiveBodyChange: { previous, updated in
        liveBodyChanges.append((previous, updated))
      },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // This is a deterministic NSTextInputClient lifecycle simulation. It
    // exercises NSTextView's public marked-text calls, but does not prove a
    // live keyboard/input-source session in the real editor window.
    // Starting with a punctuation preedit also proves that automatic pairing
    // is disabled before the first marked-text update reaches the coordinator.
    textView.setMarkedText(
      "(",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: selectedRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "(正文")
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 1))
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))

    // Updating a preedit replaces the prior marked range rather than inserting
    // a second copy into the document.
    textView.setMarkedText(
      "ni",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: textView.markedRange()
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(textView.markedRange(), NSRange(location: 0, length: 2))
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

    // Candidate submission is the NSTextInputClient commit path: insertText
    // replaces the marked range, clears composition state, and leaves the
    // caret after the committed candidate. AppKit synchronously delivers the
    // resulting textDidChange notification, so do not dispatch a duplicate.
    textView.insertText("你", replacementRange: textView.markedRange())

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(
      liveBodyChanges.map { $0.1 },
      ["(正文", "ni正文", "你正文"]
    )

    // A SwiftUI update carrying the old body/caret must not overwrite the
    // live committed NSTextView state before the trailing binding flush.
    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    XCTAssertFalse(
      coordinator.shouldApplyRepresentedSelection(
        selectedRange: NSRange(location: 0, length: 0),
        isFrontMatterSelection: false,
        in: textView
      )
    )
    XCTAssertEqual(textView.string, "你正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(selectedRange, NSRange(location: 0, length: 0))
    XCTAssertEqual(textWriteCount, 0)

    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "你正文")
    XCTAssertEqual(selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(textWriteCount, 1)
  }

  func testSimulatedIMECancelAndUnmarkPathsClearMarkedStateWithoutBindingEcho() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 640, height: 480)
    )
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    // Build a preedit, then exercise NSTextInputClient's unmarkText path.
    textView.setMarkedText(
      "ni",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: selectedRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")

    // AppKit synchronously delivers textDidChange while unmarking, so this
    // call exercises the real notification path without a duplicate dispatch.
    textView.unmarkText()

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)

    // A cancelled composition is represented by replacing the marked range
    // with an empty string. This is separate from unmarkText: cancellation
    // must restore the original body and caret, with no stale binding echo.
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    textView.setMarkedText(
      "hao",
      selectedRange: NSRange(location: 5, length: 0),
      replacementRange: NSRange(location: 2, length: 0)
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    XCTAssertTrue(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "nihao正文")

    let cancellationRange = textView.markedRange()
    textView.setMarkedText(
      "",
      // NSTextView interprets selectedRange relative to replacementRange for
      // an empty marked-text cancellation, so zero means the range's start.
      selectedRange: NSRange(location: 0, length: 0),
      replacementRange: cancellationRange
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "ni正文")
    XCTAssertEqual(
      textView.selectedRange(),
      NSRange(location: cancellationRange.location, length: 0)
    )
    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "ni正文")
    XCTAssertEqual(selectedRange, NSRange(location: cancellationRange.location, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(textWriteCount, 1)
  }

  func testFrontMatterSelectionBindingCoalescesUntilExplicitFlush() {
    var text = "---\n正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var selectionWriteCount = 0
    var frontMatterWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: "正文",
      bodyUTF16Offset: 4,
      selectedRange: Binding(
        get: { selectedRange },
        set: {
          selectionWriteCount += 1
          selectedRange = $0
        }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: {
          frontMatterWriteCount += 1
          isFrontMatterSelection = $0
        }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertFalse(isFrontMatterSelection)
    XCTAssertEqual(frontMatterWriteCount, 0)
    coordinator.flushPendingBindingWrites()

    XCTAssertTrue(isFrontMatterSelection)
    XCTAssertEqual(selectionWriteCount, 0)
    XCTAssertEqual(frontMatterWriteCount, 1)
  }

  func testEditorBindingAndStatisticsPublishOnSeparateIdleEdges() async throws {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var deliveredStatistics: [MarkdownEditorStatistics] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { deliveredStatistics.append($0) },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文一"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(text, "正文")
    XCTAssertTrue(deliveredStatistics.isEmpty)

    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(text, "正文一")
    XCTAssertTrue(deliveredStatistics.isEmpty)

    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(deliveredStatistics.last?.characterCount, 3)
  }

  func testStaleSwiftUIEchoDoesNotReplaceLiveTextButExternalTextCancelsPendingWrite() {
    var text = "正文"
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(get: { NSRange(location: 0, length: 0) }, set: { _ in }),
      isFrontMatterSelection: Binding(get: { false }, set: { _ in }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文*"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertFalse(coordinator.updateRepresentedText("正文"))
    XCTAssertFalse(coordinator.updateRepresentedText("正文*"))
    XCTAssertTrue(coordinator.updateRepresentedText("外部正文"))
    coordinator.flushPendingBindingWrites()

    XCTAssertEqual(text, "正文")
    XCTAssertEqual(textWriteCount, 0)
  }

  func testDismantleFlushesLastLiveTextBinding() {
    var text = "正文"
    var textWriteCount = 0
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: {
          textWriteCount += 1
          text = $0
        }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(get: { NSRange(location: 0, length: 0) }, set: { _ in }),
      isFrontMatterSelection: Binding(get: { false }, set: { _ in }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = "正文最后一个字"
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )
    let scrollView = NSScrollView()
    scrollView.documentView = textView

    MacMarkdownTextView.dismantleNSView(scrollView, coordinator: coordinator)

    XCTAssertEqual(text, "正文最后一个字")
    XCTAssertEqual(textWriteCount, 1)
  }

  func testAutomaticPairingUsesLiveTextViewUndoableInsertionPath() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)

    let shouldApplyDefaultInsertion = coordinator.textView(
      textView,
      shouldChangeTextIn: selectedRange,
      replacementString: "("
    )

    XCTAssertFalse(shouldApplyDefaultInsertion)
    XCTAssertEqual(textView.string, "()正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(
      coordinator.pendingSelectedRangeBindingValue,
      NSRange(location: 1, length: 0)
    )
    coordinator.flushPendingBindingWrites()
    XCTAssertEqual(selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(isFrontMatterSelection)
  }

  func testAutomaticPairingRegistersOneUndoStepAndRestoresOriginalSelection() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: true
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    textView.allowsUndo = true
    textView.string = text
    textView.delegate = coordinator
    textView.setSelectedRange(selectedRange)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = textView
    window.makeFirstResponder(textView)
    defer { window.orderOut(nil) }

    // Go through NSTextView's real insertion route so the delegate callback,
    // paired insertion, and AppKit undo registration are exercised together.
    textView.insertText("(", replacementRange: selectedRange)
    XCTAssertEqual(textView.string, "()正文")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertTrue(textView.undoManager?.canUndo == true)

    textView.undoManager?.undo()

    XCTAssertEqual(textView.string, "正文")
    XCTAssertEqual(textView.selectedRange(), selectedRange)
    XCTAssertFalse(textView.undoManager?.canUndo == true)
  }

  func testAutomaticPairingCanBeDisabled() {
    var text = "正文"
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: text,
      bodyUTF16Offset: 0,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(
        automaticPairingEnabled: false
      ),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let textView = NSTextView()
    textView.string = text
    textView.delegate = coordinator

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: selectedRange,
        replacementString: "("
      )
    )
    XCTAssertEqual(textView.string, "正文")
  }

  func testBodyEditKeepsExistingFrontMatterBoundary() {
    let source = "---\r\ntitle: Draft\r\n---\r\n\r\n正文"
    let sourceText = source as NSString
    let bodyRange = sourceText.range(of: "正文")
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: "正文",
      bodyUTF16Offset: bodyRange.location
    )
    let textView = NSTextView()
    textView.string = source
    textView.delegate = coordinator
    let editRange = NSRange(location: bodyRange.location, length: 1)

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: editRange,
        replacementString: "改"
      )
    )
    let updated = sourceText.replacingCharacters(in: editRange, with: "改")
    textView.string = updated
    textView.setSelectedRange(NSRange(location: editRange.location + 1, length: 0))
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(coordinator.bodyUTF16Offset, bodyRange.location)
    XCTAssertEqual(coordinator.bodyMarkdown, "改文")
    coordinator.invalidateHighlightedTextCache()
  }

  func testFrontMatterEditRecomputesBoundaryWithoutChangingBody() {
    let source = "---\ntitle: Old\n---\n\n正文"
    let sourceText = source as NSString
    let originalBodyRange = sourceText.range(of: "正文")
    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: "正文",
      bodyUTF16Offset: originalBodyRange.location
    )
    let textView = NSTextView()
    textView.string = source
    textView.delegate = coordinator
    let editRange = sourceText.range(of: "Old")
    let replacement = "A much longer title"

    XCTAssertTrue(
      coordinator.textView(
        textView,
        shouldChangeTextIn: editRange,
        replacementString: replacement
      )
    )
    let updated = sourceText.replacingCharacters(in: editRange, with: replacement)
    textView.string = updated
    textView.setSelectedRange(
      NSRange(location: editRange.location + (replacement as NSString).length, length: 0)
    )
    coordinator.textDidChange(
      Notification(name: NSText.didChangeNotification, object: textView)
    )

    XCTAssertEqual(
      coordinator.bodyUTF16Offset,
      (updated as NSString).range(of: "正文").location
    )
    XCTAssertEqual(coordinator.bodyMarkdown, "正文")
    coordinator.invalidateHighlightedTextCache()
  }

  func testDragAcceptsSupportedImagesAndDeliversOnlyFilteredFileURLs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
    textView.fileDropImageURLsProvider = { _ in
      ImageFileSupport.supportedImageURLs(in: [fixture.imageURL, fixture.textURL])
    }
    var targetedStates: [Bool] = []
    var droppedURLs: [URL] = []
    textView.fileDropTargetChangedHandler = { targetedStates.append($0) }
    textView.fileDropHandler = { urls, _ in droppedURLs = urls }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), .copy)
    XCTAssertTrue(textView.prepareForDragOperation(draggingInfo))
    XCTAssertTrue(textView.performDragOperation(draggingInfo))
    XCTAssertEqual(droppedURLs, [fixture.imageURL.standardizedFileURL])
    XCTAssertEqual(targetedStates, [true, false])
  }

  func testDragRejectsUnsupportedFilesWithoutCallingDropHandler() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    var didDrop = false
    textView.fileDropImageURLsProvider = { _ in [] }
    textView.fileDropHandler = { _, _ in didDrop = true }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), [])
    XCTAssertFalse(textView.prepareForDragOperation(draggingInfo))
    XCTAssertFalse(textView.performDragOperation(draggingInfo))
    XCTAssertFalse(didDrop)
  }

  func testKnowledgeDragCarriesCitationMetadataIntoDropHandler() throws {
    let citation = KnowledgeCitation(
      id: "drag-citation",
      documentID: UUID(),
      chunkID: UUID(),
      title: "本地资料",
      locator: "第二章",
      excerpt: "用于写作的资料片段"
    )
    let pasteboard = NSPasteboard.general

    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Draft"
    textView.knowledgeMarkdownProvider = { _ in "> 引用片段" }
    textView.knowledgeCitationProvider = { _ in citation }
    var receivedMarkdown: String?
    var receivedCitation: KnowledgeCitation?
    textView.knowledgeMarkdownDropHandler = { markdown, _, citation in
      receivedMarkdown = markdown
      receivedCitation = citation
    }
    let draggingInfo = MarkdownDraggingInfoStub(pasteboard: pasteboard)

    XCTAssertEqual(textView.draggingEntered(draggingInfo), .copy)
    XCTAssertTrue(textView.performDragOperation(draggingInfo))
    XCTAssertEqual(receivedMarkdown, "> 引用片段")
    XCTAssertEqual(receivedCitation, citation)
  }

  func testRichHTMLPasteboardKeepsTrustedWebBaseURL() {
    let pasteboard = TestMarkdownPasteboardSource(
      strings: [
        .html: "<p><strong>Hello</strong></p>",
        .URL: "https://example.com/articles/1",
      ]
    )

    let content = MarkdownPasteboardReader.richTextContent(from: pasteboard)

    XCTAssertEqual(content?.html, "<p><strong>Hello</strong></p>")
    XCTAssertEqual(content?.baseURL?.absoluteString, "https://example.com/articles/1")
  }

  private func makeCoordinator(
    source: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int
  ) -> MacMarkdownTextView.Coordinator {
    var text = source
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    return MacMarkdownTextView.Coordinator(
      text: Binding(
        get: { text },
        set: { text = $0 }
      ),
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
  }

  private func makeFixture() throws -> (root: URL, imageURL: URL, textURL: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MarkdownEditorAppKitInteractionTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let imageURL = root.appendingPathComponent("cover.png")
    let textURL = root.appendingPathComponent("notes.txt")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
    try Data("notes".utf8).write(to: textURL)
    return (root, imageURL, textURL)
  }

  private func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    characters: String = "",
    charactersIgnoringModifiers: String = "",
    isARepeat: Bool = false
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      isARepeat: isARepeat,
      keyCode: keyCode
    )
  }

  private func makeTextView() -> DroppableMarkdownTextView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
    )
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    return DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: textContainer
    )
  }
}

@MainActor
private final class MarkdownInlineAttachmentTaskCancellationProbe {
  var started = false
  var cancelled = false
}

struct TestMarkdownPasteboardSource: MarkdownPasteboardSource {
  let strings: [NSPasteboard.PasteboardType: String]
  let dataByType: [NSPasteboard.PasteboardType: Data]

  init(
    strings: [NSPasteboard.PasteboardType: String] = [:],
    data: [NSPasteboard.PasteboardType: Data] = [:]
  ) {
    self.strings = strings
    self.dataByType = data
  }

  func readObjects(
    forClasses classArray: [AnyClass],
    options: [NSPasteboard.ReadingOptionKey: Any]? = nil
  ) -> [Any]? {
    nil
  }

  func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
    dataByType[dataType]
  }

  func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
    strings[dataType]
  }

  var appKitPasteboard: NSPasteboard? { nil }
}

@MainActor
private final class MarkdownDraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = .copy
  var draggingLocation: NSPoint = .zero
  var draggedImageLocation: NSPoint = .zero
  var draggedImage: NSImage?
  var draggingSource: Any?
  var draggingSequenceNumber: Int = 1
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight = .none

  init(pasteboard: NSPasteboard) {
    draggingPasteboard = pasteboard
  }

  func slideDraggedImage(to screenPoint: NSPoint) {}

  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
    nil
  }

  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [],
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}

  func resetSpringLoading() {}
}
