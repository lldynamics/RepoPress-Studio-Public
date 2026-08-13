import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class SiteMaintenanceRelationBenchmarkTests: XCTestCase {
  func testInvertedIndexKeepsCandidateWorkLinearAtFixedLabelDensity() throws {
    let groupSize = 8
    let small = try scan(articleCount: 256, labelGroupSize: groupSize)
    let large = try scan(articleCount: 1_024, labelGroupSize: groupSize)

    XCTAssertEqual(small.sourceDraftCount, 256)
    XCTAssertEqual(small.publishedTargetDraftCount, 256)
    XCTAssertEqual(small.indexedTargetDraftCount, 256)
    XCTAssertEqual(small.indexedLabelCount, 256 / groupSize)
    XCTAssertEqual(small.targetIndexEntryCount, 256)
    XCTAssertEqual(small.candidateEvaluationCount, 256 * (groupSize - 1))
    XCTAssertEqual(small.suggestionCount, small.candidateEvaluationCount)

    XCTAssertEqual(large.sourceDraftCount, 1_024)
    XCTAssertEqual(large.publishedTargetDraftCount, 1_024)
    XCTAssertEqual(large.indexedTargetDraftCount, 1_024)
    XCTAssertEqual(large.indexedLabelCount, 1_024 / groupSize)
    XCTAssertEqual(large.targetIndexEntryCount, 1_024)
    XCTAssertEqual(large.candidateEvaluationCount, 1_024 * (groupSize - 1))
    XCTAssertEqual(large.suggestionCount, large.candidateEvaluationCount)
    XCTAssertEqual(
      large.candidateEvaluationCount,
      small.candidateEvaluationCount * 4
    )
    XCTAssertLessThan(
      large.candidateEvaluationCount,
      large.sourceDraftCount * large.publishedTargetDraftCount / 100
    )
  }

  func testGeneratedRelationScanScaleBaseline() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_SITE_MAINTENANCE_RELATION_BENCHMARK"] == "1" else {
      if environment["PERFORMANCE_BENCHMARK_REQUIRED"] == "1" {
        throw SiteMaintenanceRelationBenchmarkError.requiredEnvironmentMissing(
          "RUN_SITE_MAINTENANCE_RELATION_BENCHMARK=1"
        )
      }
      throw XCTSkip(
        "Set RUN_SITE_MAINTENANCE_RELATION_BENCHMARK=1 to collect the relation scan baseline."
      )
    }

    let configuredSizes = (environment["SITE_MAINTENANCE_RELATION_BENCHMARK_SIZES"] ?? "")
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      .filter { $0 > 0 }
    let sizes = configuredSizes.isEmpty ? [512, 2_048, 4_096] : configuredSizes
    let iterations = max(
      1,
      Int(environment["SITE_MAINTENANCE_RELATION_BENCHMARK_ITERATIONS"] ?? "") ?? 5
    )
    let labelGroupSize = max(
      2,
      Int(environment["SITE_MAINTENANCE_RELATION_BENCHMARK_LABEL_GROUP_SIZE"] ?? "") ?? 8
    )
    let outputPath =
      environment["SITE_MAINTENANCE_RELATION_BENCHMARK_OUTPUT"]
      ?? ".build/benchmarks/site-maintenance-relations.json"

    let scenarios = try sizes.map {
      try benchmark(
        articleCount: $0,
        labelGroupSize: labelGroupSize,
        iterations: iterations
      )
    }
    let report = SiteMaintenanceRelationBenchmarkReport(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      configuration: environment["SITE_MAINTENANCE_RELATION_BENCHMARK_CONFIGURATION"] ?? "debug",
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
      labelGroupSize: labelGroupSize,
      scenarios: scenarios
    )
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
        "SITE_MAINTENANCE_RELATION_BENCHMARK"
          + " articles=\(scenario.articleCount)"
          + " labels=\(scenario.indexedLabelCount)"
          + " index_entries=\(scenario.targetIndexEntryCount)"
          + " candidates=\(scenario.candidateEvaluationCount)"
          + " full_pairs=\(scenario.fullPairCount)"
          + " suggestions=\(scenario.suggestionCount)"
          + " median_ms=\(Self.formatted(scenario.medianMilliseconds))"
          + " p95_ms=\(Self.formatted(scenario.p95Milliseconds))"
      )
    }
    print("SITE_MAINTENANCE_RELATION_BENCHMARK output=\(outputURL.path)")
  }

  private static func environmentValue(_ key: String, fallback: String) -> String {
    let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return value?.isEmpty == false ? value! : fallback
  }

  private func scan(
    articleCount: Int,
    labelGroupSize: Int
  ) throws -> SiteRelationScanMetrics {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let drafts = Self.makeDrafts(
      count: articleCount,
      labelGroupSize: labelGroupSize,
      profileID: profile.id
    )
    return SiteMaintenanceService().relationSuggestionScan(
      drafts: drafts,
      profile: profile
    ).metrics
  }

  private func benchmark(
    articleCount: Int,
    labelGroupSize: Int,
    iterations: Int
  ) throws -> SiteMaintenanceRelationBenchmarkScenario {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let drafts = Self.makeDrafts(
      count: articleCount,
      labelGroupSize: labelGroupSize,
      profileID: profile.id
    )
    let service = SiteMaintenanceService()
    _ = service.relationSuggestionScan(drafts: drafts, profile: profile)

    var samples: [Double] = []
    var metrics: SiteRelationScanMetrics?
    for _ in 0..<iterations {
      let start = ContinuousClock.now
      let result = service.relationSuggestionScan(drafts: drafts, profile: profile)
      samples.append(Self.milliseconds(since: start))
      metrics = result.metrics
    }

    let finalMetrics = try XCTUnwrap(metrics)
    let sortedSamples = samples.sorted()
    let p95Index = min(
      sortedSamples.count - 1,
      max(0, Int(ceil(Double(sortedSamples.count) * 0.95)) - 1)
    )
    return SiteMaintenanceRelationBenchmarkScenario(
      articleCount: articleCount,
      indexedLabelCount: finalMetrics.indexedLabelCount,
      targetIndexEntryCount: finalMetrics.targetIndexEntryCount,
      candidateEvaluationCount: finalMetrics.candidateEvaluationCount,
      fullPairCount: articleCount * max(0, articleCount - 1),
      suggestionCount: finalMetrics.suggestionCount,
      sampleCount: samples.count,
      rawSamplesMilliseconds: samples,
      minimumMilliseconds: sortedSamples.first ?? 0,
      medianMilliseconds: sortedSamples[sortedSamples.count / 2],
      p95Milliseconds: sortedSamples[p95Index],
      maximumMilliseconds: sortedSamples.last ?? 0
    )
  }

  private static func makeDrafts(
    count: Int,
    labelGroupSize: Int,
    profileID: UUID
  ) -> [ArticleDraft] {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return (0..<count).map { index in
      ArticleDraft(
        siteProfileID: profileID,
        title: "Scale article \(index)",
        date: date,
        slug: "scale-article-\(index)",
        tags: ["topic-\(index / labelGroupSize)"],
        categories: [],
        draft: false,
        bodyMarkdown: "Synthetic benchmark body without internal links.",
        status: .published,
        updatedAt: date
      )
    }
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

private struct SiteMaintenanceRelationBenchmarkReport: Encodable {
  let schemaVersion = 2
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
  let labelGroupSize: Int
  let scenarios: [SiteMaintenanceRelationBenchmarkScenario]
}

private struct SiteMaintenanceRelationBenchmarkScenario: Encodable {
  let articleCount: Int
  let indexedLabelCount: Int
  let targetIndexEntryCount: Int
  let candidateEvaluationCount: Int
  let fullPairCount: Int
  let suggestionCount: Int
  let sampleCount: Int
  let rawSamplesMilliseconds: [Double]
  let minimumMilliseconds: Double
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let maximumMilliseconds: Double
}

private enum SiteMaintenanceRelationBenchmarkError: LocalizedError {
  case requiredEnvironmentMissing(String)

  var errorDescription: String? {
    switch self {
    case .requiredEnvironmentMissing(let variable):
      return "Required release performance environment variable is missing: \(variable)."
    }
  }
}
