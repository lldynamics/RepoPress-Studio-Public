import AppKit
import Foundation
import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownViewportHighlightBenchmarkTests: XCTestCase {
  func testInlineAttachmentLayoutRejectsUnsafeExpansionAndClipsBlocks() throws {
    let container = NSRect(x: 0, y: 0, width: 96, height: 480)
    let safeBlock = try XCTUnwrap(MarkdownInlineAttachmentOverlayLayout.frame(
      sourceRect: NSRect(x: 20, y: 40, width: 200, height: 24),
      textViewBounds: container,
      horizontalInset: 26,
      mode: .block,
      preferredWidth: nil,
      preferredHeight: 164
    ))
    let unsafeInline = MarkdownInlineAttachmentOverlayLayout.frame(
      sourceRect: NSRect(x: 34, y: 40, width: 40, height: 20),
      textViewBounds: container,
      horizontalInset: 26,
      mode: .inline,
      preferredWidth: 72,
      preferredHeight: 30
    )

    XCTAssertLessThanOrEqual(safeBlock.maxX, container.maxX)
    XCTAssertLessThanOrEqual(safeBlock.width, container.width)
    XCTAssertNil(unsafeInline)
  }

  func testIncrementalViewportPipelineDocumentSizeIndependence() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_MARKDOWN_VIEWPORT_BENCHMARK"] == "1" else {
      throw XCTSkip(
        "Set RUN_MARKDOWN_VIEWPORT_BENCHMARK=1 to measure the TextKit 2 viewport pipeline."
      )
    }

    let iterations = max(
      1,
      Int(environment["MARKDOWN_VIEWPORT_BENCHMARK_ITERATIONS"] ?? "") ?? 20
    )
    var scenarios: [MarkdownViewportBenchmarkScenarioResult] = []
    for targetLength in [1_000, 100_000] {
      scenarios.append(
        try await measure(targetUTF16Length: targetLength, iterations: iterations)
      )
    }
    let small = try XCTUnwrap(scenarios.first)
    let large = try XCTUnwrap(scenarios.last)
    let ratio = large.total.medianMilliseconds
      / max(small.total.medianMilliseconds, 0.001)
    let rapidCoalesced = try await measureRapidCoalesced(
      targetUTF16Length: 100_000,
      iterations: iterations
    )
    let report = MarkdownViewportBenchmarkReport(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      configuration: environment["MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION"] ?? "debug",
      iterations: iterations,
      largeToSmallMedianRatio: ratio,
      scenarios: scenarios,
      rapidCoalesced: rapidCoalesced
    )

    XCTAssertLessThan(large.highlightedUTF16Length, large.documentUTF16Length)
    XCTAssertLessThanOrEqual(large.highlightedUTF16Length, 20_000)
    XCTAssertEqual(large.fallbackParseCount, 0)
    XCTAssertEqual(large.incrementalParseCountBeforeFirstIdle, 0)
    XCTAssertEqual(large.incrementalParseCount, 1)
    XCTAssertEqual(large.lightweightSnapshotCount, iterations)
    XCTAssertEqual(large.treeSynchronizationCount, 1)
    XCTAssertEqual(large.idleTreeSynchronization.rawSamplesMilliseconds.count, 1)
    XCTAssertGreaterThan(large.scrollingDelta.overlapUTF16Length, 0)
    XCTAssertLessThan(
      large.scrollingDelta.affectedUTF16Length,
      large.scrollingDelta.fullPaddedViewportUTF16Length
    )
    XCTAssertTrue(large.overlayReconciliation.reusedOverlayIdentity)
    XCTAssertEqual(large.overlayReconciliation.planComputationCountAfterWarmup, 1)
    XCTAssertEqual(large.overlayReconciliation.planComputationCountAfterReconciliation, 1)
    XCTAssertLessThan(
      large.overlayPostprocessing.deltaAppliedCount,
      large.overlayPostprocessing.fullAppliedCount
    )
    XCTAssertGreaterThan(large.overlayPostprocessing.deltaAppliedCount, 0)
    XCTAssertTrue(rapidCoalesced.hintUsed)
    XCTAssertEqual(rapidCoalesced.fallbackParseCount, 0)
    XCTAssertEqual(rapidCoalesced.coalescedEditCount, 10)
    XCTAssertEqual(rapidCoalesced.incrementalParseCountBeforeFirstIdle, 0)
    XCTAssertEqual(rapidCoalesced.incrementalParseCount, iterations)
    XCTAssertEqual(rapidCoalesced.lightweightSnapshotCount, iterations)
    XCTAssertEqual(rapidCoalesced.treeSynchronizationCount, iterations)
    XCTAssertEqual(rapidCoalesced.editHintParseCount, iterations)

    let outputPath = environment["MARKDOWN_VIEWPORT_BENCHMARK_OUTPUT"]
      ?? ".build/benchmarks/markdown-viewport-highlight-baseline.json"
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: outputURL, options: .atomic)

    for scenario in scenarios {
      print(
        "MARKDOWN_VIEWPORT_BENCHMARK"
          + " document_utf16=\(scenario.documentUTF16Length)"
          + " highlighted_utf16=\(scenario.highlightedUTF16Length)"
          + " lightweight_parse_median_ms=\(Self.formatted(scenario.parse.medianMilliseconds))"
          + " render_median_ms=\(Self.formatted(scenario.render.medianMilliseconds))"
          + " total_median_ms=\(Self.formatted(scenario.total.medianMilliseconds))"
          + " total_p95_ms=\(Self.formatted(scenario.total.p95Milliseconds))"
          + " idle_tree_sync_ms=\(Self.formatted(scenario.idleTreeSynchronization.medianMilliseconds))"
          + " scroll_delta_affected_utf16=\(scenario.scrollingDelta.affectedUTF16Length)"
          + " scroll_delta_full_padded_utf16=\(scenario.scrollingDelta.fullPaddedViewportUTF16Length)"
          + " scroll_delta_total_median_ms=\(Self.formatted(scenario.scrollingDelta.total.medianMilliseconds))"
          + " overlay_full_rebuild_median_ms=\(Self.formatted(scenario.overlayReconciliation.fullRebuild.medianMilliseconds))"
          + " overlay_reconcile_median_ms=\(Self.formatted(scenario.overlayReconciliation.reconcile.medianMilliseconds))"
          + " overlay_plan_count=\(scenario.overlayReconciliation.planComputationCountAfterReconciliation)"
          + " overlay_post_full_median_ms=\(Self.formatted(scenario.overlayPostprocessing.fullRefresh.medianMilliseconds))"
          + " overlay_post_delta_median_ms=\(Self.formatted(scenario.overlayPostprocessing.viewportDelta.medianMilliseconds))"
          + " overlay_post_full_applied=\(scenario.overlayPostprocessing.fullAppliedCount)"
          + " overlay_post_delta_applied=\(scenario.overlayPostprocessing.deltaAppliedCount)"
          + " incremental_before_idle=\(scenario.incrementalParseCountBeforeFirstIdle)"
      )
    }
    print(
      "MARKDOWN_VIEWPORT_RAPID_COALESCED"
        + " document_utf16=\(rapidCoalesced.documentUTF16Length)"
        + " highlighted_utf16=\(rapidCoalesced.highlightedUTF16Length)"
        + " edits=\(rapidCoalesced.coalescedEditCount)"
        + " hint_used=\(rapidCoalesced.hintUsed)"
        + " edit_hint_count=\(rapidCoalesced.editHintParseCount)"
        + " fallback_count=\(rapidCoalesced.fallbackParseCount)"
        + " lightweight_parse_median_ms=\(Self.formatted(rapidCoalesced.parse.medianMilliseconds))"
        + " parse_p95_ms=\(Self.formatted(rapidCoalesced.parse.p95Milliseconds))"
        + " idle_tree_sync_ms=\(Self.formatted(rapidCoalesced.idleTreeSynchronization.medianMilliseconds))"
        + " incremental_before_idle=\(rapidCoalesced.incrementalParseCountBeforeFirstIdle)"
    )
    print(
      "MARKDOWN_VIEWPORT_SIZE_RATIO"
        + " large_to_small_median=\(Self.formatted(ratio))"
        + " output=\(outputURL.path)"
    )
  }

  private func measure(
    targetUTF16Length: Int,
    iterations: Int
  ) async throws -> MarkdownViewportBenchmarkScenarioResult {
    let initialText = Self.document(targetUTF16Length: targetUTF16Length)
    let source = initialText as NSString
    let marker = source.range(
      of: "benchmark-token",
      options: [],
      range: NSRange(location: source.length / 2, length: source.length - source.length / 2)
    )
    guard marker.location != NSNotFound else {
      throw MarkdownViewportBenchmarkError.missingEditMarker
    }
    let editRange = NSRange(location: marker.location, length: 1)
    let parser = MarkdownSyntaxHighlightParser()
    let initialSnapshot = await parser.snapshot(
      in: initialText,
      revision: 0,
      mode: .synchronized
    )
    _ = try XCTUnwrap(initialSnapshot)
    let incrementalParseCountBeforeFirstIdle = (await parser.metrics()).incrementalParseCount

    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = initialText
    var currentText = initialText
    var currentRevision: UInt64 = 0
    var parseSamples: [Double] = []
    var renderSamples: [Double] = []
    var totalSamples: [Double] = []
    var accumulatedEdit: MarkdownSyntaxHighlightEditAccumulator?
    var highlightedUTF16Length = 0

    for iteration in 0..<iterations {
      let replacement = iteration.isMultiple(of: 2) ? "B" : "b"
      let previousText = currentText
      let previousRevision = currentRevision
      currentText = (currentText as NSString).replacingCharacters(
        in: editRange,
        with: replacement
      )
      currentRevision += 1
      let edit = MarkdownSyntaxHighlightEdit(
        previousText: previousText,
        replacedRange: editRange,
        previousRevision: previousRevision
      )
      if let existingEdit = accumulatedEdit {
        accumulatedEdit = try XCTUnwrap(
          existingEdit.accumulating(
            previousText: previousText,
            currentText: currentText,
            replacedRange: editRange,
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      } else {
        accumulatedEdit = try XCTUnwrap(
          MarkdownSyntaxHighlightEditAccumulator(
            previousText: previousText,
            currentText: currentText,
            replacedRange: editRange,
            previousRevision: previousRevision,
            currentRevision: currentRevision
          )
        )
      }
      textView.textStorage?.replaceCharacters(in: editRange, with: replacement)
      let visibleRange = (currentText as NSString).lineRange(for: editRange)
      let applicationRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
        in: currentText,
        visibleRange: visibleRange
      )
      highlightedUTF16Length = applicationRange.length

      let totalStart = ContinuousClock.now
      let parseStart = ContinuousClock.now
      let parsedSnapshot = await parser.snapshot(
        in: currentText,
        range: applicationRange,
        revision: currentRevision,
        edit: edit,
        mode: .lightweight
      )
      let snapshot = try XCTUnwrap(parsedSnapshot)
      parseSamples.append(Self.milliseconds(since: parseStart))

      let renderStart = ContinuousClock.now
      MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
        [.foregroundColor, .font],
        for: applicationRange,
        in: textView
      )
      _ = MarkdownTextKit2RangeAdapter.applySyntaxHighlighting(
        snapshot,
        defaultAttributes: [
          .foregroundColor: NSColor.labelColor,
          .font: NSFont.systemFont(ofSize: 14),
        ],
        styleAttributes: [
          .heading: [.foregroundColor: NSColor.systemBlue],
          .heading1: [.foregroundColor: NSColor.systemBlue],
          .heading2: [.foregroundColor: NSColor.systemBlue],
          .bold: [.font: NSFont.boldSystemFont(ofSize: 14)],
          .inlineCode: [.foregroundColor: NSColor.systemOrange],
          .codeBlock: [.foregroundColor: NSColor.systemOrange],
          .link: [.foregroundColor: NSColor.systemTeal],
        ],
        in: textView
      )
      renderSamples.append(Self.milliseconds(since: renderStart))
      totalSamples.append(Self.milliseconds(since: totalStart))
    }

    var idleTreeSynchronizationSamples: [Double] = []
    if let accumulatedEdit {
      let idleStart = ContinuousClock.now
      let didSynchronize = await parser.synchronizeTree(
        in: currentText,
        revision: currentRevision,
        edit: accumulatedEdit.parserEdit
      )
      XCTAssertTrue(didSynchronize)
      idleTreeSynchronizationSamples.append(Self.milliseconds(since: idleStart))
    }

    let metrics = await parser.metrics()
    return MarkdownViewportBenchmarkScenarioResult(
      documentUTF16Length: (currentText as NSString).length,
      highlightedUTF16Length: highlightedUTF16Length,
      incrementalParseCountBeforeFirstIdle: incrementalParseCountBeforeFirstIdle,
      incrementalParseCount: metrics.incrementalParseCount,
      fallbackParseCount: metrics.fallbackParseCount,
      lightweightSnapshotCount: metrics.lightweightSnapshotCount,
      treeSynchronizationCount: metrics.treeSynchronizationCount,
      parse: MarkdownViewportBenchmarkStatistics(samples: parseSamples),
      render: MarkdownViewportBenchmarkStatistics(samples: renderSamples),
      total: MarkdownViewportBenchmarkStatistics(samples: totalSamples),
      idleTreeSynchronization: MarkdownViewportBenchmarkStatistics(
        samples: idleTreeSynchronizationSamples
      ),
      scrollingDelta: try measureScrollingDelta(
        targetUTF16Length: targetUTF16Length,
        iterations: iterations
      ),
      overlayReconciliation: try measureOverlayReconciliation(
        targetUTF16Length: targetUTF16Length,
        iterations: iterations
      ),
      overlayPostprocessing: try measureOverlayPostprocessing(
        targetUTF16Length: targetUTF16Length,
        iterations: iterations
      )
    )
  }

  private func measureOverlayReconciliation(
    targetUTF16Length: Int,
    iterations: Int
  ) throws -> MarkdownViewportOverlayReconciliationBenchmarkResult {
    let baseText = Self.document(targetUTF16Length: targetUTF16Length)
    let baseSource = baseText as NSString
    let insertionLine = baseSource.lineRange(
      for: NSRange(location: baseSource.length / 2, length: 0)
    )
    let formula = "$$\nE = mc^2\n$$\n"
    let text = baseSource.replacingCharacters(
      in: NSRange(location: insertionLine.location, length: 0),
      with: formula
    )
    let source = text as NSString
    let formulaRange = source.range(of: "$$\nE = mc^2\n$$")
    let applicationRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: source.lineRange(for: formulaRange)
    )
    let coordinator = makeBenchmarkCoordinator(source: text)
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = text
    textView.setSelectedRange(NSRange(location: source.length, length: 0))

    coordinator.applyInlineAttachmentOverlays(
      in: textView,
      applicationRange: applicationRange
    )
    let key = "attachment:\(formulaRange.location)"
    let warmOverlay = try XCTUnwrap(coordinator.inlineAttachmentOverlayViews[key])
    let planComputationCountAfterWarmup = coordinator.inlineAttachmentPlanComputationCount

    var reconcileSamples: [Double] = []
    var reusedOverlayIdentity = true
    for _ in 0..<max(1, iterations) {
      let start = ContinuousClock.now
      coordinator.applyInlineAttachmentOverlays(
        in: textView,
        applicationRange: applicationRange,
        preservingExisting: true
      )
      reconcileSamples.append(Self.milliseconds(since: start))
      reusedOverlayIdentity = reusedOverlayIdentity
        && coordinator.inlineAttachmentOverlayViews[key] === warmOverlay
    }
    let planComputationCountAfterReconciliation =
      coordinator.inlineAttachmentPlanComputationCount

    var fullRebuildSamples: [Double] = []
    for _ in 0..<max(1, iterations) {
      coordinator.inlineAttachmentPlan = nil
      coordinator.inlineAttachmentPlanDocumentRevision = nil
      coordinator.inlineAttachmentPlanBodyUTF16Offset = nil
      let start = ContinuousClock.now
      coordinator.applyInlineAttachmentOverlays(
        in: textView,
        applicationRange: applicationRange
      )
      fullRebuildSamples.append(Self.milliseconds(since: start))
    }

    return MarkdownViewportOverlayReconciliationBenchmarkResult(
      documentUTF16Length: source.length,
      applicationUTF16Length: applicationRange.length,
      visibleOverlayCount: coordinator.inlineAttachmentOverlayViews.count,
      reusedOverlayIdentity: reusedOverlayIdentity,
      planComputationCountAfterWarmup: planComputationCountAfterWarmup,
      planComputationCountAfterReconciliation: planComputationCountAfterReconciliation,
      fullRebuild: MarkdownViewportBenchmarkStatistics(samples: fullRebuildSamples),
      reconcile: MarkdownViewportBenchmarkStatistics(samples: reconcileSamples)
    )
  }

  private func measureOverlayPostprocessing(
    targetUTF16Length: Int,
    iterations: Int
  ) throws -> MarkdownViewportOverlayPostprocessingBenchmarkResult {
    let text = Self.document(targetUTF16Length: targetUTF16Length)
    let source = text as NSString
    var diagnostics: [MarkdownInlineDiagnostic] = []
    var searchLocation = 0
    while searchLocation < source.length {
      let match = source.range(
        of: "benchmark-token",
        options: [],
        range: NSRange(
          location: searchLocation,
          length: source.length - searchLocation
        )
      )
      guard match.location != NSNotFound else { break }
      diagnostics.append(
        MarkdownInlineDiagnostic(
          id: "benchmark-\(match.location)",
          severity: .warning,
          title: "Benchmark",
          message: "Synthetic diagnostic",
          range: match
        )
      )
      searchLocation = NSMaxRange(match)
    }
    let coordinator = makeBenchmarkCoordinator(
      source: text,
      diagnostics: diagnostics
    )
    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = text
    let midpointIndex = diagnostics.count / 2
    let midpoint = diagnostics[midpointIndex].range.location
    textView.setSelectedRange(NSRange(location: midpoint, length: 0))
    let previousVisibleRange = source.lineRange(
      for: NSRange(location: midpoint, length: 0)
    )
    let currentVisibleRange = source.lineRange(
      for: NSRange(location: diagnostics[midpointIndex + 1].range.location, length: 0)
    )
    let previousRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: previousVisibleRange
    )
    let currentRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: currentVisibleRange
    )
    let fullRange = NSRange(location: 0, length: source.length)

    var fullSamples: [Double] = []
    var fullAppliedCount = 0
    for _ in 0..<max(1, iterations) {
      let start = ContinuousClock.now
      let metrics = coordinator.updateDiagnosticOverlays(
        in: textView,
        applicationRange: fullRange,
        force: true
      )
      fullSamples.append(Self.milliseconds(since: start))
      fullAppliedCount = metrics.appliedCount
    }

    _ = coordinator.updateDiagnosticOverlays(
      in: textView,
      applicationRange: previousRange,
      force: true
    )
    var deltaSamples: [Double] = []
    var deltaAppliedCount = 0
    var previousPaintedRange = previousRange
    for iteration in 0..<max(1, iterations) {
      let nextRange = iteration.isMultiple(of: 2) ? currentRange : previousRange
      let deltaPlan = MarkdownSyntaxViewportRenderPlan.make(
        previousPaintedRange: previousPaintedRange,
        currentSnapshot: MarkdownSyntaxHighlightSnapshot(range: nextRange, runs: []),
        requiresFullRepaint: false
      )
      let start = ContinuousClock.now
      let metrics = coordinator.updateDiagnosticOverlays(
        in: textView,
        applicationRange: nextRange,
        invalidatedRanges: deltaPlan.applicationSnapshots.map(\.range)
      )
      deltaSamples.append(Self.milliseconds(since: start))
      deltaAppliedCount = max(deltaAppliedCount, metrics.appliedCount)
      previousPaintedRange = nextRange
    }

    return MarkdownViewportOverlayPostprocessingBenchmarkResult(
      documentUTF16Length: source.length,
      diagnosticCount: diagnostics.count,
      fullAppliedCount: fullAppliedCount,
      deltaAppliedCount: deltaAppliedCount,
      fullRefresh: MarkdownViewportBenchmarkStatistics(samples: fullSamples),
      viewportDelta: MarkdownViewportBenchmarkStatistics(samples: deltaSamples)
    )
  }

  private func measureScrollingDelta(
    targetUTF16Length: Int,
    iterations: Int
  ) throws -> MarkdownViewportScrollingDeltaBenchmarkResult {
    let text = Self.document(targetUTF16Length: targetUTF16Length)
    let source = text as NSString
    let previousVisibleRange = source.lineRange(
      for: NSRange(location: source.length / 2, length: 0)
    )
    let currentVisibleLocation = NSMaxRange(previousVisibleRange)
    let currentVisibleRange = source.lineRange(
      for: NSRange(location: currentVisibleLocation, length: 0)
    )
    let contextLineCount = 3
    let previousPaddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: previousVisibleRange,
      contextLineCount: contextLineCount
    )
    let currentPaddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: currentVisibleRange,
      contextLineCount: contextLineCount
    )
    let overlapUTF16Length = NSIntersectionRange(
      previousPaddedRange,
      currentPaddedRange
    ).length
    guard previousPaddedRange.length > 0,
      currentPaddedRange.length > 0,
      overlapUTF16Length > 0,
      previousPaddedRange != currentPaddedRange
    else {
      throw MarkdownViewportBenchmarkError.invalidScrollingViewport
    }

    let currentSnapshot = MarkdownSyntaxHighlightSnapshot(
      range: currentPaddedRange,
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(
            location: currentPaddedRange.location,
            length: min(8, currentPaddedRange.length)
          )
        )
      ]
    )
    let expectedPlan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previousPaddedRange,
      currentSnapshot: currentSnapshot,
      requiresFullRepaint: false
    )
    XCTAssertLessThan(
      expectedPlan.affectedUTF16Length,
      currentPaddedRange.length
    )

    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = text
    var planSamples: [Double] = []
    var renderSamples: [Double] = []
    var totalSamples: [Double] = []
    let sampleCount = max(1, iterations)

    for _ in 0..<sampleCount {
      let totalStart = ContinuousClock.now
      let planStart = ContinuousClock.now
      let plan = MarkdownSyntaxViewportRenderPlan.make(
        previousPaintedRange: previousPaddedRange,
        currentSnapshot: currentSnapshot,
        requiresFullRepaint: false
      )
      planSamples.append(Self.milliseconds(since: planStart))

      let renderStart = ContinuousClock.now
      for removalRange in plan.removalRanges {
        MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
          [.foregroundColor, .font],
          for: removalRange,
          in: textView
        )
      }
      for applicationSnapshot in plan.applicationSnapshots {
        _ = MarkdownTextKit2RangeAdapter.applySyntaxHighlighting(
          applicationSnapshot,
          defaultAttributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 14),
          ],
          styleAttributes: [
            .heading: [.foregroundColor: NSColor.systemBlue],
          ],
          in: textView
        )
      }
      renderSamples.append(Self.milliseconds(since: renderStart))
      totalSamples.append(Self.milliseconds(since: totalStart))
    }

    return MarkdownViewportScrollingDeltaBenchmarkResult(
      previousPaddedViewportUTF16Length: previousPaddedRange.length,
      fullPaddedViewportUTF16Length: currentPaddedRange.length,
      overlapUTF16Length: overlapUTF16Length,
      affectedUTF16Length: expectedPlan.affectedUTF16Length,
      plan: MarkdownViewportBenchmarkStatistics(samples: planSamples),
      render: MarkdownViewportBenchmarkStatistics(samples: renderSamples),
      total: MarkdownViewportBenchmarkStatistics(samples: totalSamples)
    )
  }

  private func measureRapidCoalesced(
    targetUTF16Length: Int,
    iterations: Int
  ) async throws -> MarkdownViewportRapidCoalescedBenchmarkResult {
    let initialText = Self.document(targetUTF16Length: targetUTF16Length)
    let parser = MarkdownSyntaxHighlightParser()
    let initialSnapshot = await parser.snapshot(
      in: initialText,
      revision: 0,
      mode: .synchronized
    )
    _ = try XCTUnwrap(initialSnapshot)
    let incrementalParseCountBeforeFirstIdle = (await parser.metrics()).incrementalParseCount

    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.string = initialText
    let requestCount = 10
    var currentText = initialText
    var currentRevision: UInt64 = 0
    var parseSamples: [Double] = []
    var idleTreeSynchronizationSamples: [Double] = []
    var highlightedUTF16Length = 0

    for _ in 0..<iterations {
      let baseText = currentText
      let baseRevision = currentRevision
      let baseSource = baseText as NSString
      let marker = baseSource.range(
        of: "benchmark-token",
        options: [],
        range: NSRange(
          location: baseSource.length / 2,
          length: baseSource.length - baseSource.length / 2
        )
      )
      guard marker.location != NSNotFound else {
        throw MarkdownViewportBenchmarkError.missingEditMarker
      }

      var burstText = baseText
      var previousRevision = baseRevision
      var accumulatedEdit: MarkdownSyntaxHighlightEditAccumulator?
      let editRange = NSRange(location: marker.location, length: 1)
      for requestID in 0..<requestCount {
        let previousText = burstText
        let replacement = String(requestID % 10)
        let nextText = (previousText as NSString).replacingCharacters(
          in: editRange,
          with: replacement
        )
        let nextRevision = previousRevision + 1
        burstText = nextText

        if let existingEdit = accumulatedEdit {
          accumulatedEdit = try XCTUnwrap(
            existingEdit.accumulating(
              previousText: previousText,
              currentText: nextText,
              replacedRange: editRange,
              previousRevision: previousRevision,
              currentRevision: nextRevision
            )
          )
        } else {
          accumulatedEdit = try XCTUnwrap(
            MarkdownSyntaxHighlightEditAccumulator(
              previousText: previousText,
              currentText: nextText,
              replacedRange: editRange,
              previousRevision: previousRevision,
              currentRevision: nextRevision
            )
          )
        }
        textView.textStorage?.replaceCharacters(
          in: editRange,
          with: replacement
        )
        previousRevision = nextRevision
      }

      currentText = burstText
      currentRevision = previousRevision
      let visibleRange = (currentText as NSString).lineRange(for: editRange)
      let applicationRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
        in: currentText,
        visibleRange: visibleRange
      )
      highlightedUTF16Length = applicationRange.length

      let parseStart = ContinuousClock.now
      let parsedSnapshot = await parser.snapshot(
        in: currentText,
        range: applicationRange,
        revision: currentRevision,
        edit: accumulatedEdit?.parserEdit,
        mode: .lightweight
      )
      _ = try XCTUnwrap(parsedSnapshot)
      parseSamples.append(Self.milliseconds(since: parseStart))

      let idleStart = ContinuousClock.now
      let didSynchronize = await parser.synchronizeTree(
        in: currentText,
        revision: currentRevision,
        edit: accumulatedEdit?.parserEdit
      )
      XCTAssertTrue(didSynchronize)
      idleTreeSynchronizationSamples.append(Self.milliseconds(since: idleStart))
    }

    let metrics = await parser.metrics()
    return MarkdownViewportRapidCoalescedBenchmarkResult(
      documentUTF16Length: (currentText as NSString).length,
      highlightedUTF16Length: highlightedUTF16Length,
      coalescedEditCount: requestCount,
      incrementalParseCountBeforeFirstIdle: incrementalParseCountBeforeFirstIdle,
      incrementalParseCount: metrics.incrementalParseCount,
      editHintParseCount: metrics.editHintParseCount,
      fallbackParseCount: metrics.fallbackParseCount,
      lightweightSnapshotCount: metrics.lightweightSnapshotCount,
      treeSynchronizationCount: metrics.treeSynchronizationCount,
      hintUsed: metrics.editHintParseCount > 0,
      parse: MarkdownViewportBenchmarkStatistics(samples: parseSamples),
      idleTreeSynchronization: MarkdownViewportBenchmarkStatistics(
        samples: idleTreeSynchronizationSamples
      )
    )
  }

  private static func document(targetUTF16Length: Int) -> String {
    let block = """
      ## Generated section

      This benchmark-token paragraph contains **bold**, *italic*, `code`, and a [link](https://example.com).

      - First item
      - Second item
      > Quoted text for viewport measurement.

      ```swift
      let value = "synthetic"
      print(value)
      ```

      """
    var result = ""
    while result.utf16.count < targetUTF16Length {
      result += block
    }
    return result
  }

  private func makeBenchmarkCoordinator(
    source: String,
    diagnostics: [MarkdownInlineDiagnostic] = []
  ) -> MacMarkdownTextView.Coordinator {
    var text = source
    var selectedRange = NSRange(location: source.utf16.count, length: 0)
    var isFrontMatterSelection = false
    return MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: source,
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
      diagnostics: diagnostics,
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private static func formatted(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}

private struct MarkdownViewportBenchmarkReport: Encodable {
  let schemaVersion = 5
  let generatedAt: String
  let configuration: String
  let iterations: Int
  let largeToSmallMedianRatio: Double
  let scenarios: [MarkdownViewportBenchmarkScenarioResult]
  let rapidCoalesced: MarkdownViewportRapidCoalescedBenchmarkResult
}

private struct MarkdownViewportBenchmarkScenarioResult: Encodable {
  let documentUTF16Length: Int
  let highlightedUTF16Length: Int
  let incrementalParseCountBeforeFirstIdle: Int
  let incrementalParseCount: Int
  let fallbackParseCount: Int
  let lightweightSnapshotCount: Int
  let treeSynchronizationCount: Int
  let parse: MarkdownViewportBenchmarkStatistics
  let render: MarkdownViewportBenchmarkStatistics
  let total: MarkdownViewportBenchmarkStatistics
  let idleTreeSynchronization: MarkdownViewportBenchmarkStatistics
  let scrollingDelta: MarkdownViewportScrollingDeltaBenchmarkResult
  let overlayReconciliation: MarkdownViewportOverlayReconciliationBenchmarkResult
  let overlayPostprocessing: MarkdownViewportOverlayPostprocessingBenchmarkResult
}

private struct MarkdownViewportScrollingDeltaBenchmarkResult: Encodable {
  let previousPaddedViewportUTF16Length: Int
  let fullPaddedViewportUTF16Length: Int
  let overlapUTF16Length: Int
  let affectedUTF16Length: Int
  let plan: MarkdownViewportBenchmarkStatistics
  let render: MarkdownViewportBenchmarkStatistics
  let total: MarkdownViewportBenchmarkStatistics
}

private struct MarkdownViewportOverlayReconciliationBenchmarkResult: Encodable {
  let documentUTF16Length: Int
  let applicationUTF16Length: Int
  let visibleOverlayCount: Int
  let reusedOverlayIdentity: Bool
  let planComputationCountAfterWarmup: Int
  let planComputationCountAfterReconciliation: Int
  let fullRebuild: MarkdownViewportBenchmarkStatistics
  let reconcile: MarkdownViewportBenchmarkStatistics
}

private struct MarkdownViewportOverlayPostprocessingBenchmarkResult: Encodable {
  let documentUTF16Length: Int
  let diagnosticCount: Int
  let fullAppliedCount: Int
  let deltaAppliedCount: Int
  let fullRefresh: MarkdownViewportBenchmarkStatistics
  let viewportDelta: MarkdownViewportBenchmarkStatistics
}

private struct MarkdownViewportBenchmarkStatistics: Encodable {
  let rawSamplesMilliseconds: [Double]
  let medianMilliseconds: Double
  let p95Milliseconds: Double

  init(samples: [Double]) {
    let sorted = samples.sorted()
    rawSamplesMilliseconds = samples
    medianMilliseconds = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p95Index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    p95Milliseconds = sorted.isEmpty ? 0 : sorted[p95Index]
  }
}

private struct MarkdownViewportRapidCoalescedBenchmarkResult: Encodable {
  let documentUTF16Length: Int
  let highlightedUTF16Length: Int
  let coalescedEditCount: Int
  let incrementalParseCountBeforeFirstIdle: Int
  let incrementalParseCount: Int
  let editHintParseCount: Int
  let fallbackParseCount: Int
  let lightweightSnapshotCount: Int
  let treeSynchronizationCount: Int
  let hintUsed: Bool
  let parse: MarkdownViewportBenchmarkStatistics
  let idleTreeSynchronization: MarkdownViewportBenchmarkStatistics
}

private enum MarkdownViewportBenchmarkError: Error {
  case missingEditMarker
  case invalidScrollingViewport
}
