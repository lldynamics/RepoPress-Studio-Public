import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeContextRecommendationPresentationTests: XCTestCase {
  func testFirstFourCardsUseDistinctDocumentsAndKeepAdditionalChunksAvailable() {
    let query = "标题：Fedora 更新"
    let first = fixture(
      title: "Fedora 资料一",
      content: "Fedora 更新的第一段资料。",
      ordinal: 0,
      signals: [.semantic, .fullText]
    )
    let firstAdditional = fixture(
      document: first.document,
      content: "Fedora 更新的第二段资料。",
      ordinal: 1,
      signals: [.semantic, .fullText]
    )
    let second = fixture(title: "资料二", content: "Fedora 更新日志。", ordinal: 0, signals: [.fullText])
    let third = fixture(title: "Fedora 资料三", ordinal: 0, signals: [.title])
    let fourth = fixture(title: "资料四", content: "Fedora 更新说明。", ordinal: 0, signals: [.fullText])
    let cards = KnowledgeContextRecommendationPresentationPolicy.cards(
      from: [first, firstAdditional, second, third, fourth],
      query: query
    )

    XCTAssertEqual(
      cards.map(\.document.id),
      [
        first.document.id, second.document.id, third.document.id, fourth.document.id,
      ])
    XCTAssertEqual(cards.first?.additionalResults, [firstAdditional])
    XCTAssertEqual(cards.first?.reason, "标题和正文命中：“Fedora”")
    XCTAssertEqual(cards[1].reason, "正文命中：“Fedora”")
    XCTAssertEqual(cards[2].reason, "标题命中：“Fedora”")
  }

  func testGenericFullTextFlagAndSemanticOnlyResultStayInPossibleGroup() {
    let query = "标题：Fedora 系统更新"
    let semanticOnly = fixture(title: "人生感悟", ordinal: 0, signals: [.semantic])
    let genericFlagOnly = fixture(
      title: "系统随笔",
      content: "系统维护的个人感悟。",
      ordinal: 1,
      signals: [.fullText, .semantic]
    )
    let keywordResult = fixture(
      title: "Fedora 更新说明",
      content: "Fedora 的升级步骤。",
      ordinal: 0,
      signals: [.fullText, .semantic]
    )

    let groups = KnowledgeContextRecommendationPresentationPolicy.groups(
      from: [semanticOnly, genericFlagOnly, keywordResult],
      query: query
    )

    XCTAssertEqual(groups.strong.map(\.document.id), [keywordResult.document.id])
    XCTAssertEqual(
      Set(groups.possible.map(\.document.id)),
      [semanticOnly.document.id, genericFlagOnly.document.id]
    )
    XCTAssertEqual(groups.strong.first?.reason, "标题和正文命中：“Fedora”")
    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: genericFlagOnly,
        query: query
      ).strength,
      .possible
    )
  }

  func testTitleAndBodyEvidenceUseAnExplicitReason() {
    let result = fixture(
      title: "Fedora 运维",
      content: "Fedora 的更新与回滚流程。",
      ordinal: 0,
      signals: [.title, .fullText, .semantic]
    )

    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: result,
        query: "标题：Fedora 升级"
      ).reason,
      "标题和正文命中：“Fedora”"
    )
  }

  func testDismissalInputOnlyHidesDocumentForThatQuery() {
    let query = "标题：Fedora 更新"
    let first = fixture(title: "Fedora 资料一", ordinal: 0, signals: [.fullText])
    let second = fixture(title: "Fedora 资料二", ordinal: 0, signals: [.fullText])
    let results = [first, second]

    let hiddenForFirstQuery = KnowledgeContextRecommendationPresentationPolicy.cards(
      from: results,
      query: query,
      excludingDocumentIDs: [first.document.id]
    )
    let differentQuery = KnowledgeContextRecommendationPresentationPolicy.cards(
      from: results,
      query: query
    )

    XCTAssertEqual(hiddenForFirstQuery.map(\.document.id), [second.document.id])
    XCTAssertEqual(differentQuery.map(\.document.id), [first.document.id, second.document.id])
  }

  func testChineseTopicFromRealQueryBuilderOutputPromotesMatchingLibraryIndexGuide() {
    let query = KnowledgeContextQueryService.query(
      input: KnowledgeContextQueryInput(
        title: "如何修复资料库索引",
        summary: "",
        tags: [],
        bodyMarkdown: "资料库检索结果没有更新。"
      )
    )
    let result = fixture(
      title: "资料库索引维护指南",
      content: "重建本地索引后重新检索。",
      ordinal: 0,
      signals: [.semantic, .fullText]
    )

    XCTAssertTrue(query.contains("标题：如何修复资料库索引"))
    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: result,
        query: query
      ).strength,
      .strong
    )
  }

  func testEnglishAndSwiftSyntaxOnlyDoNotPromoteSemanticCandidate() {
    let query = KnowledgeContextQueryService.query(
      input: KnowledgeContextQueryInput(
        title: "SwiftUI 窗口状态",
        summary: "",
        tags: [],
        bodyMarkdown: "```swift\nimport Foundation\n```"
      )
    )
    let result = fixture(
      title: "CSV 导入格式",
      content: "import Foundation\n使用逗号分隔列。",
      ordinal: 0,
      signals: [.semantic, .fullText]
    )

    XCTAssertTrue(query.contains("import Foundation"))
    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: result,
        query: query
      ).strength,
      .possible
    )
  }

  func testGenericChineseQueryFrameDoesNotPromoteDifferentTopic() {
    let query = KnowledgeContextQueryService.query(
      input: KnowledgeContextQueryInput(
        title: "如何使用 SwiftUI 管理窗口",
        summary: "",
        tags: [],
        bodyMarkdown: ""
      )
    )
    let result = fixture(
      title: "如何使用 Excel 导出 CSV",
      content: "使用表格导出数据。",
      ordinal: 0,
      signals: [.semantic, .fullText]
    )

    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: result,
        query: query
      ).strength,
      .possible
    )
  }

  func testEnglishTermsRequireWholeTokenizerMatches() {
    let query = KnowledgeContextQueryService.query(
      input: KnowledgeContextQueryInput(
        title: "API 设计",
        summary: "",
        tags: [],
        bodyMarkdown: ""
      )
    )
    let result = fixture(
      title: "Capital planning",
      content: "A budget outline for the next quarter.",
      ordinal: 0,
      signals: [.semantic, .fullText]
    )

    XCTAssertEqual(
      KnowledgeContextRecommendationPresentationPolicy.classification(
        for: result,
        query: query
      ).strength,
      .possible
    )
  }

  func testSnapshotPreservesGroupsAndCachesEveryRenderedSnippet() throws {
    let query = "标题：Fedora 更新"
    let first = fixture(title: "Fedora 资料一", ordinal: 0, signals: [.semantic, .fullText])
    let additional = fixture(
      document: first.document,
      title: first.document.title,
      ordinal: 1,
      signals: [.semantic, .fullText]
    )
    let possible = fixture(title: "不相干资料", ordinal: 0, signals: [.semantic])
    let input = KnowledgeContextRecommendationPresentationInput(
      query: query,
      results: [first, additional, possible],
      excludingDocumentIDs: []
    )

    let snapshot = try XCTUnwrap(KnowledgeContextRecommendationPresentationPolicy.snapshot(for: input))
    let expected = KnowledgeContextRecommendationPresentationPolicy.groups(
      from: input.results,
      query: query
    )
    let renderedResults = (snapshot.groups.strong + snapshot.groups.possible).flatMap {
      [$0.primaryResult] + $0.additionalResults
    }

    XCTAssertEqual(snapshot.groups.strong.map(\.document.id), expected.strong.map(\.document.id))
    XCTAssertEqual(snapshot.groups.possible.map(\.document.id), expected.possible.map(\.document.id))
    XCTAssertEqual(snapshot.groups.strong.map(\.reason), expected.strong.map(\.reason))
    XCTAssertEqual(snapshot.semanticRecommendationCount, 1)
    XCTAssertEqual(Set(snapshot.hitsByResultID.keys), Set(renderedResults.map(\.id)))
  }

  func testSnapshotClassifiesEachEligibleResultOnceAndSkipsDismissedDocument() throws {
    let first = fixture(title: "Fedora 一", ordinal: 0, signals: [.semantic])
    let second = fixture(title: "Fedora 二", ordinal: 0, signals: [.semantic])
    let dismissed = fixture(title: "Fedora 三", ordinal: 0, signals: [.semantic])
    let input = KnowledgeContextRecommendationPresentationInput(
      query: "标题：Fedora 更新",
      results: [first, second, dismissed],
      excludingDocumentIDs: [dismissed.document.id]
    )

    let snapshot = try XCTUnwrap(KnowledgeContextRecommendationPresentationPolicy.snapshot(for: input))

    XCTAssertEqual(snapshot.classifiedResultCount, 2)
    XCTAssertFalse(snapshot.groups.strong.map(\.document.id).contains(dismissed.document.id))
    XCTAssertFalse(snapshot.groups.possible.map(\.document.id).contains(dismissed.document.id))
  }

  func testEmptyQuerySnapshotSkipsClassificationAndSnippetWork() throws {
    let result = fixture(title: "Fedora 资料", ordinal: 0, signals: [.semantic])
    let input = KnowledgeContextRecommendationPresentationInput(
      query: "  \n",
      results: [result],
      excludingDocumentIDs: []
    )

    let snapshot = try XCTUnwrap(KnowledgeContextRecommendationPresentationPolicy.snapshot(for: input))

    XCTAssertEqual(snapshot.query, input.query)
    XCTAssertTrue(snapshot.groups.strong.isEmpty)
    XCTAssertTrue(snapshot.groups.possible.isEmpty)
    XCTAssertTrue(snapshot.hitsByResultID.isEmpty)
    XCTAssertEqual(snapshot.classifiedResultCount, 0)
  }

  private func fixture(
    document: KnowledgeDocument? = nil,
    title: String = "资料",
    content: String = "与本次写作相关的片段",
    ordinal: Int,
    signals: Set<KnowledgeRetrievalSignal>
  ) -> KnowledgeSearchResult {
    let document = document ?? KnowledgeDocument(kind: .note, title: title)
    let chunk = KnowledgeChunk(
      documentID: document.id,
      revisionID: document.currentRevisionID,
      ordinal: ordinal,
      content: "\(content) \(ordinal)",
      tokenEstimate: 12,
      contentHash: "chunk-\(ordinal)"
    )
    return KnowledgeSearchResult(document: document, chunk: chunk, score: 1, signals: signals)
  }
}
