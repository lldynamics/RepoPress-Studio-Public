import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceContentSearchNavigationTests: XCTestCase {
  func testResultWaitsForDismissalAndOriginalWindowThenDeliversOnlyOnce() {
    var state = WorkspaceDeferredContentSearchRequest()
    state.enqueue(.rss(articleID: "hit", query: "needle"))
    XCTAssertNil(state.consume(isKeyWindow: true))
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: false))
    guard case .rss(let articleID, let query) = state.consume(isKeyWindow: true) else {
      return XCTFail("Expected the original search destination")
    }
    XCTAssertEqual(articleID, "hit")
    XCTAssertEqual(query, "needle")
    XCTAssertNil(state.consume(isKeyWindow: true))

    state.enqueue(.rss(articleID: "private-hit", query: "private"))
    state.cancel()
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: true))
  }

  @MainActor
  func testRSSHitOutsideCurrentFilterOpensWithoutReplacingFilters() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ContentSearchNavigation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("rss.json")
    let feed = RSSFeed(
      title: "Feed", url: try XCTUnwrap(URL(string: "https://example.com/feed.xml")))
    let article = RSSArticle(id: "hit", feedID: feed.id, title: "Found", author: "Alice")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(RSSReaderSnapshot(feeds: [feed], articles: [article])).write(to: file)
    let store = RSSReaderStore(fileURL: file)
    let presentation = RSSReaderPresentationState()
    presentation.selectedAuthor = "Bob"
    presentation.debouncedSearchText = "other query"

    XCTAssertTrue(presentation.openContentSearchResult(article.id, in: store))
    presentation.synchronizeSelection(in: store)
    XCTAssertEqual(presentation.selectedArticleID, article.id)
    XCTAssertEqual(presentation.selectedAuthor, "Bob")
    XCTAssertEqual(presentation.debouncedSearchText, "other query")
    XCTAssertTrue(presentation.isSelectedArticleOutsideMatchingResults(in: store))
    XCTAssertTrue(presentation.showingFullTextIDs.contains(article.id))
    XCTAssertFalse(presentation.openContentSearchResult("deleted", in: store))
    XCTAssertEqual(presentation.selectedArticleID, article.id)
    presentation.returnToArticleResults()
    presentation.selectedArticleID = article.id
    presentation.synchronizeSelection(in: store)
    XCTAssertNil(presentation.selectedArticleID)
  }
}
