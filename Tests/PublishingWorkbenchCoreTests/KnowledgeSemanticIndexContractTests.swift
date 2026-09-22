import Foundation
import XCTest

@testable import PublishingKnowledgeCore

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

  func testFolderLabelWritesKeepWarmIndexWithoutHidingSecurityOrRevisionChanges() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("semantic-folder-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 本地检索\n\n中文技术资料的语义索引。".write(
      to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let database = try service.database()
    let record = try XCTUnwrap(database.semanticIndexRecords().first)
    let vector = try XCTUnwrap(
      service.semanticEmbeddingService.vector(
        for: record.searchableText,
        modelIdentifier: KnowledgeSemanticEmbeddingService.fallbackModelIdentifier,
        role: .query))
    try database.execute("UPDATE knowledge_documents SET allows_ai_use = 1;")
    let initial = try database.semanticSearch(
      queryVector: vector, limit: 5, onlyRemoteAIAllowed: true)
    XCTAssertFalse(initial.isEmpty)
    let buildCount = database.semanticFlatVectorIndexBuildCount
    let folder = try database.createFolder(name: "Research")
    _ = try database.renameFolder(id: folder.id, name: "Renamed")
    let afterRename = try database.semanticSearch(
      queryVector: vector, limit: 5, onlyRemoteAIAllowed: true)
    XCTAssertEqual(afterRename.map(\.chunk.id), initial.map(\.chunk.id))
    XCTAssertEqual(database.semanticFlatVectorIndexBuildCount, buildCount)

    // An unrelated label write must never bless a previously stale snapshot.
    let mutations = [
      "allows_ai_use = 0",
      "allows_local_semantic_index = 0",
      "is_archived = 1",
      "current_revision_id = 'obsolete-revision'",
    ]
    for (index, mutation) in mutations.enumerated() {
      try database.execute("UPDATE knowledge_documents SET \(mutation);")
      _ = try database.renameFolder(id: folder.id, name: "Folder \(index)")
      let results = try database.semanticSearch(
        queryVector: vector, limit: 5, onlyRemoteAIAllowed: true)
      XCTAssertTrue(results.isEmpty, mutation)
      try database.execute(
        "UPDATE knowledge_documents SET allows_ai_use = 1, allows_local_semantic_index = 1, "
          + "is_archived = 0, current_revision_id = '\(record.chunk.revisionID.uuidString)';")
      let restored = try database.semanticSearch(
        queryVector: vector, limit: 5, onlyRemoteAIAllowed: true)
      XCTAssertFalse(restored.isEmpty, mutation)
    }
    XCTAssertEqual(database.semanticFlatVectorIndexBuildCount, buildCount + mutations.count * 2)
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
