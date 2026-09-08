import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAgentKnowledgeServiceTests: XCTestCase {
  func testSearchOnlyReturnsRemoteAllowedDocumentsAndExposesSafeSourceURL() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let allowedID = try await commit(
      title: "允许远程检索",
      text: "共享资料中的关键词和正文。",
      sourceURL: URL(string: "https://example.com/allowed"),
      allowsRemoteAIUse: true,
      library: library
    )
    _ = try await commit(
      title: "禁止远程检索",
      text: "共享资料中的关键词和私有正文。",
      sourceURL: URL(string: "https://example.com/private"),
      allowsRemoteAIUse: false,
      library: library
    )

    let results = try await WorkbenchAgentKnowledgeService(library: library).search(
      query: "共享资料",
      limit: 10
    )

    XCTAssertFalse(results.isEmpty)
    XCTAssertTrue(results.allSatisfy { $0.documentID == allowedID })
    XCTAssertTrue(results.allSatisfy { $0.sourceURL?.scheme == "https" })
    XCTAssertTrue(
      results.allSatisfy {
        $0.signals.allSatisfy { ["title", "fullText", "semantic"].contains($0) }
      })
  }

  func testSearchTrimsAndBoundsQueryAndClampsLimit() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    for index in 0..<12 {
      _ = try await commit(
        title: "边界资料 \(index)",
        text: "边界查询词 \(index) 可检索。",
        allowsRemoteAIUse: true,
        library: library
      )
    }
    let service = WorkbenchAgentKnowledgeService(library: library)
    let minimum = try await service.search(
      query: "\n  边界查询词  \n",
      limit: Int.min
    )
    XCTAssertEqual(minimum.count, 1)

    let maximum = try await service.search(
      query: String(repeating: "边界查询词 ", count: 300),
      limit: Int.max
    )
    XCTAssertLessThanOrEqual(maximum.count, WorkbenchAgentKnowledgeService.maximumSearchLimit)
    XCTAssertTrue(
      maximum.allSatisfy { $0.title.count <= WorkbenchAgentKnowledgeService.maximumTitleLength })
    XCTAssertTrue(
      maximum.allSatisfy { $0.excerpt.count <= WorkbenchAgentKnowledgeService.maximumExcerptLength }
    )
    var total = 0
    for hit in maximum {
      total += hit.documentID.uuidString.count
      total += hit.chunkID.uuidString.count
      total += hit.title.count
      total += hit.locator?.count ?? 0
      total += hit.excerpt.count
      for signal in hit.signals {
        total += signal.count
      }
      total += hit.sourceURL?.absoluteString.count ?? 0
    }
    XCTAssertLessThanOrEqual(total, WorkbenchAgentKnowledgeService.maximumSearchOutputCharacters)
  }

  func testSearchAndReadIDsAreStableAndReadIsBounded() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commit(
      title: "稳定资料",
      text: String(repeating: "稳定正文 ", count: 6_000),
      allowsRemoteAIUse: true,
      library: library
    )
    let service = WorkbenchAgentKnowledgeService(library: library)

    let first = try await service.search(query: "稳定正文", limit: 10)
    let second = try await service.search(query: "稳定正文", limit: 10)
    XCTAssertGreaterThan(first.count, 1)
    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertEqual(first.map(\.documentID), Array(repeating: documentID, count: first.count))
    XCTAssertEqual(Set(first.map(\.id)).count, first.count)

    let read = try await service.read(documentID: documentID)
    XCTAssertEqual(read.documentID, documentID)
    XCTAssertTrue(read.isTruncated)
    XCTAssertEqual(read.text.count, WorkbenchAgentKnowledgeService.maximumReadCharacters)
    XCTAssertLessThanOrEqual(read.title.count, WorkbenchAgentKnowledgeService.maximumTitleLength)
  }

  func testChunkReadPaginatesAndRechecksRevokedPermission() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commit(
      title: "长资料",
      text: (0..<2_000).map { "段落\($0)：后段可读取的资料正文。" }.joined(separator: "\n"),
      allowsRemoteAIUse: true,
      library: library
    )
    let service = WorkbenchAgentKnowledgeService(library: library)
    let hits = try await service.search(query: "后段可读取", limit: 10)
    let hit = try XCTUnwrap(hits.last)
    let first = try await service.read(
      documentID: documentID, chunkID: hit.chunkID, maximumCharacters: 80
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let second = try await service.read(
      documentID: documentID, chunkID: hit.chunkID, cursor: cursor, maximumCharacters: 80
    )

    XCTAssertEqual(first.chunkID, hit.chunkID)
    XCTAssertEqual(second.chunkID, hit.chunkID)
    XCTAssertEqual(second.cursor, cursor)
    XCTAssertNotEqual(first.text, second.text)

    try library.setAllowsRemoteAIUse(false, documentID: documentID)
    await XCTAssertThrowsErrorAsync(
      try await service.read(documentID: documentID, chunkID: hit.chunkID, cursor: cursor)
    ) { error in
      XCTAssertEqual(error as? WorkbenchAgentKnowledgeError, .notAllowed)
    }
  }

  func testReadRejectsMissingAndUnapprovedDocumentsWithoutLeakingPaths() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let deniedID = try await commit(
      title: "本地私有资料",
      text: "不允许远程读取。",
      allowsRemoteAIUse: false,
      library: library
    )
    let service = WorkbenchAgentKnowledgeService(library: library)

    do {
      _ = try await service.read(documentID: deniedID)
      XCTFail("未授权文档不应被读取")
    } catch let error as WorkbenchAgentKnowledgeError {
      XCTAssertEqual(error, .notAllowed)
      XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
    }

    let archivedID = try await commit(
      title: "已归档资料",
      text: "即使曾允许远程使用，归档后也不能读取。",
      allowsRemoteAIUse: true,
      library: library
    )
    try library.moveToRecycleBin(documentIDs: [archivedID])
    do {
      _ = try await service.read(documentID: archivedID)
      XCTFail("归档文档不应被读取")
    } catch let error as WorkbenchAgentKnowledgeError {
      XCTAssertEqual(error, .notAllowed)
    }

    let missingID = UUID()
    do {
      _ = try await service.read(documentID: missingID)
      XCTFail("不存在的文档不应被读取")
    } catch let error as WorkbenchAgentKnowledgeError {
      XCTAssertEqual(error, .missingDocument)
      XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
    }
  }

  func testChunkReadDoesNotRequireLocalSemanticIndexPermission() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commit(
      title: "独立授权资料",
      text: "片段读取应只取决于远程 AI 授权，不依赖本地语义索引。",
      allowsRemoteAIUse: true,
      library: library
    )
    try library.setAllowsLocalSemanticIndex(false, documentID: documentID)
    let service = WorkbenchAgentKnowledgeService(library: library)
    let hits = try await service.search(query: "片段读取")
    let hit = try XCTUnwrap(hits.first { $0.documentID == documentID })

    let result = try await service.read(documentID: documentID, chunkID: hit.chunkID)

    XCTAssertEqual(result.chunkID, hit.chunkID)
    XCTAssertTrue(result.text.contains("不依赖本地语义索引"))
    XCTAssertFalse(try XCTUnwrap(library.document(id: documentID)).allowsLocalSemanticIndex)
    try library.setAllowsRemoteAIUse(false, documentID: documentID)
    await XCTAssertThrowsErrorAsync(
      try await service.read(documentID: documentID, chunkID: hit.chunkID)
    ) { error in
      XCTAssertEqual(error as? WorkbenchAgentKnowledgeError, .notAllowed)
    }
  }

  func testChunkReadRejectsAnotherDocumentsLocator() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let firstID = try await commit(
      title: "第一份资料", text: "跨文档片段定位校验。",
      allowsRemoteAIUse: true, library: library
    )
    let secondID = try await commit(
      title: "第二份资料", text: "另一份允许读取的独立内容。",
      allowsRemoteAIUse: true, library: library
    )
    let service = WorkbenchAgentKnowledgeService(library: library)
    let hits = try await service.search(query: "跨文档片段")
    let hit = try XCTUnwrap(hits.first { $0.documentID == firstID })

    await XCTAssertThrowsErrorAsync(
      try await service.read(documentID: secondID, chunkID: hit.chunkID)
    ) { error in
      XCTAssertEqual(error as? WorkbenchAgentKnowledgeError, .missingDocument)
    }
  }

  func testChunkReadRejectsPreviousRevisionAfterReimport() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let sourceURL = rootURL.appendingPathComponent("revision.txt")
    try "旧版本片段内容。".write(to: sourceURL, atomically: true, encoding: .utf8)
    let imported = try await library.commit(
      try await library.makeImportPreview(sourceURL: sourceURL))
    let documentID = try XCTUnwrap(imported.documentIDs.first)
    try library.setAllowsRemoteAIUse(true, documentID: documentID)
    let service = WorkbenchAgentKnowledgeService(library: library)
    let hits = try await service.search(query: "旧版本片段")
    let hit = try XCTUnwrap(hits.first)

    try "新版本正文应取代旧内容。".write(to: sourceURL, atomically: true, encoding: .utf8)
    let updated = try await library.commit(
      try await library.makeImportPreview(sourceURL: sourceURL))
    XCTAssertEqual(updated.updatedCount, 1)
    try library.setAllowsRemoteAIUse(true, documentID: documentID)

    await XCTAssertThrowsErrorAsync(
      try await service.read(documentID: documentID, chunkID: hit.chunkID)
    ) { error in
      XCTAssertEqual(error as? WorkbenchAgentKnowledgeError, .missingDocument)
    }
    let current = try await service.read(documentID: documentID)
    XCTAssertTrue(current.text.contains("新版本正文"))
    XCTAssertFalse(current.text.contains("旧版本片段"))
  }

  func testEmptyQueryAndCancellationUseDistinctErrors() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = WorkbenchAgentKnowledgeService(
      library: KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    )

    do {
      _ = try await service.search(query: " \n\t ")
      XCTFail("空查询应被拒绝")
    } catch let error as WorkbenchAgentKnowledgeError {
      XCTAssertEqual(error, .emptyQuery)
    }

    let task = Task { try await service.search(query: "已取消") }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("取消后的搜索应失败")
    } catch let error as WorkbenchAgentKnowledgeError {
      XCTAssertEqual(error, .cancelled)
    }
  }

  private func commit(
    title: String,
    text: String,
    sourceURL: URL? = nil,
    allowsRemoteAIUse: Bool,
    library: KnowledgeLibraryService
  ) async throws -> UUID {
    let hash = KnowledgeChunkingService.contentHash(for: text)
    let candidate = KnowledgeImportCandidate(
      kind: .markdown,
      title: title,
      sourceURL: sourceURL,
      sourceName: "\(title).md",
      allowsRemoteAIUse: allowsRemoteAIUse,
      originalContentHash: hash,
      normalizedText: text,
      normalizedContentHash: hash,
      sections: [KnowledgeExtractedSection(headingPath: title, text: text)]
    )
    let preview = KnowledgeImportPreview(sourceName: "fixture", candidates: [candidate])
    let result = try await library.commit(preview)
    return try XCTUnwrap(result.documentIDs.first)
  }

  private func temporaryDirectory() throws -> URL {
    try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "agent-knowledge")
  }
}
