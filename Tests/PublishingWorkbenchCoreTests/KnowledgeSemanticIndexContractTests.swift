import Foundation
import XCTest

@testable import PublishingKnowledgeCore
@testable import PublishingWorkbenchCore

final class KnowledgeSemanticIndexContractTests: XCTestCase {
  func testSemanticSearchExcludesWrongEncodingAndMissingInputHash() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("semantic-index-contract-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "# 本地检索\n\n中文技术资料的语义索引。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let database = try service.database()
    let record = try XCTUnwrap(database.semanticIndexRecords().first)
    let queryVector = try XCTUnwrap(
      service.semanticEmbeddingService.vector(
        for: record.searchableText,
        modelIdentifier: KnowledgeSemanticEmbeddingService.fallbackModelIdentifier,
        role: .query
      ))

    XCTAssertFalse(
      try database.semanticSearch(
        queryVector: queryVector,
        limit: 5,
        onlyRemoteAIAllowed: false
      ).isEmpty)

    try database.execute(
      "UPDATE knowledge_chunk_embeddings SET encoding_version = 'obsolete-contract';"
    )
    XCTAssertTrue(
      try database.semanticSearch(
        queryVector: queryVector,
        limit: 5,
        onlyRemoteAIAllowed: false
      ).isEmpty)

    try database.execute(
      "UPDATE knowledge_chunk_embeddings SET encoding_version = 'features-v2', input_hash = '';"
    )
    XCTAssertTrue(
      try database.semanticSearch(
        queryVector: queryVector,
        limit: 5,
        onlyRemoteAIAllowed: false
      ).isEmpty)
  }

  func testRepairScanPageAdvancesByRowsInspected() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("semantic-repair-page-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "# 分页\n\n需要稳定扫描的正文。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let database = try service.database()
    let first = try database.semanticIndexRepairScanPage(
      modelIdentifier: KnowledgeSemanticEmbeddingService.fallbackModelIdentifier,
      expectedDimension: 384,
      expectedEncodingVersion: "features-v2",
      offset: 0,
      maximumScannedRecords: 1
    )
    XCTAssertTrue(first.records.isEmpty)
    XCTAssertEqual(first.nextOffset, 1)

    let finished = try database.semanticIndexRepairScanPage(
      modelIdentifier: KnowledgeSemanticEmbeddingService.fallbackModelIdentifier,
      expectedDimension: 384,
      expectedEncodingVersion: "features-v2",
      offset: try XCTUnwrap(first.nextOffset),
      maximumScannedRecords: 1
    )
    XCTAssertTrue(finished.records.isEmpty)
    XCTAssertNil(finished.nextOffset)
  }
}
