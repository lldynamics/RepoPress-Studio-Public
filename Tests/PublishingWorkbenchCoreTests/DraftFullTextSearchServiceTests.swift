import XCTest
@testable import PublishingWorkbenchCore

final class DraftFullTextSearchServiceTests: XCTestCase {
  private let service = DraftFullTextSearchService()
  private let profileID = UUID()

  func testSearchesTitleSummaryBodyAndMetadataWithUsefulRanking() {
    let draft = makeDraft(
      title: "Swift 发布指南",
      slug: "swift-release",
      tags: ["macOS"],
      summary: "从检查到部署的完整流程",
      body: "先执行构建检查，再发布到远端仓库。",
      repositoryPath: "content/posts/swift-release.md"
    )

    XCTAssertEqual(service.search(query: "Swift", drafts: [draft]).first?.field, .title)
    XCTAssertEqual(service.search(query: "完整流程", drafts: [draft]).first?.field, .summary)
    XCTAssertEqual(service.search(query: "构建检查", drafts: [draft]).first?.field, .body)
    XCTAssertEqual(service.search(query: "macOS", drafts: [draft]).first?.field, .tags)
    XCTAssertEqual(service.search(query: "content/posts", drafts: [draft]).first?.field, .repositoryPath)
  }

  func testMultiTermSearchRequiresEveryTermButCanMatchAcrossFields() {
    let matching = makeDraft(
      title: "Swift 工作流",
      body: "发布之前先运行所有测试。"
    )
    let partial = makeDraft(
      title: "Swift 入门",
      body: "介绍语言基础。"
    )

    let results = service.search(query: "Swift 发布", drafts: [partial, matching])

    XCTAssertEqual(Set(results.map(\.draftID)), [matching.id])
    XCTAssertTrue(results.contains { $0.field == .title && $0.matchedText == "Swift" })
    XCTAssertTrue(results.contains { $0.field == .body && $0.matchedText == "发布" })
  }

  func testBodySearchReturnsDistinctExactRangesAndContext() throws {
    let body = "第一段介绍预览。\n\n第二段包含预览定位。\n\n第三段再次包含预览结果。"
    let draft = makeDraft(title: "多次命中", body: body)

    let hits = service.search(query: "预览", drafts: [draft]).filter { $0.field == .body }

    XCTAssertEqual(hits.count, 3)
    XCTAssertEqual(hits.map(\.sourceRange.location), [5, 15, 29])
    for hit in hits {
      XCTAssertEqual((body as NSString).substring(with: hit.sourceRange), "预览")
      XCTAssertTrue(hit.snippet.contains("预览"))
    }
  }

  func testSearchIsCaseDiacriticAndWidthInsensitive() throws {
    let draft = makeDraft(
      title: "Café 写作",
      body: "使用Ｓｗｉｆｔ构建。"
    )

    let cafe = try XCTUnwrap(service.search(query: "CAFE", drafts: [draft]).first)
    let swift = try XCTUnwrap(service.search(query: "Swift", drafts: [draft]).first)

    XCTAssertEqual(cafe.matchedText, "Café")
    XCTAssertEqual(swift.matchedText, "Ｓｗｉｆｔ")
  }

  func testLimitsMatchesPerDraftAndTotalResults() {
    let first = makeDraft(title: "命中一", body: "目标 目标 目标 目标")
    let second = makeDraft(title: "命中二", body: "目标 目标 目标 目标")

    let results = service.search(
      query: "目标",
      drafts: [first, second],
      limit: 3,
      matchesPerDraft: 2
    )

    XCTAssertEqual(results.count, 3)
    XCTAssertLessThanOrEqual(results.filter { $0.draftID == first.id }.count, 2)
    XCTAssertLessThanOrEqual(results.filter { $0.draftID == second.id }.count, 2)
  }

  func testEmptyQueryReturnsNoResults() {
    XCTAssertTrue(service.search(query: "  \n", drafts: [makeDraft(title: "文章")]).isEmpty)
  }

  func testParsesQuotedStructuredFilters() {
    let query = service.parse(
      query: "发布 title:\"Swift 指南\" tag:mac status:ready before:2026-03-01 after:2026-01-01 is:private"
    )

    XCTAssertEqual(query.textTerms, ["发布"])
    XCTAssertEqual(query.titleTerms, ["Swift 指南"])
    XCTAssertEqual(query.tagTerms, ["mac"])
    XCTAssertEqual(query.statuses, [.ready])
    XCTAssertEqual(query.visibilities, [.private])
    XCTAssertEqual(query.beforeDate, date("2026-03-01T00:00:00Z"))
    XCTAssertEqual(query.afterDate, date("2026-01-01T00:00:00Z"))
    XCTAssertTrue(query.invalidFilters.isEmpty)
  }

  func testStructuredFiltersCombineWithFreeText() {
    let matching = makeDraft(
      title: "Swift 发布指南",
      tags: ["macOS"],
      body: "发布前运行检查。",
      date: date("2026-02-15T12:00:00Z"),
      status: .ready,
      visibility: .private
    )
    let wrongStatus = makeDraft(
      title: "Swift 发布指南",
      tags: ["macOS"],
      body: "发布前运行检查。",
      date: date("2026-02-15T12:00:00Z"),
      status: .draft,
      visibility: .private
    )
    let wrongDate = makeDraft(
      title: "Swift 发布指南",
      tags: ["macOS"],
      body: "发布前运行检查。",
      date: date("2026-04-01T12:00:00Z"),
      status: .ready,
      visibility: .private
    )

    let results = service.search(
      query: "发布 title:Swift tag:mac status:ready after:2026-02-01 before:2026-03-01 is:private",
      drafts: [wrongStatus, wrongDate, matching]
    )

    XCTAssertEqual(Set(results.map(\.draftID)), [matching.id])
  }

  func testFilterOnlyQueryReturnsRepresentativeArticleHits() {
    let ready = makeDraft(title: "待发布文章", status: .ready)
    let draft = makeDraft(title: "普通草稿", status: .draft)

    let results = service.search(query: "status:ready", drafts: [draft, ready])

    XCTAssertEqual(Set(results.map(\.draftID)), [ready.id])
    XCTAssertEqual(results.first?.field, .title)
    XCTAssertEqual(results.first?.matchedText, ready.title)
  }

  func testRepeatedStatusFiltersUseOrSemantics() {
    let draft = makeDraft(title: "草稿", status: .draft)
    let ready = makeDraft(title: "待发布", status: .ready)
    let published = makeDraft(title: "已发布", status: .published)

    let results = service.search(
      query: "status:草稿 status:ready",
      drafts: [published, ready, draft]
    )

    XCTAssertEqual(Set(results.map(\.draftID)), [draft.id, ready.id])
  }

  func testInvalidStructuredFiltersAreReported() {
    let query = service.parse(
      query: "title: status:unknown before:2026-99-99 is:secret"
    )

    XCTAssertFalse(query.hasCriteria)
    XCTAssertEqual(
      query.invalidFilters,
      ["title:", "status:unknown", "before:2026-99-99", "is:secret"]
    )
  }

  func testSavedQueriesDeduplicateLimitAndRoundTrip() {
    var saved: [DraftFullTextSavedQuery] = []
    for index in 0..<25 {
      saved = DraftFullTextSavedQueryService.saving(
        query: "query \(index)",
        searchesAllSites: false,
        in: saved,
        savedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    XCTAssertEqual(saved.count, DraftFullTextSavedQueryService.maximumCount)
    XCTAssertEqual(saved.first?.query, "query 24")
    XCTAssertEqual(saved.last?.query, "query 5")

    let replacementID = UUID()
    saved = DraftFullTextSavedQueryService.saving(
      query: "QUERY 24",
      searchesAllSites: false,
      in: saved,
      id: replacementID,
      savedAt: Date(timeIntervalSince1970: 100)
    )
    XCTAssertEqual(saved.count, DraftFullTextSavedQueryService.maximumCount)
    XCTAssertEqual(saved.first?.id, replacementID)

    let decoded = DraftFullTextSavedQueryService.decode(
      DraftFullTextSavedQueryService.encode(saved)
    )
    XCTAssertEqual(decoded, saved)
    XCTAssertEqual(
      DraftFullTextSavedQueryService.removing(id: replacementID, from: decoded).count,
      saved.count - 1
    )
  }

  func testEditorFocusRequestCarriesExactBodyRange() {
    let range = NSRange(location: 18, length: 4)
    let request = EditorFocusRequest(
      draftID: UUID(),
      field: "body",
      query: "预览定位",
      selectedRange: range
    )

    XCTAssertEqual(request.selectedRange, range)
  }

  private func makeDraft(
    title: String,
    slug: String = "",
    tags: [String] = [],
    summary: String = "",
    body: String = "",
    date: Date = Date(timeIntervalSince1970: 1_000),
    status: DraftStatus = .draft,
    visibility: ArticleVisibility = .public,
    repositoryPath: String? = nil
  ) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profileID,
      title: title,
      date: date,
      slug: slug,
      tags: tags,
      visibility: visibility,
      summary: summary,
      bodyMarkdown: body,
      status: status,
      updatedAt: Date(timeIntervalSince1970: 1_000),
      repositoryPath: repositoryPath
    )
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
