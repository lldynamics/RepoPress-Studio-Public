import Foundation
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

/// Opt-in end-to-end benchmark for the current SQLite-backed semantic search.
///
/// This test is deliberately skipped during the normal test inventory. The
/// shell wrapper supplies the opt-in environment and makes the resulting JSON
/// artifact reproducible enough for comparing cold snapshot construction and
/// hot flat-array retrieval with a future sqlite-vec implementation.
final class KnowledgeSemanticSearchBenchmarkTests: XCTestCase {
  func testSemanticSearchBaseline() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK"] == "1" else {
      if environment["PERFORMANCE_BENCHMARK_REQUIRED"] == "1" {
        throw KnowledgeSemanticSearchBenchmarkError.requiredEnvironmentMissing(
          "RUN_KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK=1"
        )
      }
      throw XCTSkip(
        "Run script/benchmark_knowledge_semantic_search.sh to collect this baseline."
      )
    }

    let iterations = try Self.positiveInteger(
      environment["KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_ITERATIONS"],
      default: 5,
      name: "iterations"
    )
    let sizes = try Self.parseSizes(
      environment["KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SIZES"] ?? "1000,10000,50000"
    )
    let configuration = Self.environmentValue(
      "KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_CONFIGURATION",
      fallback: "debug"
    )
    let report = try Self.run(
      sizes: sizes,
      iterations: iterations,
      configuration: configuration,
      scratchPath: environment["KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_SCRATCH_PATH"]
    )

    let outputPath = Self.environmentValue(
      "KNOWLEDGE_SEMANTIC_SEARCH_BENCHMARK_OUTPUT",
      fallback: ".build/benchmarks/knowledge-semantic-search.json"
    )
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: outputURL, options: .atomic)

    for scenario in report.scenarios {
      XCTAssertTrue(
        scenario.correctness.matchedExpectedChunk,
        "semantic search did not return the deterministic target for \(scenario.chunkCount) chunks"
      )
      XCTAssertEqual(
        scenario.correctness.actualTopChunkID,
        scenario.correctness.expectedChunkID,
        "top semantic result changed for \(scenario.chunkCount) chunks"
      )
      XCTAssertGreaterThanOrEqual(scenario.correctness.returnedCount, 1)
      print(
        "KNOWLEDGE_SEMANTIC_BENCHMARK"
          + " chunks=\(scenario.chunkCount)"
          + " dimension=\(scenario.dimension)"
          + " iterations=\(scenario.hotQuery.sampleCount)"
          + " setup_ms=\(Self.formatted(scenario.setupMilliseconds))"
          + " cold_median_ms=\(Self.formatted(scenario.coldQuery.medianMilliseconds))"
          + " cold_p95_ms=\(Self.formatted(scenario.coldQuery.p95Milliseconds))"
          + " hot_median_ms=\(Self.formatted(scenario.hotQuery.medianMilliseconds))"
          + " hot_p95_ms=\(Self.formatted(scenario.hotQuery.p95Milliseconds))"
      )
    }
    print("KNOWLEDGE_SEMANTIC_BENCHMARK output=\(outputURL.path)")
  }

  private static func run(
    sizes: [Int],
    iterations: Int,
    configuration: String,
    scratchPath: String?
  ) throws -> KnowledgeSemanticSearchBenchmarkReport {
    var scenarios: [KnowledgeSemanticSearchScenarioReport] = []
    for chunkCount in sizes {
      scenarios.append(
        try runScenario(
          chunkCount: chunkCount,
          iterations: iterations,
          scratchPath: scratchPath
        )
      )
    }

    return KnowledgeSemanticSearchBenchmarkReport(
      schemaVersion: 2,
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      benchmark: "knowledge-database-semantic-search",
      configuration: configuration,
      commit: environmentValue("PERFORMANCE_BENCHMARK_COMMIT", fallback: "unknown"),
      toolchain: environmentValue("PERFORMANCE_BENCHMARK_TOOLCHAIN", fallback: "unknown"),
      architecture: environmentValue(
        "PERFORMANCE_BENCHMARK_ARCHITECTURE",
        fallback: "unknown"
      ),
      operatingSystem: environmentValue(
        "PERFORMANCE_BENCHMARK_OPERATING_SYSTEM",
        fallback: ProcessInfo.processInfo.operatingSystemVersionString
      ),
      machine: environmentValue(
        "PERFORMANCE_BENCHMARK_MACHINE",
        fallback: "unknown"
      ),
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
      iterations: iterations,
      sampleCount: iterations,
      dimension: KnowledgeSemanticSearchFixture.dimension,
      modelIdentifier: KnowledgeSemanticSearchFixture.modelIdentifier,
      scenarios: scenarios
    )
  }

  private static func runScenario(
    chunkCount: Int,
    iterations: Int,
    scratchPath: String?
  ) throws -> KnowledgeSemanticSearchScenarioReport {
    let setupStart = ContinuousClock.now
    let fixture = try KnowledgeSemanticSearchFixture.make(
      chunkCount: chunkCount,
      scratchPath: scratchPath
    )
    let setupMilliseconds = milliseconds(since: setupStart)
    let fixtureRootURL = fixture.rootURL
    defer {
      // The fixture is isolated from the user's repository and shared .build;
      // SQLite files are removed after each scenario.
      do {
        try FileManager.default.removeItem(at: fixtureRootURL)
      } catch {
        print("KNOWLEDGE_SEMANTIC_BENCHMARK cleanup_warning=\(error.localizedDescription)")
      }
    }

    var coldSamples: [Double] = []
    var lastResults: [KnowledgeSearchResult] = []
    coldSamples.reserveCapacity(iterations)
    for _ in 0..<iterations {
      fixture.database.withLock {
        fixture.database.invalidateSemanticFlatVectorIndexesUnlocked()
      }
      let queryStart = ContinuousClock.now
      lastResults = try fixture.database.semanticSearch(
        queryVector: fixture.queryVector,
        limit: KnowledgeSemanticSearchFixture.resultLimit,
        onlyRemoteAIAllowed: false
      )
      coldSamples.append(milliseconds(since: queryStart))
      try Self.assertCorrectness(
        lastResults,
        expectedChunkID: fixture.expectedChunkID,
        chunkCount: chunkCount
      )
    }

    var hotSamples: [Double] = []
    hotSamples.reserveCapacity(iterations)
    for _ in 0..<iterations {
      let queryStart = ContinuousClock.now
      lastResults = try fixture.database.semanticSearch(
        queryVector: fixture.queryVector,
        limit: KnowledgeSemanticSearchFixture.resultLimit,
        onlyRemoteAIAllowed: false
      )
      hotSamples.append(milliseconds(since: queryStart))
      try Self.assertCorrectness(
        lastResults,
        expectedChunkID: fixture.expectedChunkID,
        chunkCount: chunkCount
      )
    }

    let topResult = try XCTUnwrap(lastResults.first)
    return KnowledgeSemanticSearchScenarioReport(
      chunkCount: chunkCount,
      dimension: KnowledgeSemanticSearchFixture.dimension,
      setupMilliseconds: setupMilliseconds,
      coldQuery: KnowledgeSemanticSearchBenchmarkStatistics(samples: coldSamples),
      hotQuery: KnowledgeSemanticSearchBenchmarkStatistics(samples: hotSamples),
      correctness: KnowledgeSemanticSearchCorrectnessReport(
        expectedChunkID: fixture.expectedChunkID.uuidString,
        actualTopChunkID: topResult.chunk.id.uuidString,
        returnedCount: lastResults.count,
        topScore: topResult.score,
        matchedExpectedChunk: topResult.chunk.id == fixture.expectedChunkID
      )
    )
  }

  private static func assertCorrectness(
    _ results: [KnowledgeSearchResult],
    expectedChunkID: UUID,
    chunkCount: Int
  ) throws {
    guard let first = results.first, first.chunk.id == expectedChunkID else {
      throw KnowledgeSemanticSearchBenchmarkError.semanticResultMismatch(
        chunkCount: chunkCount,
        expected: expectedChunkID.uuidString,
        actual: results.first?.chunk.id.uuidString ?? "none"
      )
    }
  }

  private static func parseSizes(_ rawValue: String) throws -> [Int] {
    let values = rawValue.split(separator: ",", omittingEmptySubsequences: false)
    guard !values.isEmpty else {
      throw KnowledgeSemanticSearchBenchmarkError.invalidConfiguration(
        "sizes must contain at least one positive integer"
      )
    }
    var sizes: [Int] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let size = Int(trimmed), size > 0 else {
        throw KnowledgeSemanticSearchBenchmarkError.invalidConfiguration(
          "sizes must contain positive integers: \(rawValue)"
        )
      }
      sizes.append(size)
    }
    return sizes
  }

  private static func positiveInteger(
    _ rawValue: String?,
    default defaultValue: Int,
    name: String
  ) throws -> Int {
    guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return defaultValue
    }
    guard let value = Int(rawValue), value > 0 else {
      throw KnowledgeSemanticSearchBenchmarkError.invalidConfiguration(
        "\(name) must be a positive integer: \(rawValue)"
      )
    }
    return value
  }

  private static func environmentValue(_ key: String, fallback: String) -> String {
    let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if let value, !value.isEmpty {
      return value
    }
    return fallback
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

private struct KnowledgeSemanticSearchBenchmarkReport: Codable {
  let schemaVersion: Int
  let generatedAt: String
  let benchmark: String
  let configuration: String
  let commit: String
  let toolchain: String
  let architecture: String
  let operatingSystem: String
  let machine: String
  let activeProcessorCount: Int
  let iterations: Int
  let sampleCount: Int
  let dimension: Int
  let modelIdentifier: String
  let scenarios: [KnowledgeSemanticSearchScenarioReport]
}

private struct KnowledgeSemanticSearchScenarioReport: Codable {
  let chunkCount: Int
  let dimension: Int
  let setupMilliseconds: Double
  let coldQuery: KnowledgeSemanticSearchBenchmarkStatistics
  let hotQuery: KnowledgeSemanticSearchBenchmarkStatistics
  let correctness: KnowledgeSemanticSearchCorrectnessReport
}

private struct KnowledgeSemanticSearchCorrectnessReport: Codable {
  let expectedChunkID: String
  let actualTopChunkID: String
  let returnedCount: Int
  let topScore: Double
  let matchedExpectedChunk: Bool
}

private struct KnowledgeSemanticSearchBenchmarkStatistics: Codable {
  let rawSamplesMilliseconds: [Double]
  let sampleCount: Int
  let minimumMilliseconds: Double
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let maximumMilliseconds: Double

  init(samples: [Double]) {
    precondition(!samples.isEmpty)
    let sorted = samples.sorted()
    rawSamplesMilliseconds = samples
    sampleCount = samples.count
    minimumMilliseconds = sorted[0]
    maximumMilliseconds = sorted[sorted.count - 1]
    medianMilliseconds = sorted[sorted.count / 2]
    let p95Index = min(
      sorted.count - 1,
      max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    )
    p95Milliseconds = sorted[p95Index]
  }
}

private final class KnowledgeSemanticSearchFixture {
  static let dimension = 384
  static let modelIdentifier = "benchmark-deterministic-384-v1"
  static let resultLimit = 10

  let database: KnowledgeDatabase
  let rootURL: URL
  let expectedChunkID: UUID
  let queryVector: KnowledgeSemanticVector

  private init(
    database: KnowledgeDatabase,
    rootURL: URL,
    expectedChunkID: UUID,
    queryVector: KnowledgeSemanticVector
  ) {
    self.database = database
    self.rootURL = rootURL
    self.expectedChunkID = expectedChunkID
    self.queryVector = queryVector
  }

  static func make(chunkCount: Int, scratchPath: String?) throws -> Self {
    let baseURL = scratchPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
    let rootURL = baseURL.appendingPathComponent(
      "knowledge-semantic-search-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("library.sqlite")
    )
    let documentID = stableUUID(namespace: 1, index: chunkCount)
    let revisionID = stableUUID(namespace: 2, index: chunkCount)
    try populate(
      database: database,
      documentID: documentID,
      revisionID: revisionID,
      chunkCount: chunkCount
    )
    let expectedChunkID = stableUUID(namespace: 3, index: 0)
    let queryVector = KnowledgeSemanticVector(
      modelIdentifier: modelIdentifier,
      values: vectorValues(for: 0),
      minimumSimilarity: -1
    )
    return Self(
      database: database,
      rootURL: rootURL,
      expectedChunkID: expectedChunkID,
      queryVector: queryVector
    )
  }

  private static func populate(
    database: KnowledgeDatabase,
    documentID: UUID,
    revisionID: UUID,
    chunkCount: Int
  ) throws {
    try database.withLock {
      try database.executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        let documentSQL = """
          INSERT INTO knowledge_documents (
            id, kind, title, authors_json, language, summary, tags_json,
            source_url, source_name, folder_id, source_byte_count,
            allows_ai_use, allows_local_semantic_index, is_archived,
            imported_at, updated_at, current_revision_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          """
        let revisionSQL = """
          INSERT INTO knowledge_revisions (
            id, document_id, original_hash, normalized_hash, parser_version,
            imported_at, source_modified_at, original_storage_ref,
            captured_text_storage_ref, normalized_storage_ref
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          """
        let chunkSQL = """
          INSERT INTO knowledge_chunks (
            id, document_id, revision_id, ordinal, heading_path, locator,
            content, token_estimate, content_hash
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
          """
        let embeddingSQL = """
          INSERT INTO knowledge_chunk_embeddings (
            chunk_id, revision_id, model_id, dimension, vector, created_at
          ) VALUES (?, ?, ?, ?, ?, ?);
          """

        let timestamp = 1_700_000_000.0
        try database.withCachedStatementUnlocked(documentSQL) { documentStatement in
          database.bind(documentID.uuidString, at: 1, to: documentStatement)
          database.bind("text", at: 2, to: documentStatement)
          database.bind("Semantic benchmark (\(chunkCount))", at: 3, to: documentStatement)
          database.bind("[]", at: 4, to: documentStatement)
          sqlite3_bind_null(documentStatement, 5)
          database.bind("Deterministic semantic search benchmark", at: 6, to: documentStatement)
          database.bind("[]", at: 7, to: documentStatement)
          sqlite3_bind_null(documentStatement, 8)
          database.bind("benchmark", at: 9, to: documentStatement)
          sqlite3_bind_null(documentStatement, 10)
          sqlite3_bind_int64(documentStatement, 11, 0)
          sqlite3_bind_int(documentStatement, 12, 0)
          sqlite3_bind_int(documentStatement, 13, 1)
          sqlite3_bind_int(documentStatement, 14, 0)
          sqlite3_bind_double(documentStatement, 15, timestamp)
          sqlite3_bind_double(documentStatement, 16, timestamp)
          database.bind(revisionID.uuidString, at: 17, to: documentStatement)
          try step(documentStatement, database: database)
        }

        try database.withCachedStatementUnlocked(revisionSQL) { revisionStatement in
          database.bind(revisionID.uuidString, at: 1, to: revisionStatement)
          database.bind(documentID.uuidString, at: 2, to: revisionStatement)
          database.bind("benchmark-original-\(chunkCount)", at: 3, to: revisionStatement)
          database.bind("benchmark-normalized-\(chunkCount)", at: 4, to: revisionStatement)
          sqlite3_bind_int(revisionStatement, 5, 1)
          sqlite3_bind_double(revisionStatement, 6, timestamp)
          sqlite3_bind_null(revisionStatement, 7)
          sqlite3_bind_null(revisionStatement, 8)
          sqlite3_bind_null(revisionStatement, 9)
          database.bind("benchmark/normalized", at: 10, to: revisionStatement)
          try step(revisionStatement, database: database)
        }

        try database.withCachedStatementUnlocked(chunkSQL) { chunkStatement in
          for index in 0..<chunkCount {
            let chunkID = stableUUID(namespace: 3, index: index)
            let content = "semantic benchmark chunk \(index)"
            sqlite3_reset(chunkStatement)
            sqlite3_clear_bindings(chunkStatement)
            database.bind(chunkID.uuidString, at: 1, to: chunkStatement)
            database.bind(documentID.uuidString, at: 2, to: chunkStatement)
            database.bind(revisionID.uuidString, at: 3, to: chunkStatement)
            sqlite3_bind_int64(chunkStatement, 4, sqlite3_int64(index))
            sqlite3_bind_null(chunkStatement, 5)
            database.bind("chunk-\(index)", at: 6, to: chunkStatement)
            database.bind(content, at: 7, to: chunkStatement)
            sqlite3_bind_int64(chunkStatement, 8, 4)
            database.bind("benchmark-content-\(index)", at: 9, to: chunkStatement)
            try step(chunkStatement, database: database)
          }
        }

        try database.withCachedStatementUnlocked(embeddingSQL) { embeddingStatement in
          for index in 0..<chunkCount {
            let chunkID = stableUUID(namespace: 3, index: index)
            let vector = vectorValues(for: index)
            sqlite3_reset(embeddingStatement)
            sqlite3_clear_bindings(embeddingStatement)
            database.bind(chunkID.uuidString, at: 1, to: embeddingStatement)
            database.bind(revisionID.uuidString, at: 2, to: embeddingStatement)
            database.bind(modelIdentifier, at: 3, to: embeddingStatement)
            sqlite3_bind_int64(
              embeddingStatement,
              4,
              sqlite3_int64(dimension)
            )
            database.bind(
              KnowledgeSemanticVectorStorage.vectorData(vector),
              at: 5,
              to: embeddingStatement
            )
            sqlite3_bind_double(embeddingStatement, 6, timestamp)
            try step(embeddingStatement, database: database)
          }
        }

        try database.executeUnlocked("COMMIT;")
      } catch {
        do {
          try database.executeUnlocked("ROLLBACK;")
        } catch {
          print("KNOWLEDGE_SEMANTIC_BENCHMARK rollback_warning=\(error.localizedDescription)")
        }
        throw error
      }
    }
  }

  private static func step(
    _ statement: OpaquePointer?,
    database: KnowledgeDatabase
  ) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw database.databaseError()
    }
  }

  private static func stableUUID(namespace: UInt8, index: Int) -> UUID {
    let value = UInt64(index)
    return UUID(uuid: (
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      namespace,
      UInt8((value >> 56) & 0xff),
      UInt8((value >> 48) & 0xff),
      UInt8((value >> 40) & 0xff),
      UInt8((value >> 32) & 0xff),
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff)
    ))
  }

  private static func vectorValues(for index: Int) -> [Float] {
    if index == 0 {
      var values = [Float](repeating: 0, count: dimension)
      values[0] = 1
      return values
    }

    var state = UInt64(index) &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    var values = [Float](repeating: 0, count: dimension)
    var squaredMagnitude = 0.0
    for offset in values.indices {
      state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
      let unit = Double(state >> 11) / 9_007_199_254_740_992.0
      let value = Float(unit * 2 - 1)
      values[offset] = value
      squaredMagnitude += Double(value) * Double(value)
    }
    let scale = Float(1.0 / sqrt(squaredMagnitude))
    for offset in values.indices {
      values[offset] *= scale
    }
    return values
  }
}

private enum KnowledgeSemanticSearchBenchmarkError: Error, CustomStringConvertible {
  case requiredEnvironmentMissing(String)
  case invalidConfiguration(String)
  case semanticResultMismatch(chunkCount: Int, expected: String, actual: String)

  var description: String {
    switch self {
    case .requiredEnvironmentMissing(let variable):
      return "Required benchmark environment is missing: \(variable)"
    case .invalidConfiguration(let message):
      return "Invalid semantic benchmark configuration: \(message)"
    case .semanticResultMismatch(let chunkCount, let expected, let actual):
      return "Semantic benchmark correctness failed for \(chunkCount) chunks: expected \(expected), got \(actual)"
    }
  }
}
