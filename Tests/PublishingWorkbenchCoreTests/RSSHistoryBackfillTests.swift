import Foundation
import XCTest

@testable import PublishingKnowledgeCore

@MainActor
final class RSSHistoryBackfillTests: XCTestCase {
  func testDirectoryDiscoversOnlyExplicitSameOriginArticlesAndNextPages() throws {
    let html = """
      <html><head><link rel="canonical" href="/archive/" /></head><body>
      <a class="archive-item-link" href="/old/?edition=1#top">Old</a>
      <a class="post-link" href="/old/?edition=2">Different edition</a>
      <a rel="bookmark" href="https://elsewhere.example/other">Other site</a>
      <a href="/login">Account</a><a rel="next" href="?page=2">Next</a>
      </body></html>
      """
    let origin = url("/archive/")
    let page = try RSSHistoryDirectoryParser.parse(
      data: Data(html.utf8), responseURL: origin, origin: origin)
    XCTAssertEqual(page.articles.count, 2)
    XCTAssertEqual(page.nextPages, [url("/archive/?page=2")])
    XCTAssertEqual(page.canonicalURL, origin)
    XCTAssertNotEqual(
      RSSHistoryURLIdentity.key(page.articles[0].url),
      RSSHistoryURLIdentity.key(page.articles[1].url))
    XCTAssertNotEqual(
      RSSHistoryURLIdentity.key(url("//post")), RSSHistoryURLIdentity.key(url("/post")))
    XCTAssertNotEqual(
      RSSHistoryURLIdentity.key(url("/post/")), RSSHistoryURLIdentity.key(url("/post")))
  }

  func testNoArchiveAndNoFollowPreventDirectoryDiscovery() throws {
    for directive in ["noarchive", "nofollow", "none"] {
      let html =
        "<html><head><meta name='robots' content='\(directive)' /></head><body>\(directory([("/a", "A")]))</body></html>"
      let page = try RSSHistoryDirectoryParser.parse(
        data: Data(html.utf8), responseURL: url("/"), origin: url("/"))
      XCTAssertTrue(page.forbidsArchiving)
      XCTAssertTrue(page.articles.isEmpty)
    }
  }

  func testRobotsHonorsLongestRuleWildcardAndSpecificAgent() {
    let policy = RSSHistoryRobotsPolicy(
      text: """
        User-agent: *
        Disallow: /
        User-agent: RepoPress
        Disallow: /private/*
        Allow: /private/public$
        Crawl-delay: 3
        """)
    XCTAssertTrue(policy.allows(url("/archive")))
    XCTAssertFalse(policy.allows(url("/private/a")))
    XCTAssertTrue(policy.allows(url("/private/public")))
    XCTAssertFalse(policy.allows(url("/private/public/more")))
    XCTAssertEqual(policy.crawlDelay, 3)
  }

  func testBatchCheckpointResumesAfterReopeningWithoutDuplicates() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B"), ("/c", "C")], batchSize: 1)
    defer { fixture.cleanUp() }
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .paused)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.nextIndex, 1)
    let reopened = RSSReaderStore(fileURL: fixture.store.fileURL, userDefaults: fixture.defaults)
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    XCTAssertEqual(reopened.historyBackfillProgress?.nextIndex, 2)
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    let progress = try XCTUnwrap(reopened.historyBackfillProgress)
    XCTAssertEqual(progress.status, .completed)
    XCTAssertEqual(progress.addedCount, 3)
    XCTAssertEqual(progress.fullTextSuccessCount, 3)
    XCTAssertEqual(try reopened.database?.statistics().articleCount, 3)
    let count = await fixture.transport.count(url("/"))
    XCTAssertEqual(count, 1, "Resuming must use the persisted discovery queue")
  }

  func testExistingBodyLocalStateHighlightAndFeedValidatorsArePreserved() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let article = RSSArticle(
      id: "existing", feedID: fixture.feedID, title: "My local title", link: url("/a"),
      summaryHTML: "Local summary",
      contentHTML: String(repeating: "<p>My local edited full article.</p>", count: 100),
      readAt: Date(timeIntervalSince1970: 123), isStarred: true, tags: ["local"]
    )
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [article])
    _ = fixture.store.load()
    let highlight = try fixture.store.saveHighlight(
      articleID: article.id, text: "Saved quote", note: "Local annotation")
    let before = try fixture.store.database?.article(id: "existing")
    await fixture.run()
    XCTAssertEqual(try fixture.store.database?.article(id: "existing"), before)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.duplicateCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 1)
    XCTAssertEqual(fixture.store.feeds.first?.url, fixture.feed.url)
    XCTAssertEqual(fixture.store.highlights.first, highlight)
    let calls = await fixture.transport.count(url("/a"))
    XCTAssertEqual(calls, 0, "A complete existing body does not need another request")
  }

  func testReadyFullTextCacheIsNeverReplaced() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let article = RSSArticle(id: "existing", feedID: fixture.feedID, title: "A", link: url("/a"))
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [article])
    let record = RSSArticleFullTextRecord.ready(
      articleID: article.id, contentHTML: "<p>Preserved rich body</p>",
      plainText: "Preserved rich body", sourceURL: article.link, confidence: 1,
      attemptedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try fixture.store.saveFullTextRecord(record)
    _ = fixture.store.load()
    await fixture.run()
    XCTAssertEqual(try fixture.store.fullTextRecord(articleID: article.id), record)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.addedCount, 0)
  }

  func testCacheForFormerSourceDoesNotSuppressCurrentSourceExtraction() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let article = RSSArticle(id: "existing", feedID: fixture.feedID, title: "A", link: url("/a"))
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [article])
    try fixture.store.saveFullTextRecord(
      .ready(
        articleID: article.id, contentHTML: "<p>Old source body</p>", plainText: "Old source body",
        sourceURL: url("/former-source"), confidence: 1
      ))
    _ = fixture.store.load()
    await fixture.run()
    let calls = await fixture.transport.count(url("/a"))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(try fixture.store.fullTextRecord(articleID: article.id)?.sourceURL, article.link)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 1)
  }

  func testSlashVariantRequiresCanonicalEvidenceAndKeepsOriginalID() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let original = RSSArticle(
      id: "guid", feedID: fixture.feedID, title: "Edited local title", link: url("//a"),
      isStarred: true)
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [original])
    _ = fixture.store.load()
    await fixture.transport.set(url("//a"), .html(body("A", canonical: "/a")))
    await fixture.run()
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.duplicateCount, 1)
    XCTAssertEqual(try fixture.store.database?.article(id: "guid")?.link, url("//a"))
    XCTAssertEqual(try fixture.store.database?.article(id: "guid")?.isStarred, true)
  }

  func testSlashVariantWithoutEvidenceRemainsDistinct() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let original = RSSArticle(id: "guid", feedID: fixture.feedID, title: "A", link: url("//a"))
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [original])
    _ = fixture.store.load()
    await fixture.transport.set(url("//a"), .html(body("A")))
    await fixture.run()
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.addedCount, 1)
  }

  func testCancellationStopsUncommittedItemAndResumeKeepsSuccessfulResults() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/b"), .suspend)
    fixture.store.startHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    for _ in 0..<10_000 {
      if await fixture.transport.count(url("/b")) > 0 { break }
      await Task.yield()
    }
    XCTAssertEqual(fixture.store.historyBackfillProgress?.nextIndex, 1)
    fixture.store.cancelHistoryBackfill()
    await fixture.store.historyBackfillTask?.value
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .paused)
    await fixture.transport.set(url("/b"), .html(body("B")))
    await fixture.run()
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.addedCount, 2)
    let calls = await fixture.transport.count(url("/a"))
    XCTAssertEqual(calls, 1)
  }

  func testRateLimitPausesWithoutAdvancingAndHonorsRetryAfter() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B")])
    defer { fixture.cleanUp() }
    let retryAt = Date().addingTimeInterval(600)
    await fixture.transport.set(
      url("/b"), .issue(RSSFeedIssue.http(statusCode: 429, retryAt: retryAt)))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.nextIndex, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.retryAt, retryAt)
    await fixture.run()
    let calls = await fixture.transport.count(url("/b"))
    XCTAssertEqual(calls, 1)
  }

  func testMissingArticleIsPartialFailureAndCanBeRetried() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/a"), .status(404))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextFailureCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.failedIndices, [0])
    await fixture.transport.set(url("/a"), .html(body("A")))
    await fixture.store.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service, retryFailures: true)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.duplicateCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextFailureCount, 0)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 2)
  }

  func testPaginationCycleAndDuplicateLinksAreBounded() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/"), .html(directory([("/a", "A")], next: "/older")))
    await fixture.transport.set(
      url("/older"), .html(directory([("/a", "A"), ("/b", "B")], next: "/")))
    await fixture.transport.set(url("/b"), .html(body("B")))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.discoveredCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.visitedPages.count, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .completed)
    let calls = await fixture.transport.count(url("/"))
    XCTAssertEqual(calls, 1)
  }

  func testURLLimitReportsIncompleteCoverage() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B"), ("/c", "C")], maximumURLs: 2)
    defer { fixture.cleanUp() }
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.discoveredCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.reachedDiscoveryLimit, true)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 2)
  }

  func testUnavailableDirectoryDoesNotInventOrImportURLs() async throws {
    let fixture = try makeFixture(entries: [])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/"), .html("<html><a href='/login'>Sign in</a></html>"))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .unavailable)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 0)
  }

  func testRobotsDenyDirectoryPreventsAnyDirectoryRequest() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/robots.txt"), .html("User-agent: *\nDisallow: /"))
    await fixture.run()
    let calls = await fixture.transport.count(url("/"))
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 0)
  }

  func testCrossOriginDirectoryIsRejectedBeforeNetwork() async throws {
    let fixture = try makeFixture(entries: [])
    defer { fixture.cleanUp() }
    await fixture.store.runHistoryBackfill(
      feedID: fixture.feedID,
      directoryURL: try XCTUnwrap(URL(string: "https://elsewhere.example/")),
      service: fixture.service)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .unavailable)
    let calls = await fixture.transport.totalCount()
    XCTAssertEqual(calls, 0)
  }

  func testOpeningVersionSevenDefersCheckpointTableUntilExplicitBackfill() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    let article = RSSArticle(
      id: "before-migration", feedID: fixture.feedID, title: "Local article", link: url("/a"),
      contentHTML: "Original body", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
      isStarred: true)
    try fixture.store.database?.upsertFeedAndArticles(fixture.feed, articles: [article])
    try fixture.store.database?.withLock {
      try fixture.store.database?.executeUnlocked("DROP TABLE IF EXISTS rss_history_jobs;")
      try fixture.store.database?.executeUnlocked("PRAGMA user_version = 7;")
    }
    let reopened = RSSReaderStore(fileURL: fixture.store.fileURL, userDefaults: fixture.defaults)
    XCTAssertEqual(try reopened.database?.article(id: article.id), article)
    XCTAssertNil(try reopened.database?.historyBackfillProgress(feedID: fixture.feedID))
    XCTAssertEqual(try reopened.database?.scalarInt("PRAGMA user_version;"), 7)
    XCTAssertEqual(
      try reopened.database?.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'rss_history_jobs';"), 0)
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    XCTAssertEqual(reopened.historyBackfillProgress?.duplicateCount, 1)
    XCTAssertNotNil(try reopened.database?.historyBackfillProgress(feedID: fixture.feedID))
  }

  func testOversizedCheckpointCannotReplaceLastDurableProgress() throws {
    let fixture = try makeFixture(entries: [])
    defer { fixture.cleanUp() }
    let saved = RSSHistoryBackfillProgress(
      feedID: fixture.feedID, feedURL: fixture.feed.url, directoryURL: url("/"))
    try fixture.store.database?.saveHistoryBackfillProgress(saved)
    var oversized = saved
    oversized.candidates = (0..<500).map { index in
      RSSHistoryBackfillCandidate(
        url: url("/\(index)?q=\(String(repeating: "a", count: 5_000))"), title: "A")
    }
    XCTAssertThrowsError(try fixture.store.database?.saveHistoryBackfillProgress(oversized))
    XCTAssertEqual(
      try fixture.store.database?.historyBackfillProgress(feedID: fixture.feedID), saved)
  }

  func testUnavailableRobotsStopsBeforeReadingDirectory() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/robots.txt"), .issue(RSSFeedIssue.http(statusCode: 503)))
    await fixture.run()
    let calls = await fixture.transport.count(url("/"))
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .paused)
    XCTAssertNotNil(fixture.store.historyBackfillProgress?.retryAt)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 0)
  }

  func testSourceChangeDuringDownloadCannotSaveOldResult() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/a"), .delayedHTML(body("A")))
    fixture.store.startHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    for _ in 0..<200 {
      if await fixture.transport.count(url("/a")) > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try fixture.store.updateFeedURL(feedID: fixture.feedID, newURL: url("/new-feed.xml"))
    await fixture.store.historyBackfillTask?.value
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 0)
    XCTAssertEqual(fixture.store.feeds.first?.url, url("/new-feed.xml"))
  }

  func testNetworkScopeValidationRunsBeforeDNSOrConnection() async throws {
    var request = URLRequest(url: url("/private"))
    request.httpMethod = "GET"
    do {
      _ = try await RSSNetworkHTTPClient.data(
        for: request, maximumByteCount: 100, allowsPrivateNetworkAccess: false,
        resolver: { _ in
          XCTFail("Scope rejection must run before DNS")
          return []
        },
        additionalURLValidation: { _ in
          throw RSSHistoryBackfillError.unavailable("Denied by policy")
        }
      )
      XCTFail("Expected a scope rejection")
    } catch RSSHistoryBackfillError.unavailable(let reason) {
      XCTAssertEqual(reason, "Denied by policy")
    }
  }

  func testHugoArchiveAndBloggerPostHeadingsUsePublishedStructure() throws {
    let html = """
      <html><body><nav><a href='/cn/2020/01/nav/'>Navigation</a></nav>
      <div class='main archive'><ul><li><span>2020/01/01</span>
      <a href='/cn/2020/01/post/'>Archive title</a></li>
      <li><a href='https://other.example/post'>Other origin</a></li></ul></div>
      <article class='post'><a rel='bookmark' href='/2020/01/post.html'>January 1</a>
      <h3 class='post-title entry-title'><a href='/2020/01/post.html'>Published title</a></h3></article>
      <a class='blog-pager-older-link' href='/search?updated-max=2020'>Older posts</a>
      </body></html>
      """
    let page = try RSSHistoryDirectoryParser.parse(
      data: Data(html.utf8), responseURL: url("/"), origin: url("/"))
    XCTAssertEqual(page.articles.map(\.title), ["Archive title", "Published title"])
    XCTAssertTrue(page.nextPages.isEmpty, "A disallowed Blogger pager is not an alternative index")
  }

  func testSitemapNamespacesScopeIndicesAndUntrustedXML() throws {
    let xml = sitemap([
      "https://example.com/cn/2020/post/", "https://example.com/en/post/",
      "https://elsewhere.example/cn/post/", "https://example.com/cn/",
    ])
    let page = try RSSHistorySitemapParser.parse(
      data: Data(xml.utf8), responseURL: url("/sitemap.xml"), directoryURL: url("/cn/"))
    XCTAssertEqual(page.articles.map(\.url), [url("/cn/2020/post/")])
    XCTAssertEqual(
      page.articles.first?.title, "", "Titles must come from the article, not an index")
    let index = """
      <sitemapindex xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'>
      <sitemap><loc>https://example.com/part.xml</loc></sitemap>
      <sitemap><loc>https://other.example/part.xml</loc></sitemap></sitemapindex>
      """
    let indexed = try RSSHistorySitemapParser.parse(
      data: Data(index.utf8), responseURL: url("/sitemap.xml"), directoryURL: url("/"))
    XCTAssertEqual(indexed.nextPages, [url("/part.xml")])
    for invalid in [
      "<urlset><url><loc>https://example.com/a</loc></url></urlset>",
      "<!DOCTYPE urlset [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><urlset>&x;</urlset>",
    ] {
      XCTAssertThrowsError(
        try RSSHistorySitemapParser.parse(
          data: Data(invalid.utf8), responseURL: url("/sitemap.xml"), directoryURL: url("/")))
    }
  }

  func testAdvertisedAllowedSitemapFindsHistoryWithoutSearchOrCrossOriginRequests() async throws {
    let fixture = try makeFixture(entries: [])
    defer { fixture.cleanUp() }
    await fixture.transport.set(
      url("/robots.txt"),
      .html(
        """
        User-agent: *
        Disallow: /search
        Disallow: /private
        Allow: /
        Sitemap: https://example.com/sitemap.xml
        Sitemap: https://example.com/private/sitemap.xml
        Sitemap: https://other.example/sitemap.xml
        """))
    await fixture.transport.set(
      url("/"),
      .html(
        "<html><a class='blog-pager-older-link' href='/search'>More</a></html>"))
    await fixture.transport.set(
      url("/sitemap.xml"),
      .xml(
        sitemap([
          url("/2020/01/a.html").absoluteString, url("/private/a").absoluteString,
        ])))
    await fixture.transport.set(url("/2020/01/a.html"), .html(body("Actual article title")))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.addedCount, 1)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 1)
    XCTAssertEqual(
      try fixture.store.database?.articleHeaders().first?.title, "Actual article title")
    let calls = await fixture.transport.requestedURLs()
    XCTAssertFalse(
      calls.contains {
        $0.contains("/search") || $0.contains("/private") || $0.contains("other.example")
      })
  }

  func testMoreThanFiveHundredResumesAcrossSegmentsRestartCancellationAndFailureRetry() async throws
  {
    let entries = (1...505).map { ("/a\($0)", "Article \($0)") }
    let fixture = try makeFixture(entries: entries, batchSize: 50)
    defer { fixture.cleanUp() }
    await fixture.transport.set(url("/a2"), .status(404))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.candidates.count, 500)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.discoveryCursor?.articleOffset, 500)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.nextIndex, 50)
    await fixture.transport.set(url("/a51"), .suspend)
    fixture.store.startHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    for _ in 0..<10_000 {
      if await fixture.transport.count(url("/a51")) > 0 { break }
      await Task.yield()
    }
    fixture.store.cancelHistoryBackfill()
    await fixture.store.historyBackfillTask?.value
    XCTAssertEqual(fixture.store.historyBackfillProgress?.nextIndex, 50)
    await fixture.transport.set(url("/a51"), .html(body("Article 51")))
    let reopened = RSSReaderStore(fileURL: fixture.store.fileURL, userDefaults: fixture.defaults)
    for _ in 0..<10 {
      await reopened.runHistoryBackfill(
        feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
      XCTAssertLessThanOrEqual(reopened.historyBackfillProgress?.candidates.count ?? 0, 500)
    }
    var progress = try XCTUnwrap(reopened.historyBackfillProgress)
    XCTAssertEqual(progress.status, .completed)
    XCTAssertEqual(progress.discoveredCount, 505)
    XCTAssertEqual(progress.addedCount, 505)
    XCTAssertEqual(progress.fullTextSuccessCount, 504)
    XCTAssertEqual(progress.fullTextFailureCount, 1)
    XCTAssertEqual(try reopened.database?.statistics().articleCount, 505)
    XCTAssertEqual(
      try reopened.database?.historyFailedCandidates(progress).map(\.url), [url("/a2")])
    await fixture.transport.set(url("/a2"), .html(body("Article 2")))
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service, retryFailures: true)
    progress = try XCTUnwrap(reopened.historyBackfillProgress)
    XCTAssertEqual(progress.fullTextFailureCount, 0)
    XCTAssertEqual(progress.fullTextSuccessCount, 505)
    XCTAssertEqual(progress.discoveredCount, 505)
    XCTAssertEqual(try reopened.database?.statistics().articleCount, 505)
    for _ in 0..<11 {
      await reopened.runHistoryBackfill(
        feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service)
    }
    XCTAssertEqual(reopened.historyBackfillProgress?.addedCount, 0)
    XCTAssertEqual(reopened.historyBackfillProgress?.duplicateCount, 505)
    XCTAssertEqual(try reopened.database?.statistics().articleCount, 505)
  }

  func testChangedDirectoryStopsAtSavedCursorInsteadOfSkippingNewPrefix() async throws {
    let fixture = try makeFixture(entries: [("/a", "A"), ("/b", "B"), ("/c", "C")], maximumURLs: 2)
    defer { fixture.cleanUp() }
    await fixture.run()
    await fixture.transport.set(
      url("/"), .html(directory([("/new", "New"), ("/b", "B"), ("/c", "C")])))
    await fixture.run()
    XCTAssertEqual(fixture.store.historyBackfillProgress?.status, .unavailable)
    XCTAssertEqual(try fixture.store.database?.statistics().articleCount, 2)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.discoveryCursor?.articleOffset, 2)
  }

  func testFailureRetryRotatesPastFiveHundredPersistentFailuresAfterRestart() async throws {
    let fixture = try makeFixture(entries: [], batchSize: 50)
    defer { fixture.cleanUp() }
    var progress = RSSHistoryBackfillProgress(
      feedID: fixture.feedID, feedURL: fixture.feed.url, directoryURL: url("/"))
    progress.pendingPages = []
    progress.status = .completed
    for start in [0, 500] {
      progress.completedDiscoveryCount = start
      progress.candidates = (start..<min(start + 500, 505)).map {
        RSSHistoryBackfillCandidate(
          url: url("/a" + String(format: "%04d", $0)), title: "Article \($0)")
      }
      progress.nextIndex = progress.candidates.count
      progress.failedIndices = Array(progress.candidates.indices)
      progress.failureLedgerInitialized = nil
      progress.fullTextFailureCount = min(start + 500, 505)
      try fixture.store.database?.saveHistoryBackfillProgress(progress)
    }
    for index in 500..<505 {
      await fixture.transport.set(
        url("/a" + String(format: "%04d", index)), .html(body("Article \(index)")))
    }
    for _ in 0..<10 {
      await fixture.store.runHistoryBackfill(
        feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service,
        retryFailures: true)
      XCTAssertLessThanOrEqual(
        fixture.store.historyBackfillProgress?.candidates.count ?? 0, 500)
    }
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextFailureCount, 505)
    let reopened = RSSReaderStore(fileURL: fixture.store.fileURL, userDefaults: fixture.defaults)
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service, retryFailures: true)
    XCTAssertEqual(reopened.historyBackfillProgress?.candidates.count, 5)
    XCTAssertEqual(reopened.historyBackfillProgress?.fullTextFailureCount, 500)
    XCTAssertEqual(reopened.historyBackfillProgress?.fullTextSuccessCount, 5)
    XCTAssertEqual(reopened.historyBackfillProgress?.discoveredCount, 505)
    XCTAssertEqual(try reopened.database?.statistics().articleCount, 505)
    await reopened.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service, retryFailures: true)
    XCTAssertEqual(reopened.historyBackfillProgress?.candidates.first?.url, url("/a0000"))
    let firstAttempts = await fixture.transport.count(url("/a0000"))
    XCTAssertEqual(firstAttempts, 2, "Retry rotation wraps without losing persistent failures")
  }

  func testLegacyCheckpointWithoutNewFieldsRemainsReadable() throws {
    let fixture = try makeFixture(entries: [])
    defer { fixture.cleanUp() }
    let progress = RSSHistoryBackfillProgress(
      feedID: fixture.feedID, feedURL: fixture.feed.url, directoryURL: url("/"))
    let data = try JSONEncoder().encode(progress)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in [
      "discoveryCursor", "completedDiscoveryCount", "sitemapsLoaded", "retryingFailures",
      "failureLedgerInitialized",
      "failureRetryAfterURLKey",
    ] {
      json.removeValue(forKey: key)
    }
    let legacy = try JSONDecoder().decode(
      RSSHistoryBackfillProgress.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.discoveryCursor)
    XCTAssertEqual(legacy.discoveredCount, 0)
    XCTAssertNil(legacy.failureLedgerInitialized)
    XCTAssertNil(legacy.failureRetryAfterURLKey)
  }

  func testCapturedPublicDirectoryStructuresWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["RSS_HISTORY_PUBLIC_FIXTURE_DIR"] else {
      throw XCTSkip(
        "Read-only public capture not provided; structural fixtures run without networking")
    }
    let root = URL(fileURLWithPath: path)
    let yihui = URL(string: "https://yihui.org/cn/")!
    let archive = try RSSHistoryDirectoryParser.parse(
      data: Data(contentsOf: root.appendingPathComponent("yihui-archive.html")),
      responseURL: yihui, origin: yihui)
    XCTAssertGreaterThan(archive.articles.count, 1_000)
    XCTAssertTrue(
      archive.articles.allSatisfy { $0.url.host == "yihui.org" && $0.url.path.hasPrefix("/cn/") })
    let blogger = URL(string: "https://unclewaanginphuket.blogspot.com/")!
    let index = try RSSHistorySitemapParser.parse(
      data: Data(contentsOf: root.appendingPathComponent("blogger-sitemap.xml")),
      responseURL: blogger.appendingPathComponent("sitemap.xml"), directoryURL: blogger)
    XCTAssertGreaterThan(index.articles.count, 100)
    XCTAssertTrue(index.articles.allSatisfy { $0.url.host == blogger.host })
  }

  func testLegacyFailuresAreMigratedEvenWhenAnotherFeedCreatedTheLedger() async throws {
    let fixture = try makeFixture(entries: [("/a", "A")])
    defer { fixture.cleanUp() }
    var legacy = RSSHistoryBackfillProgress(
      feedID: fixture.feedID, feedURL: fixture.feed.url, directoryURL: url("/"))
    legacy.candidates = [RSSHistoryBackfillCandidate(url: url("/a"), title: "A")]
    legacy.nextIndex = 1
    legacy.failedIndices = [0]
    legacy.fullTextFailureCount = 1
    legacy.failureLedgerInitialized = nil
    legacy.pendingPages = []
    legacy.status = .completed
    // The table already exists, but this old checkpoint still has only indices.
    try fixture.store.database?.saveHistoryBackfillProgress(
      RSSHistoryBackfillProgress(
        feedID: fixture.feedID, feedURL: fixture.feed.url, directoryURL: url("/")))
    try fixture.store.database?.saveHistoryBackfillProgress(legacy)
    await fixture.store.runHistoryBackfill(
      feedID: fixture.feedID, directoryURL: url("/"), service: fixture.service, retryFailures: true)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextFailureCount, 0)
    XCTAssertEqual(fixture.store.historyBackfillProgress?.fullTextSuccessCount, 1)
  }

  private func sitemap(_ urls: [String]) -> String {
    "<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'>"
      + urls.map { "<url><loc>\($0)</loc></url>" }.joined() + "</urlset>"
  }

  private func makeFixture(
    entries: [(String, String)], batchSize: Int = 20, maximumURLs: Int = 500
  ) throws -> HistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RSSHistoryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "RSSHistoryTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = RSSReaderStore(
      fileURL: root.appendingPathComponent("reader.sqlite"), userDefaults: defaults)
    let feedID = try store.addFeed(url: url("/feed.xml"), title: "Author", siteURL: url("/"))
    var pages: [String: HistoryResponse] = [
      url("/robots.txt").absoluteString: .status(404),
      url("/").absoluteString: .html(directory(entries)),
    ]
    for (path, title) in entries { pages[url(path).absoluteString] = .html(body(title)) }
    let transport = HistoryTransport(pages: pages)
    let service = RSSHistoryBackfillService(
      limits: RSSHistoryBackfillLimits(
        maximumURLs: maximumURLs, batchSize: batchSize, requestDelay: 0),
      downloadOperation: { try await transport.download($0) }, waitOperation: { _ in }
    )
    return HistoryFixture(
      root: root, defaults: defaults, suite: suite, store: store, feedID: feedID, service: service,
      transport: transport)
  }

  private func url(_ path: String) -> URL { URL(string: "https://example.com" + path)! }

  private func directory(_ entries: [(String, String)], next: String? = nil) -> String {
    let links = entries.map {
      "<article><a class='archive-item-link' href='\($0.0)'>\($0.1)</a></article>"
    }.joined()
    return
      "<html><body>\(links)\(next.map { "<a rel='next' href='\($0)'>Next</a>" } ?? "")</body></html>"
  }

  private func body(_ title: String, canonical: String? = nil) -> String {
    let link = canonical.map { "<link rel='canonical' href='\($0)' />" } ?? ""
    return "<html><head><title>\(title)</title>\(link)</head><body><main><article><h1>\(title)</h1>"
      + String(
        repeating:
          "<p>This historical article describes a useful engineering observation in detail. It contains independent readable paragraphs and relevant context for the reader.</p>",
        count: 20)
      + "</article></main></body></html>"
  }
}

private enum HistoryResponse: Sendable {
  case html(String)
  case xml(String)
  case delayedHTML(String)
  case status(Int)
  case issue(RSSFeedIssue)
  case suspend
}

private actor HistoryTransport {
  var pages: [String: HistoryResponse]
  var calls: [String: Int] = [:]
  init(pages: [String: HistoryResponse]) { self.pages = pages }
  func set(_ url: URL, _ response: HistoryResponse) { pages[url.absoluteString] = response }
  func count(_ url: URL) -> Int { calls[url.absoluteString] ?? 0 }
  func totalCount() -> Int { calls.values.reduce(0, +) }
  func requestedURLs() -> [String] { Array(calls.keys) }
  func download(_ url: URL) async throws -> RSSArticlePageDownload {
    calls[url.absoluteString, default: 0] += 1
    guard let response = pages[url.absoluteString] else { throw RSSReaderError.httpStatus(404) }
    switch response {
    case .html(let html):
      return RSSArticlePageDownload(
        data: Data(html.utf8), sourceURL: url, resolvedURL: url, mimeType: "text/html")
    case .xml(let xml):
      return RSSArticlePageDownload(
        data: Data(xml.utf8), sourceURL: url, resolvedURL: url, mimeType: "application/atom+xml")
    case .delayedHTML(let html):
      try await Task.sleep(for: .milliseconds(100))
      return RSSArticlePageDownload(
        data: Data(html.utf8), sourceURL: url, resolvedURL: url, mimeType: "text/html")
    case .status(let status): throw RSSReaderError.httpStatus(status)
    case .issue(let issue): throw RSSReaderError.issue(issue)
    case .suspend:
      try await Task.sleep(for: .seconds(30))
      throw CancellationError()
    }
  }
}

@MainActor
private struct HistoryFixture {
  let root: URL
  let defaults: UserDefaults
  let suite: String
  let store: RSSReaderStore
  let feedID: UUID
  let service: RSSHistoryBackfillService
  let transport: HistoryTransport
  var feed: RSSFeed { store.feeds.first! }
  func run() async {
    await store.runHistoryBackfill(
      feedID: feedID, directoryURL: URL(string: "https://example.com/")!, service: service)
  }
  func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}
