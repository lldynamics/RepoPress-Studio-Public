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
    XCTAssertTrue(results.allSatisfy { $0.signals.allSatisfy { ["title", "fullText", "semantic"].contains($0) } })
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
    XCTAssertTrue(maximum.allSatisfy { $0.title.count <= WorkbenchAgentKnowledgeService.maximumTitleLength })
    XCTAssertTrue(maximum.allSatisfy { $0.excerpt.count <= WorkbenchAgentKnowledgeService.maximumExcerptLength })
    let total = maximum.reduce(0) { partial, hit in
      partial + hit.documentID.uuidString.count
        + hit.chunkID.uuidString.count
        + hit.title.count
        + (hit.locator?.count ?? 0)
        + hit.excerpt.count
        + hit.signals.reduce(0) { $0 + $1.count }
        + (hit.sourceURL?.absoluteString.count ?? 0)
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
