#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  import Foundation
  import PublishingKnowledgeCore
  import PublishingWorkbenchCore

  /// Opt-in offline transport for native UI acceptance. Real URLs never use it.
  enum RSSHistoryBackfillUIFixture {
    static func service(for directoryURL: URL) -> RSSHistoryBackfillService? {
      let environment = ProcessInfo.processInfo.environment
      guard ScreenshotDemoDataService.isEnabledFromEnvironment,
        environment[ScreenshotDemoDataService.uiTestEnvironmentKey] == "1",
        environment["PERSONAL_SITE_PUBLISHER_RSS_HISTORY_UI_FIXTURE"] == "1",
        directoryURL.scheme == "https", directoryURL.host == "demo.example.com"
      else { return nil }
      if isLargeFixture {
        return RSSHistoryBackfillService(
          downloadOperation: download,
          waitOperation: { _ in try await Task.sleep(for: .milliseconds(20)) })
      }
      return RSSHistoryBackfillService(downloadOperation: download)
    }

    private static var isLargeFixture: Bool {
      ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_RSS_HISTORY_LARGE_UI_FIXTURE"]
        == "1"
    }

    @MainActor
    static func prepareLargeFixtureIfNeeded(store: RSSReaderStore, feed: RSSFeed) {
      guard isLargeFixture, let siteURL = feed.siteURL, service(for: siteURL) != nil,
        store.articleHeaders.filter({ $0.feedID == feed.id }).count <= 1
      else { return }
      let articles = (1...500).map { number in
        RSSParsedArticle(
          id: number == 1 ? "repopress-ui-test-rss-article" : "history-fixture-\(number)",
          title: "History UI article \(number)", link: siteURL.appendingPathComponent(path(number)),
          author: "Offline fixture", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
          summaryHTML: "<p>Offline fixture article.</p>",
          contentHTML: body("History UI article \(number)"))
      }
      store.loadPreviewFeed(
        url: feed.url, title: feed.title, siteURL: siteURL,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), articles: articles)
    }

    private static func path(_ number: Int) -> String {
      number == 1 ? "posts/repopress-studio" : "history/article-\(number)"
    }

    private static func download(_ url: URL) async throws -> RSSArticlePageDownload {
      try Task.checkCancellation()
      guard url.scheme == "https", url.host == "demo.example.com" else {
        throw RSSReaderError.httpStatus(404)
      }
      let html: String
      switch url.path {
      case "/robots.txt":
        html =
          "User-agent: RepoPress\nAllow: /\nCrawl-delay: 1\n"
          + (isLargeFixture
            ? "Disallow: /search\nSitemap: https://demo.example.com/sitemap.xml\n" : "")
      case "", "/":
        html = isLargeFixture ? archive() : directory(1...12, next: "/history/page-2")
      case "/sitemap.xml":
        guard isLargeFixture else { throw RSSReaderError.httpStatus(404) }
        html =
          "<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'>"
          + (506...507).map { "<url><loc>https://demo.example.com/\(path($0))</loc></url>" }
          .joined()
          + "</urlset>"
      case "/history/page-2":
        html = directory(13...25, next: nil)
      case "/posts/repopress-studio":
        html = body("RepoPress Studio 发布工作流")
      default:
        guard url.path.hasPrefix("/history/article-"),
          let number = Int(url.lastPathComponent.replacingOccurrences(of: "article-", with: "")),
          (2...(isLargeFixture ? 507 : 25)).contains(number)
        else { throw RSSReaderError.httpStatus(404) }
        if isLargeFixture, number == 503 { try await Task.sleep(for: .seconds(8)) }
        if isLargeFixture, number == 504 { throw RSSReaderError.httpStatus(404) }
        html = body("History UI article \(number)")
      }
      return RSSArticlePageDownload(
        data: Data(html.utf8), sourceURL: url, resolvedURL: url,
        mimeType: url.path == "/sitemap.xml" ? "application/atom+xml" : "text/html")
    }

    private static func archive() -> String {
      "<html><body><div class='main archive'><ul>"
        + (1...505).map {
          "<li><span>2020/01/01</span><a href='/\(path($0))'>History UI article \($0)</a></li>"
        }.joined()
        + "</ul></div><a class='blog-pager-older-link' href='/search'>Older posts</a></body></html>"
    }

    private static func directory(_ numbers: ClosedRange<Int>, next: String?) -> String {
      let articles = numbers.map { number in
        let path = number == 1 ? "/posts/repopress-studio" : "/history/article-\(number)"
        let title = number == 1 ? "RepoPress Studio 发布工作流" : "History UI article \(number)"
        return "<a class='archive-item-link' href='\(path)'>\(title)</a>"
      }.joined()
      let pagination = next.map { "<a rel='next' href='\($0)'>Next</a>" } ?? ""
      return "<html><body>\(articles)\(pagination)</body></html>"
    }

    private static func body(_ title: String) -> String {
      "<html><head><title>\(title)</title></head><body><main><article><h1>\(title)</h1>"
        + String(
          repeating:
            "<p>This historical article describes a useful engineering observation in detail. It contains independent readable paragraphs and relevant context for the reader.</p>",
          count: 20)
        + "</article></main></body></html>"
    }
  }
#endif
