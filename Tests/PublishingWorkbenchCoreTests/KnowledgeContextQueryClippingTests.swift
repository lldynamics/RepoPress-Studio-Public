import Foundation
import PublishingCoreSupport
import PublishingKnowledgeCore
import XCTest

@testable import PublishingWorkbenchCore

final class KnowledgeContextQueryClippingTests: XCTestCase {
  private let tokenizer = LocalBPETokenizer(encoding: .o200kBase)

  func testContextPrefersAQueryHitInTheMiddleOfAnOversizedChunk() async throws {
    let prefix = String(repeating: "开场背景用于填充。", count: 90)
    let suffix = String(repeating: "结尾背景用于填充。", count: 90)
    let source = """
      # 中段命中

      \(prefix)

      真正答案在中段：星港补给每周三到港，需提前一天预约。

      \(suffix)
      """
    let service = try await importedService(markdown: source)

    let context = try XCTUnwrap(
      service.context(query: "星港补给", maximumCitations: 1, tokenBudget: 160))
    let excerpt = try XCTUnwrap(context.citations.first?.excerpt)

    XCTAssertTrue(excerpt.contains("星港补给每周三到港"))
    XCTAssertLessThanOrEqual(tokenizer.tokenCount(excerpt), 160)
  }

  func testContextRetainsMultipleMatchingParagraphsInOriginalOrder() async throws {
    let source = """
      # 多段命中

      \(String(repeating: "开头材料。", count: 80))

      第一处答案：北门在工作日七点开放。

      \(String(repeating: "中间材料。", count: 80))

      第二处答案：南门在周末九点开放。

      \(String(repeating: "结尾材料。", count: 80))
      """
    let service = try await importedService(markdown: source)

    let context = try XCTUnwrap(
      service.context(query: "开放", maximumCitations: 1, tokenBudget: 240))
    let excerpt = try XCTUnwrap(context.citations.first?.excerpt)
    let first = try XCTUnwrap(excerpt.range(of: "北门在工作日七点开放"))
    let second = try XCTUnwrap(excerpt.range(of: "南门在周末九点开放"))

    XCTAssertLessThan(first.lowerBound, second.lowerBound)
    XCTAssertLessThanOrEqual(tokenizer.tokenCount(excerpt), 240)
  }

  func testContextSafelyBoundsTitleOnlyMatchWithNoMatchingParagraph() async throws {
    let source = """
      # 普通资料

      \(String(repeating: "这段正文没有检索词。", count: 120))

      \(String(repeating: "仍然只是普通背景。", count: 120))
      """
    let service = try await importedService(markdown: source)

    let document = try XCTUnwrap(service.documents().first)
    try service.updateMetadata(
      documentID: document.id,
      metadata: KnowledgeDocumentMetadata(kind: document.kind, title: "标题专有词")
    )
    let result = try XCTUnwrap(service.search(query: "标题专有词", limit: 1).first)
    XCTAssertFalse(result.chunk.content.contains("标题专有词"))
    let context = try XCTUnwrap(
      service.context(query: "标题专有词", maximumCitations: 1, tokenBudget: 140))
    let excerpt = try XCTUnwrap(context.citations.first?.excerpt)

    XCTAssertFalse(excerpt.isEmpty)
    XCTAssertLessThanOrEqual(tokenizer.tokenCount(excerpt), 140)
  }

  func testContextHandlesChineseAndEmojiAroundTheHit() async throws {
    let source = """
      # Unicode 资料

      \(String(repeating: "前置说明。", count: 90))

      🧭 航线答案：蓝鲸号会在凌晨抵达码头。

      \(String(repeating: "后置说明。", count: 90))
      """
    let service = try await importedService(markdown: source)

    let context = try XCTUnwrap(
      service.context(query: "蓝鲸号", maximumCitations: 1, tokenBudget: 150))
    let excerpt = try XCTUnwrap(context.citations.first?.excerpt)

    XCTAssertTrue(excerpt.contains("🧭 航线答案：蓝鲸号"))
    XCTAssertLessThanOrEqual(tokenizer.tokenCount(excerpt), 150)
  }

  func testContextLeavesContentUntouchedWhenItFitsAndHandlesTinyBudgets() async throws {
    let source = """
      # 原文保持

      这段资料足够短，包含唯一术语银河协议，并应完整保留。
      """
    let service = try await importedService(markdown: source)
    let result = try XCTUnwrap(try service.search(query: "银河协议", limit: 1).first)
    let fittingBudget = max(101, tokenizer.tokenCount(result.chunk.content) + 1)

    let fittingContext = try XCTUnwrap(
      service.context(query: "银河协议", maximumCitations: 1, tokenBudget: fittingBudget))
    XCTAssertEqual(fittingContext.citations.first?.excerpt, result.chunk.content)

    XCTAssertNil(try service.context(query: "银河协议", maximumCitations: 1, tokenBudget: 1))
  }

  func testContextFindsTheAnswerInsideOneOversizedParagraph() async throws {
    let source =
      String(repeating: "背景材料与无关说明。", count: 90)
      + " 关键答案：银杉计划将在七月正式启动。 "
      + String(repeating: "结尾背景与其他说明。", count: 90)
    let service = try await importedService(markdown: source)
    let result = try XCTUnwrap(service.search(query: "银杉计划", limit: 1).first)
    XCTAssertFalse(result.chunk.content.contains("\n\n"))
    XCTAssertGreaterThan(tokenizer.tokenCount(result.chunk.content), 150)

    let context = try XCTUnwrap(
      service.context(query: "银杉计划", maximumCitations: 1, tokenBudget: 150))
    let excerpt = try XCTUnwrap(context.citations.first?.excerpt)
    XCTAssertTrue(excerpt.contains("银杉计划将在七月正式启动"))
    XCTAssertLessThanOrEqual(tokenizer.tokenCount(excerpt), 150)
    XCTAssertEqual(context.authorizationBindings.first?.chunkID, result.chunk.id)
    XCTAssertEqual(context.authorizationBindings.first?.revisionID, result.chunk.revisionID)
  }

  private func importedService(markdown: String) async throws -> KnowledgeLibraryService {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "knowledge-context-query-clipping-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { [rootURL] in
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try markdown.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(
      rootURL: rootURL.appendingPathComponent("store", isDirectory: true),
      chunkingService: KnowledgeChunkingService(
        maximumChunkCharacters: 12_000,
        overlapCharacters: 0
      )
    )
    let commit = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    try service.setAllowsRemoteAIUse(true, documentIDs: Set(commit.documentIDs))
    return service
  }
}
