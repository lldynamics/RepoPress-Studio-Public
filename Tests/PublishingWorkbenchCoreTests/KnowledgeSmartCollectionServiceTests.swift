import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeSmartCollectionServiceTests: XCTestCase {
  private let service = KnowledgeSmartCollectionService()

  func testCollectionsGroupAuthorsTagsDomainsTimeAndAIPermission() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 7,
      day: 17,
      hour: 12
    )))
    let documents = [
      makeDocument(
        title: "A",
        authors: ["陈作者"],
        tags: ["写作", "本地优先"],
        sourceURL: URL(string: "https://www.example.com/a"),
        allowsAIUse: true,
        importedAt: now
      ),
      makeDocument(
        title: "B",
        authors: ["陈作者", "林作者"],
        tags: ["写作"],
        sourceURL: URL(string: "https://example.com/b"),
        allowsAIUse: false,
        importedAt: try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
      ),
      makeDocument(
        title: "C",
        authors: ["其他作者"],
        tags: ["阅读"],
        sourceURL: URL(string: "https://another.example/c"),
        allowsAIUse: true,
        importedAt: try XCTUnwrap(calendar.date(byAdding: .month, value: -2, to: now))
      ),
    ]

    let collections = service.collections(for: documents, now: now, calendar: calendar)

    XCTAssertEqual(collections.first(where: { $0.rule == .author("陈作者") })?.documentCount, 2)
    XCTAssertEqual(collections.first(where: { $0.rule == .tag("写作") })?.documentCount, 2)
    XCTAssertEqual(
      collections.first(where: { $0.rule == .sourceDomain("example.com") })?.documentCount,
      2
    )
    XCTAssertEqual(collections.first(where: { $0.rule == .time(.today) })?.documentCount, 1)
    XCTAssertEqual(collections.first(where: { $0.rule == .time(.thisWeek) })?.documentCount, 1)
    XCTAssertEqual(collections.first(where: { $0.rule == .time(.earlier) })?.documentCount, 1)
    XCTAssertEqual(collections.first(where: { $0.rule == .aiPermission(true) })?.documentCount, 2)
    XCTAssertEqual(collections.first(where: { $0.rule == .aiPermission(false) })?.documentCount, 1)
  }

  func testCollectionMatchingIsCaseInsensitiveAndDomainNormalized() {
    let document = makeDocument(
      title: "A",
      authors: ["Alice"],
      tags: ["Research"],
      sourceURL: URL(string: "https://WWW.Example.COM/article"),
      allowsAIUse: true,
      importedAt: Date()
    )

    XCTAssertTrue(service.matches(document, rule: .author("alice")))
    XCTAssertTrue(service.matches(document, rule: .tag("research")))
    XCTAssertTrue(service.matches(document, rule: .sourceDomain("example.com")))
    XCTAssertFalse(service.matches(document, rule: .aiPermission(false)))
  }

  func testBrowserOrganizationSuggestionsRankFolderAndRelatedTagsWithoutApplyingThem() throws {
    let research = KnowledgeFolder(name: "产品研究")
    let reading = KnowledgeFolder(name: "待读")
    var domainAndAuthor = makeDocument(
      title: "同来源同作者",
      authors: ["陈作者"],
      tags: ["AI", "知识管理"],
      sourceURL: URL(string: "https://www.example.com/older"),
      allowsAIUse: true,
      importedAt: Date()
    )
    domainAndAuthor.folderID = research.id
    var sameDomain = makeDocument(
      title: "同来源",
      authors: ["其他作者"],
      tags: ["检索"],
      sourceURL: URL(string: "https://example.com/second"),
      allowsAIUse: true,
      importedAt: Date()
    )
    sameDomain.folderID = research.id
    var onlyTag = makeDocument(
      title: "仅标签相同",
      authors: [],
      tags: ["AI", "稍后读"],
      sourceURL: URL(string: "https://other.example/item"),
      allowsAIUse: true,
      importedAt: Date()
    )
    onlyTag.folderID = reading.id

    let suggestions = service.browserOrganizationSuggestions(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/new")),
      authors: ["陈作者"],
      tags: ["AI"],
      documents: [domainAndAuthor, sameDomain, onlyTag],
      folders: [research, reading]
    )

    XCTAssertEqual(suggestions.folders.first?.folder.id, research.id)
    XCTAssertEqual(
      Set(try XCTUnwrap(suggestions.folders.first).reasons),
      [.sourceDomain, .author, .tag]
    )
    XCTAssertTrue(suggestions.tags.contains("知识管理"))
    XCTAssertFalse(suggestions.tags.contains("AI"))
    XCTAssertEqual(domainAndAuthor.folderID, research.id)
    XCTAssertEqual(onlyTag.folderID, reading.id)
  }

  func testSavedCollectionCombinesRulesAndRoundTripsThroughJSON() throws {
    let matching = makeDocument(
      title: "匹配",
      authors: ["Alice"],
      tags: ["Research"],
      sourceURL: URL(string: "https://example.com/a"),
      allowsAIUse: true,
      importedAt: Date()
    )
    let partial = makeDocument(
      title: "部分匹配",
      authors: ["Alice"],
      tags: ["Other"],
      sourceURL: URL(string: "https://example.com/b"),
      allowsAIUse: false,
      importedAt: Date()
    )
    let collection = KnowledgeSavedCollection(
      name: "研究资料",
      rules: [.author("Alice"), .tag("Research"), .aiPermission(true)],
      matchMode: .all
    )

    XCTAssertTrue(service.matches(matching, rules: collection.rules, matchMode: .all))
    XCTAssertFalse(service.matches(partial, rules: collection.rules, matchMode: .all))
    XCTAssertTrue(service.matches(partial, rules: collection.rules, matchMode: .any))

    let decoded = try JSONDecoder().decode(
      KnowledgeSavedCollection.self,
      from: JSONEncoder().encode(collection)
    )
    XCTAssertEqual(decoded, collection)
  }

  func testSearchFilterSupportsScopeSignalAndAddedTimeSort() {
    let older = makeDocument(
      title: "旧资料",
      authors: [],
      tags: [],
      sourceURL: nil,
      allowsAIUse: true,
      importedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = makeDocument(
      title: "新资料",
      authors: [],
      tags: [],
      sourceURL: nil,
      allowsAIUse: true,
      importedAt: Date(timeIntervalSince1970: 20)
    )
    let olderResult = makeSearchResult(document: older, signals: [.semantic], score: 0.9)
    let newerResult = makeSearchResult(document: newer, signals: [.fullText], score: 0.5)
    let filter = KnowledgeSearchFilter(
      scope: .allLibrary,
      signal: .all,
      sort: .addedNewest
    )

    XCTAssertEqual(
      filter.filtered([olderResult, newerResult], isInCurrentCollection: { _ in false })
        .map(\.document.title),
      ["新资料", "旧资料"]
    )

    let semanticOnly = KnowledgeSearchFilter(
      scope: .currentCollection,
      signal: .semantic,
      sort: .relevance
    )
    XCTAssertEqual(
      semanticOnly.filtered([olderResult, newerResult]) { $0.id == older.id }.map(\.id),
      [olderResult.id]
    )
  }

  func testRelatedRankingCombinesMetadataAndSemanticReasons() {
    let now = Date()
    let anchor = makeRecord(
      document: makeDocument(
        title: "锚点",
        authors: ["陈作者"],
        tags: ["本地优先"],
        sourceURL: URL(string: "https://example.com/a"),
        allowsAIUse: true,
        importedAt: now
      ),
      content: "本地资料库的核心章节讨论如何长期保存、追踪来源并为写作提供可靠上下文。"
    )
    let metadataMatch = makeRecord(
      document: makeDocument(
        title: "元数据关联",
        authors: ["陈作者"],
        tags: ["本地优先"],
        sourceURL: URL(string: "https://www.example.com/b"),
        allowsAIUse: true,
        importedAt: now.addingTimeInterval(-3_600)
      ),
      content: "关联章节从作者和标签角度补充长期保存、引用追踪与本地优先的实践方法。"
    )
    let semanticMatch = makeRecord(
      document: makeDocument(
        title: "换种说法",
        authors: [],
        tags: [],
        sourceURL: URL(string: "https://other.example/b"),
        allowsAIUse: true,
        importedAt: now.addingTimeInterval(-90 * 86_400)
      ),
      content: "这段内容使用不同措辞说明离线知识整理如何支撑长期写作、保存来源，并形成可以回溯核验的可信引用链路。"
    )
    let unrelated = makeRecord(
      document: makeDocument(
        title: "无关资料",
        authors: [],
        tags: [],
        sourceURL: nil,
        allowsAIUse: true,
        importedAt: now.addingTimeInterval(-200 * 86_400)
      ),
      content: "这是一段长度足够但主题完全无关的候选内容，用于确认没有信号时不会获得推荐。"
    )

    let results = KnowledgeRelatedChapterRankingService().recommendations(
      anchor: anchor,
      candidates: [anchor, metadataMatch, semanticMatch, unrelated],
      semanticScores: [semanticMatch.chunk.id: 0.8],
      limit: 6
    )

    XCTAssertEqual(results.map(\.document.title), ["元数据关联", "换种说法"])
    XCTAssertTrue(results.first?.reasons.contains(.author("陈作者")) == true)
    XCTAssertTrue(results.first?.reasons.contains(.tag("本地优先")) == true)
    XCTAssertTrue(results.first?.reasons.contains(.sourceDomain("example.com")) == true)
    XCTAssertTrue(results.dropFirst().first?.reasons.contains(.semantic) == true)
  }

  func testRelatedRankingRejectsBloggerChromeAndSamePageWebChunks() {
    let webpage = KnowledgeDocument(
      kind: .webpage,
      title: "结构性优势",
      sourceURL: URL(string: "https://example.blogspot.com/post")
    )
    let anchor = makeRecord(
      document: webpage,
      content: "正文讨论长期积累如何形成结构性优势，并说明竞争较少时知识复利更明显。"
    )
    let samePage = makeRecord(
      document: webpage,
      content: "同一网页的另一段正文虽然足够长，也不应该作为网页自身的主动关联推荐。"
    )
    let commentFrame = makeRecord(
      document: KnowledgeDocument(kind: .webpage, title: "评论框"),
      content: "发表评论 https://www.blogger.com/comment/frame/123456 较新的博文 博客归档"
    )
    let useful = makeRecord(
      document: KnowledgeDocument(kind: .book, title: "长期积累"),
      content: "书籍章节解释持续积累、较少竞争和知识复利之间的关系，并提供长期保存来源和反复验证观点的方法，可作为独立相关内容。"
    )

    let results = KnowledgeRelatedChapterRankingService().recommendations(
      anchor: anchor,
      candidates: [anchor, samePage, commentFrame, useful],
      semanticScores: [samePage.chunk.id: 0.95, commentFrame.chunk.id: 0.99, useful.chunk.id: 0.8],
      limit: 6
    )

    XCTAssertEqual(results.map(\.document.title), ["长期积累"])
  }

  private func makeDocument(
    title: String,
    authors: [String],
    tags: [String],
    sourceURL: URL?,
    allowsAIUse: Bool,
    importedAt: Date
  ) -> KnowledgeDocument {
    KnowledgeDocument(
      kind: .article,
      title: title,
      authors: authors,
      tags: tags,
      sourceURL: sourceURL,
      allowsRemoteAIUse: allowsAIUse,
      importedAt: importedAt,
      updatedAt: importedAt
    )
  }

  private func makeRecord(
    document: KnowledgeDocument,
    content: String
  ) -> KnowledgeSemanticIndexRecord {
    KnowledgeSemanticIndexRecord(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: 0,
        headingPath: "章节",
        content: content,
        tokenEstimate: 10,
        contentHash: UUID().uuidString
      )
    )
  }

  private func makeSearchResult(
    document: KnowledgeDocument,
    signals: Set<KnowledgeRetrievalSignal>,
    score: Double
  ) -> KnowledgeSearchResult {
    KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: 0,
        content: document.title,
        tokenEstimate: 2,
        contentHash: UUID().uuidString
      ),
      score: score,
      signals: signals
    )
  }
}
