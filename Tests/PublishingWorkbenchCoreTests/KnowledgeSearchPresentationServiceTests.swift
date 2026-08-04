import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeSearchPresentationServiceTests: XCTestCase {
  private let service = KnowledgeSearchPresentationService()

  func testPresentationCentersContextOnKeywordAndOrdersReasons() {
    let content = String(repeating: "前文", count: 80)
      + " 精确关键词 "
      + String(repeating: "后文", count: 80)
    let result = makeResult(
      title: "标题也有精确关键词",
      content: content,
      signals: [.semantic, .fullText, .title]
    )

    let hit = service.presentation(
      for: result,
      query: "精确关键词",
      maximumSnippetCharacters: 90
    )

    XCTAssertTrue(hit.snippet.contains("精确关键词"))
    XCTAssertTrue(hit.snippet.hasPrefix("…"))
    XCTAssertTrue(hit.snippet.hasSuffix("…"))
    XCTAssertEqual(hit.highlightTerms, ["精确关键词"])
    XCTAssertEqual(hit.reasons, [.title, .fullText, .semantic])
  }

  func testLexicalSignalsDistinguishTitleFromFullText() {
    let titleResult = makeResult(
      title: "星云写作笔记",
      content: "这段正文没有搜索词。",
      signals: [.fullText]
    )
    let bodyResult = makeResult(
      title: "普通文章",
      content: "正文讨论星云写作方法。",
      signals: [.fullText]
    )

    XCTAssertEqual(
      service.lexicalSignals(for: titleResult, query: "星云"),
      [.title]
    )
    XCTAssertEqual(
      service.lexicalSignals(for: bodyResult, query: "星云"),
      [.fullText]
    )
  }

  func testTargetBlockUsesExactParagraphWithinCorrectHeading() throws {
    let blocks = KnowledgeDocumentBlockParser().blocks(in: """
    # 第一章

    这是一段普通内容。

    # 第二章

    目标关键词出现在这个准确段落，应当定位到这里。
    """)
    let result = makeResult(
      title: "长文章",
      content: "目标关键词出现在这个准确段落，应当定位到这里。",
      headingPath: "第二章",
      signals: [.fullText]
    )

    let blockID = try XCTUnwrap(
      service.targetBlockID(in: blocks, for: result, query: "目标关键词")
    )

    XCTAssertEqual(blockID, 3)
    XCTAssertEqual(blocks[blockID].text, "目标关键词出现在这个准确段落，应当定位到这里。")
  }

  func testSemanticOnlyHitUsesReadableParagraphAsAnchor() {
    let result = makeResult(
      title: "本地检索",
      content: "第一段是语义召回的上下文。\n\n第二段是补充内容。",
      locator: "第 18 页",
      signals: [.semantic]
    )

    let hit = service.presentation(for: result, query: "换一种说法")

    XCTAssertEqual(hit.snippet, "第一段是语义召回的上下文。")
    XCTAssertEqual(hit.paragraphAnchor, "第一段是语义召回的上下文。")
    XCTAssertEqual(hit.locationLabel, "第 18 页")
    XCTAssertEqual(hit.reasons, [.semantic])
  }

  private func makeResult(
    title: String,
    content: String,
    headingPath: String? = nil,
    locator: String? = nil,
    signals: Set<KnowledgeRetrievalSignal>
  ) -> KnowledgeSearchResult {
    let revisionID = UUID()
    let document = KnowledgeDocument(
      kind: .article,
      title: title,
      currentRevisionID: revisionID
    )
    let chunk = KnowledgeChunk(
      documentID: document.id,
      revisionID: revisionID,
      ordinal: 0,
      headingPath: headingPath,
      locator: locator,
      content: content,
      tokenEstimate: 20,
      contentHash: "test"
    )
    return KnowledgeSearchResult(
      document: document,
      chunk: chunk,
      score: 1,
      signals: signals
    )
  }
}
