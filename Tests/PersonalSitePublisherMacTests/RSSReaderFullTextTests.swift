import Combine
import Foundation
import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class RSSReaderFullTextTests: XCTestCase {
  func testPresentationStateFullTextToggling() async {
    let state = RSSReaderPresentationState()
    let article = RSSArticle(
      id: "art-test-toggle",
      feedID: UUID(),
      title: "测试文章",
      link: URL(string: "https://example.com/art-1"),
      summaryHTML: "<p>截断摘要</p>",
      contentHTML: ""
    )

    XCTAssertTrue(state.isTruncatedCandidate(article))
    XCTAssertFalse(state.isShowingFullText(for: article.id))
    XCTAssertFalse(state.isFetchingFullText(for: article.id))

    // Inject a cached full-text article
    let fullText = RSSArticle(
      id: article.id,
      feedID: article.feedID,
      title: article.title,
      link: article.link,
      summaryHTML: article.summaryHTML,
      contentHTML: "<p>完整正文内容已经成功提取完毕。</p>"
    )
    state.fullTextArticles[article.id] = fullText

    state.toggleFullText(for: article)
    XCTAssertTrue(state.isShowingFullText(for: article.id))

    let effective = state.effectiveArticle(for: article)
    XCTAssertEqual(effective.contentHTML, "<p>完整正文内容已经成功提取完毕。</p>")

    // Toggle back to summary
    state.toggleFullText(for: article)
    XCTAssertFalse(state.isShowingFullText(for: article.id))

    let fallback = state.effectiveArticle(for: article)
    XCTAssertEqual(fallback.contentHTML, "")
  }

  func testUserPreferencesDefaults() {
    let suiteName = "test-rss-user-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabled(defaults: defaults))
    XCTAssertFalse(RSSReaderUserPreferences.automaticFullTextExtractionEnabled(defaults: defaults))

    defaults.set(true, forKey: RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabledKey)
    defaults.set(true, forKey: RSSReaderUserPreferences.automaticFullTextExtractionEnabledKey)

    XCTAssertTrue(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabled(defaults: defaults))
    XCTAssertTrue(RSSReaderUserPreferences.automaticFullTextExtractionEnabled(defaults: defaults))
  }
}
