import AppKit
import Foundation
import XCTest

@testable import PublishingMarkdownCore

@MainActor
final class MarkdownSyntaxHighlightBenchmarkTests: XCTestCase {
  func testGeneratedDocumentBaseline() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_MARKDOWN_SYNTAX_BENCHMARK"] == "1" else {
      if environment["PERFORMANCE_BENCHMARK_REQUIRED"] == "1" {
        throw MarkdownSyntaxBenchmarkError.requiredEnvironmentMissing(
          "RUN_MARKDOWN_SYNTAX_BENCHMARK=1"
        )
      }
      throw XCTSkip(
        "Run script/benchmark_markdown_syntax_highlighting.sh to collect this baseline.")
    }

    let iterations = max(
      1,
      Int(environment["MARKDOWN_SYNTAX_BENCHMARK_ITERATIONS"] ?? "") ?? 20
    )
    let outputPath =
      environment["MARKDOWN_SYNTAX_BENCHMARK_OUTPUT"]
      ?? ".build/benchmarks/markdown-syntax-baseline.json"
    let report = try await MarkdownSyntaxHighlightBenchmarkRunner.run(iterations: iterations)
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: outputURL, options: .atomic)

    for scenario in report.scenarios {
      print(
        "MARKDOWN_SYNTAX_BENCHMARK"
          + " scenario=\(scenario.id)"
          + " utf16=\(scenario.utf16Length)"
          + " runs=\(scenario.styleRunCount)"
          + " parse_median_ms=\(Self.formatted(scenario.parse.medianMilliseconds))"
          + " parse_p95_ms=\(Self.formatted(scenario.parse.p95Milliseconds))"
          + " apply_median_ms=\(Self.formatted(scenario.attributeApplication.medianMilliseconds))"
          + " apply_p95_ms=\(Self.formatted(scenario.attributeApplication.p95Milliseconds))"
      )
    }
    for scenario in report.incrementalScenarios {
      print(
        "MARKDOWN_SYNTAX_INCREMENTAL_BENCHMARK"
          + " scenario=\(scenario.id)"
          + " document_utf16=\(scenario.documentUTF16Length)"
          + " highlighted_utf16=\(scenario.highlightedUTF16Length)"
          + " runs=\(scenario.styleRunCount)"
          + " full_document=\(scenario.fullDocumentHighlight)"
          + " cache_reused=\(scenario.reusedCodeBlockCache)"
          + " scheduled_debounce_ms=\(Self.formatted(scenario.scheduledDebounceMilliseconds))"
          + " plan_median_ms=\(Self.formatted(scenario.planResolution.medianMilliseconds))"
          + " parse_median_ms=\(Self.formatted(scenario.parse.medianMilliseconds))"
          + " apply_median_ms=\(Self.formatted(scenario.attributeApplication.medianMilliseconds))"
          + " total_median_ms=\(Self.formatted(scenario.total.medianMilliseconds))"
          + " total_p95_ms=\(Self.formatted(scenario.total.p95Milliseconds))"
          + " estimated_completion_p95_ms=\(Self.formatted(scenario.estimatedCompletionP95Milliseconds))"
      )
    }
    print(
      "MARKDOWN_SYNTAX_RAPID_TYPING_BENCHMARK"
        + " requests=\(report.rapidTypingBurst.requestCount)"
        + " interval_ms=\(Self.formatted(report.rapidTypingBurst.intervalMilliseconds))"
        + " scheduled_debounce_ms=\(Self.formatted(report.rapidTypingBurst.scheduledDebounceMilliseconds))"
        + " computations_started=\(report.rapidTypingBurst.startedComputationCount)"
        + " results_delivered=\(report.rapidTypingBurst.deliveredResultCount)"
        + " coalesced=\(report.rapidTypingBurst.coalescedBeforeComputationCount)"
        + " latest_delivered=\(report.rapidTypingBurst.latestRequestDelivered)"
        + " delivered_runs=\(report.rapidTypingBurst.deliveredStyleRunCount)"
        + " total_p95_ms=\(Self.formatted(report.rapidTypingBurst.total.p95Milliseconds))"
    )
    print(
      "MARKDOWN_SYNTAX_CHUNKED_APPLICATION_BENCHMARK"
        + " document_utf16=\(report.chunkedDenseApplication.documentUTF16Length)"
        + " chunks=\(report.chunkedDenseApplication.chunkCount)"
        + " max_chunk_utf16=\(report.chunkedDenseApplication.maximumChunkUTF16Length)"
        + " first_chunk_utf16=\(report.chunkedDenseApplication.firstChunkUTF16Length)"
        + " preparation_p95_ms=\(Self.formatted(report.chunkedDenseApplication.preparation.p95Milliseconds))"
        + " per_chunk_p95_ms=\(Self.formatted(report.chunkedDenseApplication.perChunk.p95Milliseconds))"
        + " total_p95_ms=\(Self.formatted(report.chunkedDenseApplication.total.p95Milliseconds))"
        + " within_frame_budget=\(report.chunkedDenseApplication.perChunkP95WithinFrameBudget)"
    )
    print("MARKDOWN_SYNTAX_BENCHMARK output=\(outputURL.path)")
  }

  private static func formatted(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}

@MainActor
private enum MarkdownSyntaxHighlightBenchmarkRunner {
  static func run(iterations: Int) async throws -> MarkdownSyntaxBenchmarkReport {
    let environment = ProcessInfo.processInfo.environment
    let parser = MarkdownSyntaxHighlightParser()
    let palette = makePalette()
    var results: [MarkdownSyntaxBenchmarkScenarioResult] = []

    for scenario in scenarios {
      let markdown = MarkdownSyntaxBenchmarkDocumentFactory.make(
        targetUTF16Length: scenario.targetUTF16Length,
        density: scenario.density
      )
      guard let warmupSnapshot = await parser.snapshot(in: markdown) else {
        throw MarkdownSyntaxBenchmarkError.parserReturnedNoSnapshot(scenario.id)
      }
      let warmupFixture = MarkdownSyntaxBenchmarkTextKitFixture(markdown: markdown)
      warmupFixture.textStorage.beginEditing()
      _ = MarkdownSyntaxHighlightAttributeApplier.apply(
        warmupSnapshot,
        to: warmupFixture.textStorage,
        defaultAttributes: palette.defaultAttributes,
        styleAttributes: palette.styleAttributes
      )
      warmupFixture.textStorage.endEditing()

      var parseSamples: [Double] = []
      var applicationSamples: [Double] = []
      var styleRunCount = 0
      for _ in 0..<iterations {
        let parseStart = ContinuousClock.now
        guard let snapshot = await parser.snapshot(in: markdown) else {
          throw MarkdownSyntaxBenchmarkError.parserReturnedNoSnapshot(scenario.id)
        }
        parseSamples.append(milliseconds(since: parseStart))
        styleRunCount = snapshot.runs.count

        let fixture = MarkdownSyntaxBenchmarkTextKitFixture(markdown: markdown)
        let applicationStart = ContinuousClock.now
        fixture.textStorage.beginEditing()
        let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
          snapshot,
          to: fixture.textStorage,
          defaultAttributes: palette.defaultAttributes,
          styleAttributes: palette.styleAttributes
        )
        fixture.textStorage.endEditing()
        applicationSamples.append(milliseconds(since: applicationStart))
        guard appliedRunCount == snapshot.runs.count else {
          throw MarkdownSyntaxBenchmarkError.appliedRunCountMismatch(
            scenario: scenario.id,
            expected: snapshot.runs.count,
            actual: appliedRunCount
          )
        }
      }

      results.append(
        MarkdownSyntaxBenchmarkScenarioResult(
          id: scenario.id,
          density: scenario.density.rawValue,
          utf16Length: (markdown as NSString).length,
          styleRunCount: styleRunCount,
          parse: MarkdownSyntaxBenchmarkStatistics(samples: parseSamples),
          attributeApplication: MarkdownSyntaxBenchmarkStatistics(
            samples: applicationSamples
          )
        )
      )
    }

    let largeMixedMarkdown = MarkdownSyntaxBenchmarkDocumentFactory.make(
      targetUTF16Length: 100_000,
      density: .mixed
    )
    let resolvedInitialPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: largeMixedMarkdown,
      plan: .fullDocument(for: largeMixedMarkdown)
    )
    let incrementalScenarios = try MarkdownSyntaxBenchmarkDocumentFactory.incrementalScenarios(
      in: largeMixedMarkdown
    )
    var incrementalResults: [MarkdownSyntaxIncrementalBenchmarkScenarioResult] = []
    for scenario in incrementalScenarios {
      incrementalResults.append(
        try await runIncrementalScenario(
          scenario,
          knownCodeBlockRanges: resolvedInitialPlan.codeBlockRanges,
          parser: parser,
          palette: palette,
          iterations: iterations
        )
      )
    }
    let rapidTypingBurst = try await runRapidTypingBurstScenario(
      markdown: largeMixedMarkdown,
      parser: parser,
      iterations: iterations
    )
    let largeDenseMarkdown = MarkdownSyntaxBenchmarkDocumentFactory.make(
      targetUTF16Length: 100_000,
      density: .dense
    )
    let chunkedDenseApplication = try await runChunkedApplicationScenario(
      markdown: largeDenseMarkdown,
      parser: parser,
      palette: palette,
      iterations: iterations
    )

    return MarkdownSyntaxBenchmarkReport(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      configuration: environment["MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION"] ?? "debug",
      commit: Self.environmentValue("PERFORMANCE_BENCHMARK_COMMIT", fallback: "unknown"),
      toolchain: Self.environmentValue("PERFORMANCE_BENCHMARK_TOOLCHAIN", fallback: "unknown"),
      architecture: Self.environmentValue(
        "PERFORMANCE_BENCHMARK_ARCHITECTURE",
        fallback: "unknown"
      ),
      operatingSystem: Self.environmentValue(
        "PERFORMANCE_BENCHMARK_OPERATING_SYSTEM",
        fallback: ProcessInfo.processInfo.operatingSystemVersionString
      ),
      machine: Self.environmentValue("PERFORMANCE_BENCHMARK_MACHINE", fallback: "unknown"),
      sampleCount: iterations,
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
      iterations: iterations,
      scenarios: results,
      incrementalScenarios: incrementalResults,
      rapidTypingBurst: rapidTypingBurst,
      chunkedDenseApplication: chunkedDenseApplication
    )
  }

  private static func environmentValue(_ key: String, fallback: String) -> String {
    let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return value?.isEmpty == false ? value! : fallback
  }

  private static func runIncrementalScenario(
    _ scenario: MarkdownSyntaxIncrementalBenchmarkScenario,
    knownCodeBlockRanges: [NSRange]?,
    parser: MarkdownSyntaxHighlightParser,
    palette: MarkdownSyntaxBenchmarkPalette,
    iterations: Int
  ) async throws -> MarkdownSyntaxIncrementalBenchmarkScenarioResult {
    _ = try await incrementalMeasurement(
      scenario,
      knownCodeBlockRanges: knownCodeBlockRanges,
      parser: parser,
      palette: palette
    )

    var planningSamples: [Double] = []
    var parseSamples: [Double] = []
    var applicationSamples: [Double] = []
    var totalSamples: [Double] = []
    var lastMeasurement: MarkdownSyntaxIncrementalBenchmarkMeasurement?
    for _ in 0..<iterations {
      let measurement = try await incrementalMeasurement(
        scenario,
        knownCodeBlockRanges: knownCodeBlockRanges,
        parser: parser,
        palette: palette
      )
      planningSamples.append(measurement.planResolutionMilliseconds)
      parseSamples.append(measurement.parseMilliseconds)
      applicationSamples.append(measurement.attributeApplicationMilliseconds)
      totalSamples.append(measurement.totalMilliseconds)
      lastMeasurement = measurement
    }

    guard let lastMeasurement else {
      throw MarkdownSyntaxBenchmarkError.noIncrementalMeasurements(scenario.id)
    }
    let planResolution = MarkdownSyntaxBenchmarkStatistics(samples: planningSamples)
    let parse = MarkdownSyntaxBenchmarkStatistics(samples: parseSamples)
    let attributeApplication = MarkdownSyntaxBenchmarkStatistics(
      samples: applicationSamples
    )
    let total = MarkdownSyntaxBenchmarkStatistics(samples: totalSamples)
    return MarkdownSyntaxIncrementalBenchmarkScenarioResult(
      id: scenario.id,
      documentUTF16Length: (scenario.currentText as NSString).length,
      highlightedUTF16Length: lastMeasurement.highlightedUTF16Length,
      styleRunCount: lastMeasurement.styleRunCount,
      fullDocumentHighlight: lastMeasurement.fullDocumentHighlight,
      reusedCodeBlockCache: lastMeasurement.reusedCodeBlockCache,
      scheduledDebounceMilliseconds: lastMeasurement.scheduledDebounceMilliseconds,
      estimatedCompletionMedianMilliseconds:
        lastMeasurement.scheduledDebounceMilliseconds + total.medianMilliseconds,
      estimatedCompletionP95Milliseconds:
        lastMeasurement.scheduledDebounceMilliseconds + total.p95Milliseconds,
      planResolution: planResolution,
      parse: parse,
      attributeApplication: attributeApplication,
      total: total
    )
  }

  private static func incrementalMeasurement(
    _ scenario: MarkdownSyntaxIncrementalBenchmarkScenario,
    knownCodeBlockRanges: [NSRange]?,
    parser: MarkdownSyntaxHighlightParser,
    palette: MarkdownSyntaxBenchmarkPalette
  ) async throws -> MarkdownSyntaxIncrementalBenchmarkMeasurement {
    let fixture = MarkdownSyntaxBenchmarkTextKitFixture(markdown: scenario.currentText)
    let totalStart = ContinuousClock.now
    let planningStart = ContinuousClock.now
    let requestedPlan = MarkdownSyntaxHighlightRangeService.plan(
      accumulating: nil,
      previousText: scenario.previousText,
      currentText: scenario.currentText,
      replacedRange: scenario.replacedRange,
      knownCodeBlockRanges: knownCodeBlockRanges
    )
    let scheduledDebounceMilliseconds =
      MarkdownSyntaxHighlightSchedulingPolicy.delay(
        for: requestedPlan,
        documentUTF16Length: (scenario.currentText as NSString).length
      ) * 1_000
    let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: scenario.currentText,
      plan: requestedPlan
    )
    let planResolutionMilliseconds = milliseconds(since: planningStart)
    let fullyResolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
      in: scenario.currentText,
      plan: .fullDocument(for: scenario.currentText)
    )
    guard resolvedPlan.codeBlockRanges == fullyResolvedPlan.codeBlockRanges else {
      throw MarkdownSyntaxBenchmarkError.incorrectResolvedCodeBlockCache(scenario.id)
    }

    let parseStart = ContinuousClock.now
    guard
      let snapshot = await parser.snapshot(
        in: scenario.currentText,
        range: resolvedPlan.range
      )
    else {
      throw MarkdownSyntaxBenchmarkError.parserReturnedNoSnapshot(scenario.id)
    }
    let parseMilliseconds = milliseconds(since: parseStart)

    let applicationStart = ContinuousClock.now
    fixture.textStorage.beginEditing()
    let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: fixture.textStorage,
      defaultAttributes: palette.defaultAttributes,
      styleAttributes: palette.styleAttributes
    )
    fixture.textStorage.endEditing()
    let attributeApplicationMilliseconds = milliseconds(since: applicationStart)
    guard appliedRunCount == snapshot.runs.count else {
      throw MarkdownSyntaxBenchmarkError.appliedRunCountMismatch(
        scenario: scenario.id,
        expected: snapshot.runs.count,
        actual: appliedRunCount
      )
    }

    let fullRange = NSRange(
      location: 0,
      length: (scenario.currentText as NSString).length
    )
    let fullDocumentHighlight = resolvedPlan.range == fullRange
    let reusedCodeBlockCache = requestedPlan.codeBlockRanges != nil
    guard fullDocumentHighlight == scenario.expectedFullDocumentHighlight,
      reusedCodeBlockCache == scenario.expectedCodeBlockCacheReuse
    else {
      throw MarkdownSyntaxBenchmarkError.unexpectedIncrementalPlan(
        scenario: scenario.id,
        fullDocument: fullDocumentHighlight,
        cacheReused: reusedCodeBlockCache
      )
    }
    if let maximumFraction = scenario.maximumHighlightedDocumentFraction,
      Double(resolvedPlan.range.length) / Double(max(1, fullRange.length))
        >= maximumFraction
    {
      throw MarkdownSyntaxBenchmarkError.highlightedRangeTooLarge(
        scenario: scenario.id,
        highlightedUTF16Length: resolvedPlan.range.length,
        documentUTF16Length: fullRange.length,
        maximumFraction: maximumFraction
      )
    }
    guard abs(scheduledDebounceMilliseconds - scenario.expectedDebounceMilliseconds) < 0.001 else {
      throw MarkdownSyntaxBenchmarkError.unexpectedScheduledDebounce(
        scenario: scenario.id,
        expectedMilliseconds: scenario.expectedDebounceMilliseconds,
        actualMilliseconds: scheduledDebounceMilliseconds
      )
    }
    return MarkdownSyntaxIncrementalBenchmarkMeasurement(
      highlightedUTF16Length: resolvedPlan.range.length,
      styleRunCount: snapshot.runs.count,
      fullDocumentHighlight: fullDocumentHighlight,
      reusedCodeBlockCache: reusedCodeBlockCache,
      scheduledDebounceMilliseconds: scheduledDebounceMilliseconds,
      planResolutionMilliseconds: planResolutionMilliseconds,
      parseMilliseconds: parseMilliseconds,
      attributeApplicationMilliseconds: attributeApplicationMilliseconds,
      totalMilliseconds: milliseconds(since: totalStart)
    )
  }

  private static func runRapidTypingBurstScenario(
    markdown: String,
    parser: MarkdownSyntaxHighlightParser,
    iterations: Int
  ) async throws -> MarkdownSyntaxRapidTypingBurstBenchmarkResult {
    let requestCount = 10
    let intervalMilliseconds = 2.0
    let interval = intervalMilliseconds / 1_000
    var totalSamples: [Double] = []
    var lastMetrics = MarkdownSyntaxHighlightDebouncerMetrics(
      scheduledRequestCount: 0,
      startedComputationCount: 0,
      deliveredResultCount: 0
    )
    var lastStyleRunCount = 0
    var lastDocumentUTF16Length = (markdown as NSString).length

    for _ in 0..<iterations {
      let debouncer = MarkdownSyntaxHighlightDebouncer()
      let recorder = MarkdownSyntaxRapidTypingBurstRecorder()
      let totalStart = ContinuousClock.now

      for requestID in 0..<requestCount {
        let currentText = markdown + "\nRapid typing request **\(requestID)**"
        let source = currentText as NSString
        lastDocumentUTF16Length = source.length
        let requestedPlan = MarkdownSyntaxHighlightPlan(
          range: source.lineRange(
            for: NSRange(location: max(0, source.length - 1), length: 0)
          ),
          codeBlockRanges: []
        )
        let delay = MarkdownSyntaxHighlightSchedulingPolicy.delay(
          for: requestedPlan,
          documentUTF16Length: source.length
        )

        debouncer.schedule(
          delay: delay,
          operation: { () async -> MarkdownSyntaxRapidTypingBurstOutput? in
            guard
              let snapshot = await parser.snapshot(
                in: currentText,
                range: requestedPlan.range
              )
            else {
              return nil
            }
            return MarkdownSyntaxRapidTypingBurstOutput(
              requestID: requestID,
              styleRunCount: snapshot.runs.count
            )
          },
          onValue: { output in
            recorder.outputs.append(output)
          }
        )
        if requestID < requestCount - 1 {
          try? await Task.sleep(for: .seconds(interval))
        }
      }

      await debouncer.waitUntilIdle()
      totalSamples.append(milliseconds(since: totalStart))
      lastMetrics = debouncer.metrics
      lastStyleRunCount = recorder.outputs.last?.styleRunCount ?? 0
      let deliveredRequestIDs = recorder.outputs.map(\.requestID)
      guard lastMetrics.scheduledRequestCount == requestCount,
        lastMetrics.startedComputationCount == 1,
        lastMetrics.deliveredResultCount == 1,
        deliveredRequestIDs == [requestCount - 1]
      else {
        throw MarkdownSyntaxBenchmarkError.unexpectedRapidTypingBurst(
          scheduled: lastMetrics.scheduledRequestCount,
          started: lastMetrics.startedComputationCount,
          delivered: lastMetrics.deliveredResultCount,
          deliveredRequestIDs: deliveredRequestIDs
        )
      }
    }

    return MarkdownSyntaxRapidTypingBurstBenchmarkResult(
      documentUTF16Length: lastDocumentUTF16Length,
      requestCount: requestCount,
      intervalMilliseconds: intervalMilliseconds,
      scheduledDebounceMilliseconds:
        MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay * 1_000,
      startedComputationCount: lastMetrics.startedComputationCount,
      deliveredResultCount: lastMetrics.deliveredResultCount,
      coalescedBeforeComputationCount: lastMetrics.coalescedBeforeComputationCount,
      latestRequestDelivered: true,
      deliveredStyleRunCount: lastStyleRunCount,
      total: MarkdownSyntaxBenchmarkStatistics(samples: totalSamples)
    )
  }

  private static func runChunkedApplicationScenario(
    markdown: String,
    parser: MarkdownSyntaxHighlightParser,
    palette: MarkdownSyntaxBenchmarkPalette,
    iterations: Int
  ) async throws -> MarkdownSyntaxChunkedApplicationBenchmarkResult {
    guard let snapshot = await parser.snapshot(in: markdown) else {
      throw MarkdownSyntaxBenchmarkError.parserReturnedNoSnapshot(
        "large-dense-chunked-application"
      )
    }
    let priorityLength = min(4_096, snapshot.range.length)
    let priorityRange = NSRange(
      location: snapshot.range.location + max(0, (snapshot.range.length - priorityLength) / 2),
      length: priorityLength
    )
    let baselineApplicationSnapshots =
      MarkdownSyntaxHighlightApplicationPlanner
      .applicationSnapshots(
        for: snapshot,
        prioritizing: priorityRange
      )
    guard baselineApplicationSnapshots.first?.range == priorityRange,
      !baselineApplicationSnapshots.isEmpty
    else {
      throw MarkdownSyntaxBenchmarkError.invalidChunkedApplicationPlan
    }

    var preparationSamples: [Double] = []
    var perChunkSamples: [Double] = []
    var totalSamples: [Double] = []
    var appliedStyleSegmentCount = 0
    for _ in 0..<iterations {
      let preparationStart = ContinuousClock.now
      let applicationSnapshots =
        MarkdownSyntaxHighlightApplicationPlanner
        .applicationSnapshots(
          for: snapshot,
          prioritizing: priorityRange
        )
      preparationSamples.append(milliseconds(since: preparationStart))
      let fixture = MarkdownSyntaxBenchmarkTextKitFixture(markdown: markdown)
      let totalStart = ContinuousClock.now
      var iterationAppliedStyleSegmentCount = 0
      for applicationSnapshot in applicationSnapshots {
        let chunkStart = ContinuousClock.now
        fixture.textStorage.beginEditing()
        iterationAppliedStyleSegmentCount += MarkdownSyntaxHighlightAttributeApplier.apply(
          applicationSnapshot,
          to: fixture.textStorage,
          defaultAttributes: palette.defaultAttributes,
          styleAttributes: palette.styleAttributes
        )
        fixture.textStorage.endEditing()
        perChunkSamples.append(milliseconds(since: chunkStart))
      }
      totalSamples.append(milliseconds(since: totalStart))
      appliedStyleSegmentCount = iterationAppliedStyleSegmentCount
    }

    let frameBudgetMilliseconds = 1_000.0 / 60.0
    let perChunk = MarkdownSyntaxBenchmarkStatistics(samples: perChunkSamples)
    let perChunkP95WithinFrameBudget = perChunk.p95Milliseconds < frameBudgetMilliseconds
    if ProcessInfo.processInfo.environment["PERFORMANCE_BENCHMARK_ENFORCE_WALL_TIME"] == "1",
      !perChunkP95WithinFrameBudget
    {
      throw MarkdownSyntaxBenchmarkError.chunkedApplicationExceededFrameBudget(
        p95Milliseconds: perChunk.p95Milliseconds,
        frameBudgetMilliseconds: frameBudgetMilliseconds
      )
    }
    return MarkdownSyntaxChunkedApplicationBenchmarkResult(
      documentUTF16Length: (markdown as NSString).length,
      styleRunCount: snapshot.runs.count,
      appliedStyleSegmentCount: appliedStyleSegmentCount,
      chunkCount: baselineApplicationSnapshots.count,
      maximumChunkUTF16Length:
        MarkdownSyntaxHighlightApplicationPlanner.defaultMaximumChunkUTF16Length,
      prioritizedUTF16Length: priorityRange.length,
      firstChunkUTF16Length: baselineApplicationSnapshots[0].range.length,
      frameBudgetMilliseconds: frameBudgetMilliseconds,
      perChunkP95WithinFrameBudget: perChunkP95WithinFrameBudget,
      preparation: MarkdownSyntaxBenchmarkStatistics(samples: preparationSamples),
      perChunk: perChunk,
      total: MarkdownSyntaxBenchmarkStatistics(samples: totalSamples)
    )
  }

  private static let scenarios = [
    MarkdownSyntaxBenchmarkScenario(id: "short-mixed", targetUTF16Length: 2_000, density: .mixed),
    MarkdownSyntaxBenchmarkScenario(id: "medium-mixed", targetUTF16Length: 20_000, density: .mixed),
    MarkdownSyntaxBenchmarkScenario(id: "large-mixed", targetUTF16Length: 100_000, density: .mixed),
    MarkdownSyntaxBenchmarkScenario(id: "large-dense", targetUTF16Length: 100_000, density: .dense),
  ]

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private static func makePalette() -> MarkdownSyntaxBenchmarkPalette {
    let baseFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    let emphasizedFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 4
    return MarkdownSyntaxBenchmarkPalette(
      defaultAttributes: [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
      ],
      styleAttributes: [
        .heading: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading1: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading2: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading3: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading4: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading5: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .heading6: [.font: emphasizedFont, .foregroundColor: NSColor.systemBlue],
        .codeBlock: [.font: baseFont, .backgroundColor: NSColor.windowBackgroundColor],
        .link: [.foregroundColor: NSColor.linkColor, .underlineStyle: 1],
        .list: [.foregroundColor: NSColor.systemGreen],
        .quote: [.foregroundColor: NSColor.secondaryLabelColor],
        .bold: [.font: emphasizedFont],
        .italic: [.obliqueness: 0.15],
        .inlineCode: [.font: baseFont, .foregroundColor: NSColor.systemOrange],
        .html: [.font: baseFont, .foregroundColor: NSColor.systemPurple],
        .strikethrough: [.strikethroughStyle: NSUnderlineStyle.single.rawValue],
      ]
    )
  }
}

private struct MarkdownSyntaxBenchmarkReport: Encodable {
  let schemaVersion = 6
  let generatedAt: String
  let configuration: String
  let commit: String
  let toolchain: String
  let architecture: String
  let operatingSystem: String
  let machine: String
  let sampleCount: Int
  let activeProcessorCount: Int
  let iterations: Int
  let localEditDebounceMilliseconds =
    MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay * 1_000
  let expensiveEditDebounceMilliseconds =
    MarkdownSyntaxHighlightSchedulingPolicy.expensiveEditDelay * 1_000
  let maximumLocalEditUTF16Length =
    MarkdownSyntaxHighlightSchedulingPolicy.maximumLocalEditUTF16Length
  let incrementalMeasurementBoundary =
    "post-edit highlighting compute excludes debounce; each scenario reports its scheduled adaptive debounce separately"
  let scenarios: [MarkdownSyntaxBenchmarkScenarioResult]
  let incrementalScenarios: [MarkdownSyntaxIncrementalBenchmarkScenarioResult]
  let rapidTypingBurst: MarkdownSyntaxRapidTypingBurstBenchmarkResult
  let chunkedDenseApplication: MarkdownSyntaxChunkedApplicationBenchmarkResult
}

private struct MarkdownSyntaxBenchmarkScenarioResult: Encodable {
  let id: String
  let density: String
  let utf16Length: Int
  let styleRunCount: Int
  let parse: MarkdownSyntaxBenchmarkStatistics
  let attributeApplication: MarkdownSyntaxBenchmarkStatistics
}

private struct MarkdownSyntaxIncrementalBenchmarkScenarioResult: Encodable {
  let id: String
  let documentUTF16Length: Int
  let highlightedUTF16Length: Int
  let styleRunCount: Int
  let fullDocumentHighlight: Bool
  let reusedCodeBlockCache: Bool
  let scheduledDebounceMilliseconds: Double
  let estimatedCompletionMedianMilliseconds: Double
  let estimatedCompletionP95Milliseconds: Double
  let planResolution: MarkdownSyntaxBenchmarkStatistics
  let parse: MarkdownSyntaxBenchmarkStatistics
  let attributeApplication: MarkdownSyntaxBenchmarkStatistics
  let total: MarkdownSyntaxBenchmarkStatistics
}

private struct MarkdownSyntaxIncrementalBenchmarkMeasurement {
  let highlightedUTF16Length: Int
  let styleRunCount: Int
  let fullDocumentHighlight: Bool
  let reusedCodeBlockCache: Bool
  let scheduledDebounceMilliseconds: Double
  let planResolutionMilliseconds: Double
  let parseMilliseconds: Double
  let attributeApplicationMilliseconds: Double
  let totalMilliseconds: Double
}

private struct MarkdownSyntaxRapidTypingBurstBenchmarkResult: Encodable {
  let documentUTF16Length: Int
  let requestCount: Int
  let intervalMilliseconds: Double
  let scheduledDebounceMilliseconds: Double
  let startedComputationCount: Int
  let deliveredResultCount: Int
  let coalescedBeforeComputationCount: Int
  let latestRequestDelivered: Bool
  let deliveredStyleRunCount: Int
  let total: MarkdownSyntaxBenchmarkStatistics
}

private struct MarkdownSyntaxChunkedApplicationBenchmarkResult: Encodable {
  let documentUTF16Length: Int
  let styleRunCount: Int
  let appliedStyleSegmentCount: Int
  let chunkCount: Int
  let maximumChunkUTF16Length: Int
  let prioritizedUTF16Length: Int
  let firstChunkUTF16Length: Int
  let frameBudgetMilliseconds: Double
  let perChunkP95WithinFrameBudget: Bool
  let preparation: MarkdownSyntaxBenchmarkStatistics
  let perChunk: MarkdownSyntaxBenchmarkStatistics
  let total: MarkdownSyntaxBenchmarkStatistics
}

private struct MarkdownSyntaxRapidTypingBurstOutput: Sendable {
  let requestID: Int
  let styleRunCount: Int
}

@MainActor
private final class MarkdownSyntaxRapidTypingBurstRecorder {
  var outputs: [MarkdownSyntaxRapidTypingBurstOutput] = []
}

private struct MarkdownSyntaxBenchmarkStatistics: Encodable {
  let sampleCount: Int
  let rawSamplesMilliseconds: [Double]
  let minimumMilliseconds: Double
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let maximumMilliseconds: Double

  init(samples: [Double]) {
    let sorted = samples.sorted()
    sampleCount = samples.count
    rawSamplesMilliseconds = samples
    minimumMilliseconds = sorted.first ?? 0
    maximumMilliseconds = sorted.last ?? 0
    if sorted.isEmpty {
      medianMilliseconds = 0
      p95Milliseconds = 0
    } else {
      medianMilliseconds = sorted[sorted.count / 2]
      let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
      p95Milliseconds = sorted[p95Index]
    }
  }
}

private struct MarkdownSyntaxBenchmarkScenario {
  let id: String
  let targetUTF16Length: Int
  let density: MarkdownSyntaxBenchmarkDensity
}

private struct MarkdownSyntaxIncrementalBenchmarkScenario {
  let id: String
  let previousText: String
  let currentText: String
  let replacedRange: NSRange
  let expectedFullDocumentHighlight: Bool
  let expectedCodeBlockCacheReuse: Bool
  let expectedDebounceMilliseconds: Double
  let maximumHighlightedDocumentFraction: Double?
}

private enum MarkdownSyntaxBenchmarkDensity: String {
  case mixed
  case dense
}

private struct MarkdownSyntaxBenchmarkPalette {
  let defaultAttributes: [NSAttributedString.Key: Any]
  let styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
}

@MainActor
private final class MarkdownSyntaxBenchmarkTextKitFixture {
  let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager
  private let textContainer: NSTextContainer

  init(markdown: String) {
    textStorage = NSTextStorage(string: markdown)
    layoutManager = NSLayoutManager()
    textContainer = NSTextContainer(
      containerSize: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    )
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
  }
}

private enum MarkdownSyntaxBenchmarkDocumentFactory {
  static func make(
    targetUTF16Length: Int,
    density: MarkdownSyntaxBenchmarkDensity
  ) -> String {
    let block: String
    switch density {
    case .mixed:
      block = mixedBlock
    case .dense:
      block = denseBlock
    }

    var chunks: [String] = []
    var length = 0
    while length < targetUTF16Length {
      chunks.append(block)
      length += block.utf16.count
    }
    return chunks.joined()
  }

  static func incrementalScenarios(
    in markdown: String
  ) throws -> [MarkdownSyntaxIncrementalBenchmarkScenario] {
    let source = markdown as NSString
    let searchStart = source.length / 2
    let paragraphMarker = try markerRange(
      "This paragraph contains",
      in: source,
      startingAt: searchStart
    )
    let typingRange = NSRange(location: NSMaxRange(paragraphMarker), length: 0)
    let paragraphLineRange = source.lineRange(for: paragraphMarker)
    let pasteRange = NSRange(location: NSMaxRange(paragraphLineRange), length: 0)
    let fenceMarker = try markerRange(
      "```swift",
      in: source,
      startingAt: searchStart
    )
    let fenceLanguageRange = NSRange(
      location: fenceMarker.location + 3,
      length: 5
    )
    let fenceOpeningLine = source.lineRange(for: fenceMarker)
    let fenceClosingMarker = try markerRange(
      "```",
      in: source,
      startingAt: NSMaxRange(fenceOpeningLine)
    )

    return [
      MarkdownSyntaxIncrementalBenchmarkScenario(
        id: "single-character-typing",
        previousText: markdown,
        currentText: source.replacingCharacters(in: typingRange, with: "x"),
        replacedRange: typingRange,
        expectedFullDocumentHighlight: false,
        expectedCodeBlockCacheReuse: true,
        expectedDebounceMilliseconds:
          MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay * 1_000,
        maximumHighlightedDocumentFraction: nil
      ),
      MarkdownSyntaxIncrementalBenchmarkScenario(
        id: "paragraph-paste",
        previousText: markdown,
        currentText: source.replacingCharacters(
          in: pasteRange,
          with:
            "Pasted paragraph with **bold**, *italic*, `code`, and a [link](https://example.com/paste).\n\n"
        ),
        replacedRange: pasteRange,
        expectedFullDocumentHighlight: false,
        expectedCodeBlockCacheReuse: true,
        expectedDebounceMilliseconds:
          MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay * 1_000,
        maximumHighlightedDocumentFraction: nil
      ),
      MarkdownSyntaxIncrementalBenchmarkScenario(
        id: "code-fence-info-edit",
        previousText: markdown,
        currentText: source.replacingCharacters(
          in: fenceLanguageRange,
          with: "markdown"
        ),
        replacedRange: fenceLanguageRange,
        expectedFullDocumentHighlight: false,
        expectedCodeBlockCacheReuse: true,
        expectedDebounceMilliseconds:
          MarkdownSyntaxHighlightSchedulingPolicy.localEditDelay * 1_000,
        maximumHighlightedDocumentFraction: nil
      ),
      MarkdownSyntaxIncrementalBenchmarkScenario(
        id: "code-fence-marker-structure-edit",
        previousText: markdown,
        currentText: source.replacingCharacters(
          in: fenceClosingMarker,
          with: "````"
        ),
        replacedRange: fenceClosingMarker,
        expectedFullDocumentHighlight: false,
        expectedCodeBlockCacheReuse: true,
        expectedDebounceMilliseconds:
          MarkdownSyntaxHighlightSchedulingPolicy.expensiveEditDelay * 1_000,
        maximumHighlightedDocumentFraction: 0.25
      ),
    ]
  }

  private static func markerRange(
    _ marker: String,
    in source: NSString,
    startingAt location: Int
  ) throws -> NSRange {
    let searchStart = min(max(0, location), source.length)
    let searchRange = NSRange(
      location: searchStart,
      length: source.length - searchStart
    )
    let range = source.range(of: marker, options: [], range: searchRange)
    guard range.location != NSNotFound else {
      throw MarkdownSyntaxBenchmarkError.missingEditMarker(marker)
    }
    return range
  }

  private static let mixedBlock = """
    ## Generated section

    This paragraph contains **bold text**, *italic text*, `inline code`, and a [link](https://example.com/docs).

    - First generated item
    - Second generated item
    > A generated quotation used only for repeatable performance measurement.

    ```swift
    let value = "synthetic"
    print(value)
    ```

    """

  private static let denseBlock = """
    ### **Dense heading** with [reference](https://example.com/dense)
    - **bold** *italic* `code` [one](https://example.com/1) [two](https://example.com/2)
    > **quoted** *content* with `token` and [link](https://example.com/3)
    **alpha** *beta* `gamma` [delta](https://example.com/4) **epsilon** *zeta*

    """
}

private enum MarkdownSyntaxBenchmarkError: LocalizedError {
  case requiredEnvironmentMissing(String)
  case parserReturnedNoSnapshot(String)
  case appliedRunCountMismatch(scenario: String, expected: Int, actual: Int)
  case missingEditMarker(String)
  case noIncrementalMeasurements(String)
  case unexpectedIncrementalPlan(scenario: String, fullDocument: Bool, cacheReused: Bool)
  case incorrectResolvedCodeBlockCache(String)
  case highlightedRangeTooLarge(
    scenario: String,
    highlightedUTF16Length: Int,
    documentUTF16Length: Int,
    maximumFraction: Double
  )
  case unexpectedScheduledDebounce(
    scenario: String,
    expectedMilliseconds: Double,
    actualMilliseconds: Double
  )
  case unexpectedRapidTypingBurst(
    scheduled: Int,
    started: Int,
    delivered: Int,
    deliveredRequestIDs: [Int]
  )
  case invalidChunkedApplicationPlan
  case chunkedApplicationExceededFrameBudget(
    p95Milliseconds: Double,
    frameBudgetMilliseconds: Double
  )

  var errorDescription: String? {
    switch self {
    case .requiredEnvironmentMissing(let variable):
      return "Required release performance environment variable is missing: \(variable)."
    case .parserReturnedNoSnapshot(let scenario):
      return "Parser returned no snapshot for benchmark scenario \(scenario)."
    case .appliedRunCountMismatch(let scenario, let expected, let actual):
      return "Attribute application mismatch for \(scenario): expected \(expected), got \(actual)."
    case .missingEditMarker(let marker):
      return "Incremental benchmark marker was not found: \(marker)."
    case .noIncrementalMeasurements(let scenario):
      return "No incremental measurements were collected for \(scenario)."
    case .unexpectedIncrementalPlan(let scenario, let fullDocument, let cacheReused):
      return
        "Unexpected incremental plan for \(scenario): fullDocument=\(fullDocument), cacheReused=\(cacheReused)."
    case .incorrectResolvedCodeBlockCache(let scenario):
      return "Resolved code-block cache does not match a full scan for \(scenario)."
    case .highlightedRangeTooLarge(
      let scenario,
      let highlightedUTF16Length,
      let documentUTF16Length,
      let maximumFraction
    ):
      return
        "Highlighted range is too large for \(scenario): \(highlightedUTF16Length)/\(documentUTF16Length) UTF-16 units, maximum fraction \(maximumFraction)."
    case .unexpectedScheduledDebounce(let scenario, let expected, let actual):
      return
        "Unexpected scheduled debounce for \(scenario): expected \(expected) ms, got \(actual) ms."
    case .unexpectedRapidTypingBurst(
      let scheduled, let started, let delivered, let deliveredRequestIDs):
      return
        "Unexpected rapid typing burst: scheduled=\(scheduled), started=\(started), delivered=\(delivered), requestIDs=\(deliveredRequestIDs)."
    case .invalidChunkedApplicationPlan:
      return "Chunked application plan did not prioritize the requested visible range."
    case .chunkedApplicationExceededFrameBudget(let p95, let frameBudget):
      return
        "Chunked attribute application exceeded the frame budget: p95=\(p95) ms, budget=\(frameBudget) ms."
    }
  }
}
