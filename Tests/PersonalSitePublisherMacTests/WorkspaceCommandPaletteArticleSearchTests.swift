import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceCommandPaletteArticleSearchTests: XCTestCase {
  func testLiveBufferSearchPreservesUTF16BodyRange() async throws {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "实时正文", body: "旧正文")
    let liveBody = "甲🙂命中正文"
    let search = makeImmediateSearch()

    search.update(
      query: "命中",
      scope: .articles,
      articleScope: .allDrafts,
      activeProfileID: profileID,
      inputs: [DraftFullTextSearchInput(draft: draft, bodyMarkdown: liveBody)],
      masksPrivateContent: false
    )
    try await waitForCompletion(search)

    let hit = try XCTUnwrap(search.snapshot.displayedHits.first)
    XCTAssertEqual(hit.field, .body)
    XCTAssertEqual(hit.sourceRange, NSRange(location: ("甲🙂" as NSString).length, length: 2))
    XCTAssertEqual(hit.matchedText, "命中")
  }

  func testStructuredQueryReachesServiceWithoutRewriting() async throws {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "结构化 Markdown 指南",
      tags: ["swift"],
      bodyMarkdown: "正文"
    )
    let search = makeImmediateSearch()

    search.update(
      query: "title:\"结构化 Markdown 指南\" tag:swift",
      scope: .all,
      articleScope: .allDrafts,
      activeProfileID: profileID,
      inputs: [DraftFullTextSearchInput(draft: draft, bodyMarkdown: draft.bodyMarkdown)],
      masksPrivateContent: false
    )
    try await waitForCompletion(search)

    XCTAssertEqual(search.snapshot.groups.map(\.draftID), [draft.id])
    XCTAssertEqual(Set(search.snapshot.displayedHits.map(\.field)), [.title, .tags])
  }

  func testPrivateLiveBodyIsMaskedOrSearchableAccordingToPreference() async throws {
    let profileID = UUID()
    let privateDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "私密文章",
      visibility: .private,
      bodyMarkdown: "已保存正文"
    )
    let input = DraftFullTextSearchInput(draft: privateDraft, bodyMarkdown: "实时机密正文")
    let search = makeImmediateSearch()

    search.update(
      query: "机密",
      scope: .articles,
      articleScope: .allDrafts,
      activeProfileID: profileID,
      inputs: [input],
      masksPrivateContent: true
    )
    try await waitForCompletion(search)
    XCTAssertTrue(search.snapshot.displayedHits.isEmpty)
    XCTAssertEqual(search.protectedPrivateDraftCount, 1)

    search.update(
      query: "机密",
      scope: .articles,
      articleScope: .allDrafts,
      activeProfileID: profileID,
      inputs: [input],
      masksPrivateContent: false
    )
    try await waitForCompletion(search)
    XCTAssertEqual(search.snapshot.displayedHits.map(\.draftID), [privateDraft.id])
    XCTAssertEqual(search.protectedPrivateDraftCount, 0)
  }

  func testArticleScopesFilterTheCapturedInputs() async throws {
    let activeProfileID = UUID()
    let otherProfileID = UUID()
    let currentSite = makeDraft(profileID: activeProfileID, title: "当前站点", body: "范围命中")
    let otherSite = makeDraft(profileID: otherProfileID, title: "其他站点", body: "范围命中")
    let generalDraft = ArticleDraft(
      siteProfileID: activeProfileID,
      scope: .general,
      title: "通用草稿",
      bodyMarkdown: "范围命中"
    )
    let inputs = [currentSite, otherSite, generalDraft].map {
      DraftFullTextSearchInput(draft: $0, bodyMarkdown: $0.bodyMarkdown)
    }
    let search = makeImmediateSearch()

    let expectedDraftIDs: [(DraftFullTextSearchScope, Set<UUID>)] = [
      (.allDrafts, [currentSite.id, otherSite.id, generalDraft.id]),
      (.currentSite, [currentSite.id]),
      (.allSites, [currentSite.id, otherSite.id]),
      (.generalDrafts, [generalDraft.id]),
    ]
    for (articleScope, expected) in expectedDraftIDs {
      search.update(
        query: "范围命中",
        scope: .articles,
        articleScope: articleScope,
        activeProfileID: activeProfileID,
        inputs: inputs,
        masksPrivateContent: false
      )
      try await waitForCompletion(search)
      XCTAssertEqual(Set(search.snapshot.displayedHits.map(\.draftID)), expected)
    }
  }

  func testEmptyQueryAndNonArticleScopeDoNotExecuteSearch() async throws {
    let recorder = SearchRecorder()
    let profileID = UUID()
    let input = DraftFullTextSearchInput(
      draft: makeDraft(profileID: profileID, title: "文章", body: "正文"),
      bodyMarkdown: "正文"
    )
    let search = WorkspaceCommandPaletteArticleSearch(
      search: { query, _, _ in
        await recorder.record(query)
        return []
      },
      debounce: { _ in }
    )

    search.update(
      query: "   ", scope: .all, articleScope: .allDrafts, activeProfileID: profileID,
      inputs: [input], masksPrivateContent: false
    )
    search.update(
      query: "正文", scope: .resources, articleScope: .allDrafts, activeProfileID: profileID,
      inputs: [input], masksPrivateContent: false
    )
    try await Task.sleep(for: .milliseconds(30))

    let queries = await recorder.queries
    XCTAssertEqual(queries, [])
    XCTAssertTrue(search.snapshot.displayedHits.isEmpty)
    XCTAssertFalse(search.isSearching)
  }

  func testSupersededQueryAndScopeCannotPublishLateResults() async throws {
    let profileID = UUID()
    let otherProfileID = UUID()
    let gate = SearchGate()
    let oldHit = makeHit(title: "旧结果")
    let current = makeDraft(profileID: profileID, title: "当前", body: "新结果")
    let other = makeDraft(profileID: otherProfileID, title: "其他", body: "新结果")
    let inputs = [current, other].map {
      DraftFullTextSearchInput(draft: $0, bodyMarkdown: $0.bodyMarkdown)
    }
    let search = WorkspaceCommandPaletteArticleSearch(
      search: { query, drafts, limit in
        if query == "旧查询" {
          await gate.wait()
          return [oldHit]
        }
        return DraftFullTextSearchService().search(query: query, drafts: drafts, limit: limit)
      },
      debounce: { _ in }
    )

    search.update(
      query: "旧查询", scope: .articles, articleScope: .allDrafts, activeProfileID: profileID,
      inputs: inputs, masksPrivateContent: false
    )
    try await waitForGate(gate)
    search.update(
      query: "新结果", scope: .articles, articleScope: .currentSite, activeProfileID: profileID,
      inputs: inputs, masksPrivateContent: false
    )
    try await waitForCompletion(search)
    XCTAssertEqual(search.snapshot.displayedHits.map(\.draftID), [current.id])

    await gate.release()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(search.snapshot.displayedHits.map(\.draftID), [current.id])
  }

  func testCancelInvalidatesAnInFlightSearch() async throws {
    let profileID = UUID()
    let gate = SearchGate()
    let oldHit = makeHit(title: "取消前结果")
    let input = DraftFullTextSearchInput(
      draft: makeDraft(profileID: profileID, title: "文章", body: "正文"),
      bodyMarkdown: "正文"
    )
    let search = WorkspaceCommandPaletteArticleSearch(
      search: { _, _, _ in
        await gate.wait()
        return [oldHit]
      },
      debounce: { _ in }
    )

    search.update(
      query: "正文", scope: .articles, articleScope: .allDrafts, activeProfileID: profileID,
      inputs: [input], masksPrivateContent: false
    )
    try await waitForGate(gate)
    search.cancel()
    await gate.release()
    try await Task.sleep(for: .milliseconds(30))

    XCTAssertTrue(search.snapshot.displayedHits.isEmpty)
    XCTAssertFalse(search.isSearching)
  }

  private func makeImmediateSearch() -> WorkspaceCommandPaletteArticleSearch {
    WorkspaceCommandPaletteArticleSearch(debounce: { _ in })
  }

  private func makeDraft(profileID: UUID, title: String, body: String) -> ArticleDraft {
    ArticleDraft(siteProfileID: profileID, title: title, bodyMarkdown: body)
  }

  private func makeHit(title: String) -> DraftFullTextSearchHit {
    DraftFullTextSearchHit(
      draftID: UUID(),
      siteProfileID: UUID(),
      draftTitle: title,
      field: .body,
      sourceRange: NSRange(location: 0, length: 1),
      snippetPrefix: "",
      matchedText: title,
      snippetSuffix: "",
      updatedAt: .now,
      score: 1
    )
  }

  private func waitForCompletion(
    _ search: WorkspaceCommandPaletteArticleSearch,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 where search.isSearching {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(search.isSearching, "search did not finish", file: file, line: line)
  }

  private func waitForGate(
    _ gate: SearchGate,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if await gate.hasWaiter { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("search did not enter the gate", file: file, line: line)
  }
}

private actor SearchRecorder {
  private(set) var queries: [String] = []

  func record(_ query: String) {
    queries.append(query)
  }
}

private actor SearchGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  var hasWaiter: Bool { continuation != nil }

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
