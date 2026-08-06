import Foundation
import SQLite3
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class RSSReaderTests: XCTestCase {
  func testParsesRSS2WithContentEncodedAndResolvesArticleLinks() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/feeds/main.xml"))
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>示例博客</title>
          <link>https://example.com/</link>
          <item>
            <title>第一篇文章</title>
            <link>/posts/first</link>
            <guid>post-1</guid>
            <pubDate>Sun, 02 Aug 2026 12:00:00 GMT</pubDate>
            <description><![CDATA[<p>摘要 <em>文本</em></p>]]></description>
            <content:encoded><![CDATA[<p>完整 <strong>正文</strong>。</p><script>不要执行</script>]]></content:encoded>
          </item>
        </channel>
      </rss>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(feed.title, "示例博客")
    XCTAssertEqual(feed.siteURL?.absoluteString, "https://example.com/")
    let article = try XCTUnwrap(feed.articles.first)
    XCTAssertEqual(article.id, "post-1")
    XCTAssertEqual(article.title, "第一篇文章")
    XCTAssertEqual(article.link?.absoluteString, "https://example.com/posts/first")
    XCTAssertTrue(article.contentHTML.contains("完整"))
    XCTAssertTrue(RSSHTMLTextSanitizer.plainText(from: article.contentHTML).contains("完整"))
    XCTAssertFalse(RSSHTMLTextSanitizer.plainText(from: article.contentHTML).contains("不要执行"))
  }

  func testParsesArticleCoverFromMediaThumbnailAndEnclosure() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/feeds/main.xml"))
    let xml = """
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
        <channel>
          <title>封面订阅</title>
          <item>
            <guid>media-cover</guid>
            <title>媒体封面</title>
            <media:thumbnail url="/images/thumbnail.jpg"/>
          </item>
          <item>
            <guid>enclosure-cover</guid>
            <title>附件封面</title>
            <enclosure url="https://cdn.example.com/cover.png" type="image/png"/>
          </item>
        </channel>
      </rss>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(
      feed.articles.first(where: { $0.id == "media-cover" })?.coverURL?.absoluteString,
      "https://example.com/images/thumbnail.jpg"
    )
    XCTAssertEqual(
      feed.articles.first(where: { $0.id == "enclosure-cover" })?.coverURL?.absoluteString,
      "https://cdn.example.com/cover.png"
    )
  }

  func testCoverResolverPrefersSocialImageAndResolvesRelativeFeedImage() throws {
    let pageURL = try XCTUnwrap(URL(string: "https://example.com/posts/one"))

    let coverURL = RSSArticleCoverResolver.coverURL(
      summaryHTML: #"<p><img src="/inline.jpg"></p>"#,
      contentHTML: "",
      webPageSnapshotHTML: #"<meta property="og:image" content="/social.jpg?size=large&amp;format=webp">"#,
      relativeTo: pageURL
    )

    XCTAssertEqual(
      coverURL?.absoluteString,
      "https://example.com/social.jpg?size=large&format=webp"
    )
  }

  func testCoverResolverFallsBackToFirstInlineImage() throws {
    let pageURL = try XCTUnwrap(URL(string: "https://example.com/posts/one"))

    let coverURL = RSSArticleCoverResolver.coverURL(
      summaryHTML: "<p>摘要</p>",
      contentHTML: #"<p><img data-src="/images/inline.webp" alt="封面"></p>"#,
      relativeTo: pageURL
    )

    XCTAssertEqual(
      coverURL?.absoluteString,
      "https://example.com/images/inline.webp"
    )
  }

  func testParsesRSS2CoreElementsInFeedSpecificDefaultNamespace() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/namespaced-rss.xml"))
    let xml = """
      <rss xmlns="https://example.com/rss2" version="2.0">
        <channel>
          <title>Namespaced RSS</title>
          <item>
            <guid>namespaced-item</guid>
            <title>兼容文章</title>
            <description><![CDATA[<p>兼容正文</p>]]></description>
          </item>
        </channel>
      </rss>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(feed.title, "Namespaced RSS")
    XCTAssertEqual(feed.articles.first?.id, "namespaced-item")
    XCTAssertEqual(feed.articles.first?.summaryHTML, "<p>兼容正文</p>")
  }

  func testLongHTMLUsesBoundedPreviewSanitizer() {
    let source = String(
      repeating: "<p>正文 &amp; &#x4E2D;&#25991; <script>不应出现</script></p>",
      count: 160
    )

    let preview = RSSHTMLTextSanitizer.previewText(from: source)

    XCTAssertTrue(preview.contains("正文 & 中文"))
    XCTAssertFalse(preview.contains("不应出现"))
  }

  func testParsesAtomEntryAndUsesAlternateLink() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom 日志</title>
        <link rel="self" href="https://example.com/atom.xml"/>
        <link rel="alternate" href="https://example.com/"/>
        <entry>
          <id>tag:example.com,2026:entry-1</id>
          <title>Atom 文章</title>
          <updated>2026-08-02T13:30:00Z</updated>
          <author><name>作者</name></author>
          <link rel="alternate" href="/posts/atom"/>
          <summary type="html"><![CDATA[<p>Atom 摘要</p>]]></summary>
          <content type="html"><![CDATA[<p>Atom 正文</p>]]></content>
        </entry>
      </feed>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(feed.title, "Atom 日志")
    XCTAssertEqual(feed.siteURL?.absoluteString, "https://example.com/")
    let article = try XCTUnwrap(feed.articles.first)
    XCTAssertEqual(article.id, "tag:example.com,2026:entry-1")
    XCTAssertEqual(article.link?.absoluteString, "https://example.com/posts/atom")
    XCTAssertEqual(article.author, "作者")
    XCTAssertEqual(article.contentHTML, "<p>Atom 正文</p>")
  }

  func testAtomEntryIgnoresNestedSourceFieldsAndUsesAuthorNameOnly() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let xml = """
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom Source Isolation</title>
        <entry>
          <source>
            <id>nested-source-id</id>
            <title>错误的来源标题</title>
            <updated>2001-01-01T00:00:00Z</updated>
            <author><name>错误的来源作者</name></author>
            <link rel="alternate" href="/wrong-source-link"/>
            <summary>错误的来源摘要</summary>
            <content>错误的来源正文</content>
          </source>
          <id>direct-entry-id</id>
          <title>正确的文章标题</title>
          <updated>2026-08-04T10:00:00Z</updated>
          <author>
            <name>正确作者</name>
            <email>should-not-be-part-of-author@example.com</email>
          </author>
          <link rel="alternate" href="/correct-entry-link"/>
          <summary type="html"><![CDATA[<p>正确摘要</p>]]></summary>
          <content type="html"><![CDATA[<p>正确正文</p>]]></content>
        </entry>
      </feed>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)
    let article = try XCTUnwrap(feed.articles.first)

    XCTAssertEqual(article.id, "direct-entry-id")
    XCTAssertEqual(article.title, "正确的文章标题")
    XCTAssertEqual(article.link?.absoluteString, "https://example.com/correct-entry-link")
    XCTAssertEqual(article.author, "正确作者")
    XCTAssertEqual(article.summaryHTML, "<p>正确摘要</p>")
    XCTAssertEqual(article.contentHTML, "<p>正确正文</p>")
    XCTAssertEqual(
      Calendar(identifier: .gregorian).component(
        .year,
        from: try XCTUnwrap(article.publishedAt)
      ),
      2026
    )
  }

  func testMediaRSSFieldsDoNotOverrideCoreArticleFields() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    let xml = """
      <rss version="2.0"
           xmlns:content="http://purl.org/rss/1.0/modules/content/"
           xmlns:media="http://search.yahoo.com/mrss/">
        <channel>
          <title>核心订阅标题</title>
          <item>
            <title>核心文章标题</title>
            <guid>namespace-collision</guid>
            <description><![CDATA[<p>核心摘要</p>]]></description>
            <content:encoded><![CDATA[<p>完整正文</p>]]></content:encoded>
            <media:title>媒体标题不应覆盖</media:title>
            <media:description>媒体描述不应覆盖</media:description>
            <media:content url="https://cdn.example.com/video.mp4"/>
          </item>
        </channel>
      </rss>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)
    let article = try XCTUnwrap(feed.articles.first)

    XCTAssertEqual(article.title, "核心文章标题")
    XCTAssertEqual(article.summaryHTML, "<p>核心摘要</p>")
    XCTAssertEqual(article.contentHTML, "<p>完整正文</p>")
  }

  func testRSSCoreFieldsIgnoreNestedSameNamespaceElements() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    let xml = """
      <rss version="2.0">
        <channel>
          <title>Nested field isolation</title>
          <item>
            <container>
              <title>错误的嵌套标题</title>
              <link>https://example.com/wrong</link>
              <description>错误的嵌套摘要</description>
            </container>
            <guid>direct-rss-id</guid>
            <title>正确的文章标题</title>
            <link>https://example.com/correct</link>
            <description><![CDATA[<p>正确摘要</p>]]></description>
          </item>
        </channel>
      </rss>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)
    let article = try XCTUnwrap(feed.articles.first)

    XCTAssertEqual(article.id, "direct-rss-id")
    XCTAssertEqual(article.title, "正确的文章标题")
    XCTAssertEqual(article.link?.absoluteString, "https://example.com/correct")
    XCTAssertEqual(article.summaryHTML, "<p>正确摘要</p>")
  }

  func testParsesPrefixedAtomXHTMLContentAndPreservesInnerMarkup() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let xml = """
      <atom:feed xmlns:atom="http://www.w3.org/2005/Atom"
                 xmlns:xhtml="http://www.w3.org/1999/xhtml">
        <atom:title>Atom XHTML</atom:title>
        <atom:entry>
          <atom:id>xhtml-entry</atom:id>
          <atom:title>文章标题</atom:title>
          <atom:content type="xhtml">
            <xhtml:div>
              <xhtml:p>正文 <xhtml:a href="https://example.com/source">来源</xhtml:a></xhtml:p>
              <xhtml:img src="https://cdn.example.com/image.jpg" alt="配图"/>
              <xhtml:title>正文内标题</xhtml:title>
            </xhtml:div>
          </atom:content>
        </atom:entry>
      </atom:feed>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)
    let article = try XCTUnwrap(feed.articles.first)

    XCTAssertEqual(feed.title, "Atom XHTML")
    XCTAssertEqual(article.title, "文章标题")
    XCTAssertTrue(article.contentHTML.contains("<p>正文 <a href=\"https://example.com/source\">来源</a></p>"))
    XCTAssertTrue(article.contentHTML.contains("<img alt=\"配图\" src=\"https://cdn.example.com/image.jpg\">"))
    XCTAssertTrue(article.contentHTML.contains("<title>正文内标题</title>"))
    XCTAssertFalse(article.contentHTML.contains("<div"))
  }

  func testParsesAtomXMLMediaTypesAsMarkupWithoutStrippingTheirRoot() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let xml = """
      <feed xmlns="http://www.w3.org/2005/Atom"
            xmlns:xhtml="http://www.w3.org/1999/xhtml"
            xmlns:example="urn:example:payload">
        <title>Atom XML Content</title>
        <entry>
          <id>application-xhtml</id>
          <title>Application XHTML</title>
          <content type="application/xhtml+xml; charset=utf-8"><xhtml:article><xhtml:p>XHTML XML 正文</xhtml:p></xhtml:article></content>
        </entry>
        <entry>
          <id>vendor-xml</id>
          <title>Vendor XML</title>
          <content type="application/vnd.example+xml"><example:payload><example:message>扩展 XML 正文</example:message></example:payload></content>
        </entry>
      </feed>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(
      feed.articles.first(where: { $0.id == "application-xhtml" })?.contentHTML,
      "<article><p>XHTML XML 正文</p></article>"
    )
    XCTAssertEqual(
      feed.articles.first(where: { $0.id == "vendor-xml" })?.contentHTML,
      "<payload><message>扩展 XML 正文</message></payload>"
    )
  }

  func testParsesDirectXHTMLBodyAsCompatibilityFallback() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let xml = """
      <feed xmlns="http://www.w3.org/2005/Atom"
            xmlns:xhtml="http://www.w3.org/1999/xhtml">
        <title>Compatibility</title>
        <entry>
          <id>xhtml-body-entry</id>
          <title>Body fallback</title>
          <xhtml:body><xhtml:div class="body-shell"><xhtml:p>兼容正文</xhtml:p></xhtml:div></xhtml:body>
        </entry>
      </feed>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)

    XCTAssertEqual(
      feed.articles.first?.contentHTML,
      "<div class=\"body-shell\"><p>兼容正文</p></div>"
    )
  }

  func testParsesRSS1WithDCAndContentModuleFields() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/rdf.xml"))
    let xml = """
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
               xmlns="http://purl.org/rss/1.0/"
               xmlns:dc="http://purl.org/dc/elements/1.1/"
               xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel rdf:about="https://example.com/rdf.xml">
          <title>RSS 1.0</title>
          <link>https://example.com/</link>
        </channel>
        <item rdf:about="https://example.com/posts/rdf">
          <title>RDF 文章</title>
          <link>https://example.com/posts/rdf</link>
          <dc:creator>RDF 作者</dc:creator>
          <dc:date>2026-08-03T08:00:00Z</dc:date>
          <content:encoded><![CDATA[<p>RDF 正文</p>]]></content:encoded>
        </item>
      </rdf:RDF>
      """

    let feed = try RSSFeedParser.parse(data: Data(xml.utf8), feedURL: feedURL)
    let article = try XCTUnwrap(feed.articles.first)

    XCTAssertEqual(feed.title, "RSS 1.0")
    XCTAssertEqual(article.title, "RDF 文章")
    XCTAssertEqual(article.author, "RDF 作者")
    XCTAssertNotNil(article.publishedAt)
    XCTAssertEqual(article.contentHTML, "<p>RDF 正文</p>")
  }

  func testReaderStorePersistsSubscriptionsReadStateAndStarredState() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let article = RSSArticle(
      id: "article-1",
      feedID: feedID,
      title: "本地缓存文章",
      coverURL: try XCTUnwrap(URL(string: "https://cdn.example.com/cover.jpg")),
      summaryHTML: "<p>摘要</p>",
      contentHTML: "<p>正文</p>"
    )
    let feed = RSSFeed(
      id: feedID,
      title: "本地订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let snapshot = RSSReaderSnapshot(feeds: [feed], articles: [article])
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let store = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(store.feeds.count, 1)
    XCTAssertEqual(store.articleHeaders(for: .feed(feedID)).map(\.id), ["article-1"])
    XCTAssertEqual(store.unreadCount, 1)

    store.markRead("article-1")
    store.toggleStarred("article-1")

    let reopened = RSSReaderStore(fileURL: fileURL)
    let reopenedArticle = try XCTUnwrap(reopened.articleHeaders.first)
    XCTAssertTrue(reopenedArticle.isRead)
    XCTAssertTrue(reopenedArticle.isStarred)
    XCTAssertEqual(
      reopenedArticle.coverURL?.absoluteString,
      "https://cdn.example.com/cover.jpg"
    )
    XCTAssertEqual(reopened.articleHeaders(for: .unread).count, 0)
    XCTAssertEqual(reopened.articleHeaders(for: .starred).count, 1)
  }

  func testLegacyJSONMigratesToSQLiteAndKeepsJSONBackup() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderMigrationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let feed = RSSFeed(
      id: feedID,
      title: "迁移测试",
      url: try XCTUnwrap(URL(string: "https://example.com/migration.xml"))
    )
    let article = RSSArticle(
      id: "migration-article",
      feedID: feedID,
      title: "SQLite 全文索引",
      summaryHTML: "迁移摘要",
      contentHTML: "迁移正文"
    )
    try writeSnapshot(RSSReaderSnapshot(feeds: [feed], articles: [article]), to: fileURL)

    let store = RSSReaderStore(fileURL: fileURL)

    XCTAssertEqual(store.articleHeaders.first?.id, article.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: RSSReaderStore.databaseFileURL(for: fileURL).path
      )
    )
    XCTAssertTrue(store.statusMessage?.contains("迁移") == true)
  }

  func testReusedGUIDGetsLinkSpecificStorageIDAndPreservesOldArticleState() throws {
    let rootURL = temporaryDirectory(named: "rss-guid-collision")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let firstURL = try XCTUnwrap(URL(string: "https://example.com/posts/first"))
    let secondURL = try XCTUnwrap(URL(string: "https://example.com/posts/second"))
    let store = RSSReaderStore(fileURL: fileURL)
    let feedID = try store.addFeed(
      url: try XCTUnwrap(URL(string: "https://example.com/collision.xml")),
      title: "GUID 冲突"
    )
    let feed = try XCTUnwrap(store.feeds.first { $0.id == feedID })

    store.merge([
      RSSParsedArticle(
        id: "reused-guid",
        title: "旧文章",
        link: firstURL,
        contentHTML: "旧正文"
      )
    ], into: feed)
    let originalID = "\(feedID.uuidString):reused-guid"
    store.markRead(originalID)
    store.toggleStarred(originalID)
    store.setArticleTags(["旧标签"], for: originalID)

    store.merge([
      RSSParsedArticle(
        id: "reused-guid",
        title: "旧文章",
        link: firstURL,
        contentHTML: "旧正文"
      ),
      RSSParsedArticle(
        id: "reused-guid",
        title: "新文章",
        link: secondURL,
        contentHTML: "新正文"
      )
    ], into: feed)

    XCTAssertEqual(store.articleHeaders.count, 2)
    let original = try XCTUnwrap(store.articleHeaders.first { $0.link == firstURL })
    let replacement = try XCTUnwrap(store.articleHeaders.first { $0.link == secondURL })
    XCTAssertEqual(original.id, originalID)
    XCTAssertTrue(original.isRead)
    XCTAssertTrue(original.isStarred)
    XCTAssertEqual(original.tags, ["旧标签"])
    XCTAssertNotEqual(replacement.id, originalID)
    XCTAssertFalse(replacement.isRead)
    XCTAssertFalse(replacement.isStarred)
    XCTAssertTrue(replacement.id.contains(":link-"))

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(Set(reopened.articleHeaders.map(\.id)), Set([original.id, replacement.id]))
  }

  func testSQLiteHeaderQueryOmitsHTMLPayloadUntilArticleIsLoaded() throws {
    let rootURL = temporaryDirectory(named: "rss-header-payload-split")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "轻量列表",
      url: try XCTUnwrap(URL(string: "https://example.com/header.xml"))
    )
    let fullPayload = "<article>\(String(repeating: "full-payload-marker-", count: 2_000))</article>"
    let article = RSSArticle(
      id: "header-payload-article",
      feedID: feed.id,
      title: "正文按需读取",
      summaryHTML: "<p>列表摘要 <strong>无 HTML 标签</strong></p><script>不可见</script>",
      contentHTML: fullPayload,
      tags: ["性能"]
    )
    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([article])

    let header = try XCTUnwrap(database.articleHeaders().first)
    XCTAssertEqual(header.id, article.id)
    XCTAssertEqual(header.readableSummary, "列表摘要 无 HTML 标签")
    XCTAssertFalse(header.readableSummary.contains("<"))
    XCTAssertFalse(header.readableSummary.contains("不可见"))
    let encodedHeader = String(decoding: try JSONEncoder().encode(header), as: UTF8.self)
    XCTAssertFalse(encodedHeader.contains("summaryHTML"))
    XCTAssertFalse(encodedHeader.contains("contentHTML"))
    XCTAssertFalse(encodedHeader.contains("full-payload-marker"))

    let loadedArticle = try XCTUnwrap(database.article(id: article.id))
    XCTAssertEqual(loadedArticle.summaryHTML, article.summaryHTML)
    XCTAssertEqual(loadedArticle.contentHTML, fullPayload)
  }

  func testSQLiteHeaderPreviewFallsBackToContentWhenSummaryIsMissing() throws {
    let rootURL = temporaryDirectory(named: "rss-header-content-preview")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "正文摘要回退",
      url: try XCTUnwrap(URL(string: "https://example.com/content-preview.xml"))
    )
    let article = RSSArticle(
      id: "content-preview-article",
      feedID: feed.id,
      title: "使用正文作为摘要",
      summaryHTML: "",
      contentHTML: "<p>正文也应显示为列表摘要。</p>"
    )
    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([article])

    let header = try XCTUnwrap(database.articleHeaders().first)
    XCTAssertEqual(header.readableSummary, "正文也应显示为列表摘要。")
  }

  func testInMemoryArticleHeaderBoundsLargeHTMLPreview() throws {
    let feedID = UUID()
    let article = RSSArticle(
      id: "large-preview",
      feedID: feedID,
      title: "大摘要",
      summaryHTML: "<p>\(String(repeating: "preview-marker ", count: 20_000))</p>",
      contentHTML: "<p>正文</p>"
    )

    let header = RSSArticleHeader(article: article)

    XCTAssertLessThanOrEqual(header.readableSummary.count, 1_001)
    XCTAssertTrue(header.readableSummary.contains("preview-marker"))
  }

  func testReaderStoreLazyPayloadCacheIsBoundedAndKeepsHeaderStateInSync() async throws {
    let rootURL = temporaryDirectory(named: "rss-lazy-payload-cache")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "LRU 测试",
      url: try XCTUnwrap(URL(string: "https://example.com/lru.xml"))
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles((0..<18).map { index in
        RSSArticle(
          id: "lazy-\(index)",
          feedID: feed.id,
          title: "文章 \(index)",
          summaryHTML: "摘要 \(index)",
          contentHTML: "<p>payload-\(index)-marker</p>",
          fetchedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
        )
      })
    }

    let store = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(store.articleHeaders.count, 18)
    XCTAssertEqual(store.cachedArticleCount, 0)

    for index in 0..<18 {
      let article = try await store.loadArticle(id: "lazy-\(index)")
      XCTAssertEqual(article?.contentHTML, "<p>payload-\(index)-marker</p>")
    }
    XCTAssertEqual(store.cachedArticleCount, RSSReaderStore.articlePayloadCacheCapacity)
    XCTAssertFalse(store.cachedArticleIDs.contains("lazy-0"))
    XCTAssertFalse(store.cachedArticleIDs.contains("lazy-1"))
    XCTAssertTrue(store.cachedArticleIDs.contains("lazy-2"))
    XCTAssertTrue(store.cachedArticleIDs.contains("lazy-17"))

    _ = try await store.loadArticle(id: "lazy-2")
    _ = try await store.loadArticle(id: "lazy-0")
    XCTAssertEqual(store.cachedArticleCount, RSSReaderStore.articlePayloadCacheCapacity)
    XCTAssertTrue(store.cachedArticleIDs.contains("lazy-2"))
    XCTAssertFalse(store.cachedArticleIDs.contains("lazy-3"))

    store.markRead("lazy-0")
    store.toggleStarred("lazy-0")
    store.setArticleTags(["缓存", "缓存", "本地"], for: "lazy-0")
    let updatedHeader = try XCTUnwrap(store.articleHeader(id: "lazy-0"))
    XCTAssertTrue(updatedHeader.isRead)
    XCTAssertTrue(updatedHeader.isStarred)
    XCTAssertEqual(updatedHeader.tags, ["缓存", "本地"])
    let updatedArticle = try await store.loadArticle(id: "lazy-0")
    XCTAssertEqual(updatedArticle?.contentHTML, "<p>payload-0-marker</p>")
    XCTAssertTrue(updatedArticle?.isRead == true)
    XCTAssertTrue(updatedArticle?.isStarred == true)
    XCTAssertEqual(updatedArticle?.tags, ["缓存", "本地"])
  }

  func testRSSArticleQueryPlansUseScopeAndOrderIndexesWithoutLegacyReadIndex() throws {
    let rootURL = temporaryDirectory(named: "rss-article-indexes")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "索引测试",
      url: try XCTUnwrap(URL(string: "https://example.com/index.xml"))
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([
        RSSArticle(id: "indexed", feedID: feed.id, title: "已建索引")
      ])
    }

    XCTAssertEqual(
      try querySQLiteText(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'rss_articles_scope_idx';",
        at: fileURL
      ),
      "1"
    )
    XCTAssertEqual(
      try querySQLiteText(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'rss_articles_order_idx';",
        at: fileURL
      ),
      "1"
    )
    XCTAssertEqual(
      try querySQLiteText(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'rss_articles_read_idx';",
        at: fileURL
      ),
      "0"
    )

    let scopePlan = try querySQLitePlanDetails(
      """
      EXPLAIN QUERY PLAN
      SELECT id FROM rss_articles
      WHERE feed_id = '\(feed.id.uuidString)' AND read_at IS NULL AND is_starred = 0
      ORDER BY published_at DESC, fetched_at DESC;
      """,
      at: fileURL
    )
    XCTAssertTrue(
      scopePlan.contains { $0.contains("rss_articles_scope_idx") },
      "应使用 scope 复合索引，实际计划：\(scopePlan)"
    )

    let orderPlan = try querySQLitePlanDetails(
      """
      EXPLAIN QUERY PLAN
      SELECT id FROM rss_articles
      ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC;
      """,
      at: fileURL
    )
    XCTAssertTrue(
      orderPlan.contains { $0.contains("rss_articles_order_idx") },
      "应使用全局顺序索引，实际计划：\(orderPlan)"
    )
  }

  func testSQLiteSearchTagsAndHighlightsRoundTrip() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feedID = try RSSReaderStore(fileURL: fileURL).addFeed(
      url: try XCTUnwrap(URL(string: "https://example.com/sqlite.xml")),
      title: "SQLite 测试"
    )
    let store = RSSReaderStore(fileURL: fileURL)
    let feed = try XCTUnwrap(store.feeds.first { $0.id == feedID })
    store.merge([
      RSSParsedArticle(
        id: "fts-1",
        title: "FTS 标题",
        summaryHTML: "普通摘要",
        contentHTML: "全文索引命中正文"
      )
    ], into: feed)
    let article = try XCTUnwrap(store.articleHeaders.first)
    store.setArticleTags(["阅读", "阅读", "资料"], for: article.id)
    let highlight = try store.saveHighlight(
      articleID: article.id,
      text: "全文索引命中正文",
      note: "后续写作素材",
      tags: ["资料"]
    )

    XCTAssertEqual(store.articleHeaders(for: .all, searchText: "全文索引").map(\.id), [article.id])
    XCTAssertEqual(store.articleHeaders.first?.tags, ["阅读", "资料"])
    XCTAssertEqual(store.highlights(for: article.id).first?.id, highlight.id)

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "全文索引").map(\.id), [article.id])
    XCTAssertEqual(reopened.articleHeaders.first?.tags, ["阅读", "资料"])
    XCTAssertEqual(reopened.highlights(for: article.id).first?.note, "后续写作素材")
  }

  func testAsyncSQLiteSearchReturnsFTSMatches() async throws {
    let rootURL = temporaryDirectory(named: "rss-async-search")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let store = RSSReaderStore(fileURL: fileURL)
    let feedID = try store.addFeed(
      url: try XCTUnwrap(URL(string: "https://example.com/async-search.xml")),
      title: "后台搜索测试"
    )
    let feed = try XCTUnwrap(store.feeds.first { $0.id == feedID })
    store.merge([
      RSSParsedArticle(
        id: "async-fts-1",
        title: "后台 FTS 标题",
        summaryHTML: "摘要",
        contentHTML: "后台查询命中的正文"
      )
    ], into: feed)
    let articleID = try XCTUnwrap(store.articleHeaders.first?.id)

    let result = await store.articleHeadersAsync(
      for: .all,
      searchText: "后台查询"
    )

    XCTAssertEqual(result.map(\.id), [articleID])
  }

  func testRSSBackupCreatesValidatedSingleFileSnapshotFromLiveWALDatabase() throws {
    let rootURL = temporaryDirectory(named: "rss-backup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("reader.sqlite")
    let backupURL = rootURL.appendingPathComponent("backup.sqlite")
    let store = try populatedRSSStore(at: sourceURL)
    let service = RSSReaderBackupService()

    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: sourceURL), "wal")
    let inspection = try withExtendedLifetime(store) {
      try service.createBackup(from: sourceURL, at: backupURL)
    }

    XCTAssertEqual(inspection.databaseSchemaVersion, RSSReaderDatabase.currentSchemaVersion)
    XCTAssertEqual(inspection.feedCount, 1)
    XCTAssertEqual(inspection.articleCount, 1)
    XCTAssertEqual(inspection.highlightCount, 1)
    XCTAssertEqual(inspection.indexedArticleCount, 1)
    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: backupURL), "delete")
    XCTAssertEqual(
      try querySQLiteText("SELECT note FROM rss_article_highlights LIMIT 1;", at: backupURL),
      "后续写作素材"
    )
    XCTAssertEqual(
      try querySQLiteText("SELECT tags_json FROM rss_articles LIMIT 1;", at: backupURL),
      "[\"阅读\",\"资料\"]"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-shm"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-journal"))
    XCTAssertEqual(try service.inspectBackup(at: backupURL), inspection)
  }

  func testRSSBackupInspectionRejectsForeignKeyCorruption() throws {
    let rootURL = temporaryDirectory(named: "rss-backup-foreign-key")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let backupURL = try validRSSBackup(in: rootURL)
    try executeSQLite("PRAGMA foreign_keys = OFF; DELETE FROM rss_feeds;", at: backupURL)

    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: backupURL)) { error in
      guard case .databaseIntegrity(let detail)? = error as? RSSReaderBackupError else {
        return XCTFail("应报告 RSS 外键完整性错误，实际为：\(error)")
      }
      XCTAssertTrue(detail.contains("外键"))
    }
  }

  func testRSSBackupInspectionRejectsSchemaAndSearchIndexCountMismatch() throws {
    let rootURL = temporaryDirectory(named: "rss-backup-schema")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let backupURL = try validRSSBackup(in: rootURL)
    let futureURL = rootURL.appendingPathComponent("future.sqlite")
    let missingIndexURL = rootURL.appendingPathComponent("missing-index.sqlite")
    try FileManager.default.copyItem(at: backupURL, to: futureURL)
    try FileManager.default.copyItem(at: backupURL, to: missingIndexURL)

    let futureVersion = RSSReaderDatabase.currentSchemaVersion + 1
    try executeSQLite("PRAGMA user_version = \(futureVersion);", at: futureURL)
    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: futureURL)) { error in
      guard case .unsupportedDatabaseVersion(let found, let supported)? =
        error as? RSSReaderBackupError else {
        return XCTFail("应报告 RSS 数据库版本不兼容，实际为：\(error)")
      }
      XCTAssertEqual(found, futureVersion)
      XCTAssertEqual(supported, RSSReaderDatabase.currentSchemaVersion)
    }

    try executeSQLite("DELETE FROM rss_articles_fts;", at: missingIndexURL)
    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: missingIndexURL)) { error in
      guard case .databaseIntegrity(let detail)? = error as? RSSReaderBackupError else {
        return XCTFail("应报告 RSS 全文索引计数错误，实际为：\(error)")
      }
      XCTAssertTrue(detail.contains("全文索引"))
    }
  }

  func testRSSBackupInspectionRejectsCorruptOrMultiFileBackup() throws {
    let rootURL = temporaryDirectory(named: "rss-backup-corruption")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let backupURL = try validRSSBackup(in: rootURL)
    let sidecarURL = URL(fileURLWithPath: backupURL.path + "-wal")
    try Data("unexpected sidecar".utf8).write(to: sidecarURL, options: .atomic)

    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: backupURL)) { error in
      guard case .databaseIntegrity(let detail)? = error as? RSSReaderBackupError else {
        return XCTFail("应报告 RSS 单文件备份错误，实际为：\(error)")
      }
      XCTAssertTrue(detail.contains("单文件"))
    }

    try FileManager.default.removeItem(at: sidecarURL)
    try Data(repeating: 0xA5, count: 4_096).write(to: backupURL, options: .atomic)
    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: backupURL))
  }

  func testFeedHealthReportsBackoffBeforeFailure() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/health.xml"))
    let now = Date()
    let healthy = RSSFeed(title: "健康", url: url, lastUpdatedAt: now)
    XCTAssertEqual(healthy.healthStatus(now: now), .healthy)

    let failing = RSSFeed(title: "失败", url: url, lastError: "网络错误", refreshFailureCount: 1)
    XCTAssertEqual(failing.healthStatus(now: now), .failing)

    let backingOff = RSSFeed(
      title: "退避",
      url: url,
      lastError: "网络错误",
      refreshFailureCount: 2,
      nextRetryAt: now.addingTimeInterval(60)
    )
    XCTAssertEqual(backingOff.healthStatus(now: now), .backingOff)
    XCTAssertEqual(backingOff.healthStatus(now: now.addingTimeInterval(61)), .failing)
  }

  func testAddingTheSameFeedIsIdempotentAndRejectsUnsupportedSchemes() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = RSSReaderStore(fileURL: fileURL)
    let url = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))

    let firstID = try store.addFeed(url: url)
    let secondID = try store.addFeed(url: url)

    XCTAssertEqual(firstID, secondID)
    XCTAssertEqual(store.feeds.count, 1)
    XCTAssertThrowsError(
      try store.addFeed(url: try XCTUnwrap(URL(string: "ftp://example.com/feed.xml")))
    ) { error in
      XCTAssertEqual(error as? RSSReaderError, .unsupportedFeedURL)
    }
  }

  func testMarkAllReadCanBeScopedToVisibleSearchResults() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let feed = RSSFeed(
      id: feedID,
      title: "搜索测试",
      url: try XCTUnwrap(URL(string: "https://example.com/search.xml"))
    )
    let matching = RSSArticle(
      id: "matching",
      feedID: feedID,
      title: "命中关键词",
      summaryHTML: "关键词"
    )
    let other = RSSArticle(
      id: "other",
      feedID: feedID,
      title: "其他文章",
      summaryHTML: "完全不同的内容"
    )
    try writeSnapshot(RSSReaderSnapshot(feeds: [feed], articles: [matching, other]), to: fileURL)

    let store = RSSReaderStore(fileURL: fileURL)
    let visibleIDs = Set(store.articleHeaders(for: .all, searchText: "命中").map(\.id))
    XCTAssertEqual(visibleIDs, ["matching"])
    XCTAssertEqual(store.markAllRead(articleIDs: visibleIDs), 1)
    XCTAssertTrue(store.articleHeaders.first { $0.id == "matching" }?.isRead == true)
    XCTAssertFalse(store.articleHeaders.first { $0.id == "other" }?.isRead == true)
  }

  func testDeletingFeedCanBeUndoneWithCachedStarredArticles() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let feed = RSSFeed(
      id: feedID,
      title: "可撤销订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/undo.xml"))
    )
    let article = RSSArticle(
      id: "undo-article",
      feedID: feedID,
      title: "收藏文章",
      isStarred: true
    )
    try writeSnapshot(RSSReaderSnapshot(feeds: [feed], articles: [article]), to: fileURL)

    let store = RSSReaderStore(fileURL: fileURL)
    store.removeFeed(id: feedID)
    XCTAssertTrue(store.feeds.isEmpty)
    XCTAssertTrue(store.articleHeaders.isEmpty)
    XCTAssertTrue(store.canUndoLastDeletion)

    store.undoLastDeletion()
    XCTAssertEqual(store.feeds.map(\.id), [feedID])
    XCTAssertTrue(store.articleHeaders.first?.isStarred == true)
    XCTAssertFalse(store.canUndoLastDeletion)
  }

  func testStarredArticlesBeyondRetentionWindowAreKept() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let feed = RSSFeed(
      id: feedID,
      title: "收藏保留",
      url: try XCTUnwrap(URL(string: "https://example.com/retention.xml"))
    )
    let articles = (0..<501).map { index in
      RSSArticle(
        id: "\(feedID.uuidString):old-\(index)",
        feedID: feedID,
        title: "文章 \(index)",
        publishedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        isStarred: index == 0
      )
    }
    try writeSnapshot(RSSReaderSnapshot(feeds: [feed], articles: articles), to: fileURL)

    let store = RSSReaderStore(fileURL: fileURL)
    store.merge([], into: feed)

    XCTAssertEqual(store.articleHeaders.count, 501)
    XCTAssertTrue(store.articleHeaders.contains { $0.id.hasSuffix("old-0") && $0.isStarred })
  }

  func testHighlightedArticlesBeyondRetentionWindowAreKept() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderHighlightRetentionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feedID = UUID()
    let feed = RSSFeed(
      id: feedID,
      title: "高亮保留",
      url: try XCTUnwrap(URL(string: "https://example.com/highlight-retention.xml"))
    )
    let oldestArticleID = "\(feedID.uuidString):old-0"
    let articles = (0..<501).map { index in
      RSSArticle(
        id: "\(feedID.uuidString):old-\(index)",
        feedID: feedID,
        title: "文章 \(index)",
        publishedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let highlight = RSSArticleHighlight(
      articleID: oldestArticleID,
      text: "这条高亮不应被清理",
      note: "需要长期保留"
    )
    try writeSnapshot(
      RSSReaderSnapshot(feeds: [feed], articles: articles, highlights: [highlight]),
      to: fileURL
    )

    let store = RSSReaderStore(fileURL: fileURL)
    store.merge([], into: feed)

    XCTAssertEqual(store.articleHeaders.count, 501)
    XCTAssertTrue(store.articleHeaders.contains { $0.id == oldestArticleID })
    XCTAssertEqual(store.highlights(for: oldestArticleID).map(\.id), [highlight.id])
  }

  func testParsesOPMLAndDiscoversAlternateRSSLinks() throws {
    let opml = """
      <?xml version="1.0"?>
      <opml version="2.0"><body>
        <outline text="博客" type="rss" xmlUrl="https://example.com/feed.xml" htmlUrl="https://example.com/"/>
        <outline text="重复" type="rss" xmlUrl="https://example.com/feed.xml"/>
        <outline text="不支持" type="rss" xmlUrl="ftp://example.com/feed.xml"/>
      </body></opml>
      """
    let subscriptions = try RSSOPMLParser.parse(data: Data(opml.utf8))
    XCTAssertEqual(subscriptions.count, 1)
    XCTAssertEqual(subscriptions.first?.title, "博客")

    let html = """
      <html><head>
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        <link rel="alternate" type="application/atom+xml" href="https://example.com/atom.xml">
      </head></html>
      """
    let baseURL = try XCTUnwrap(URL(string: "https://example.com/blog/") )
    XCTAssertEqual(
      RSSFeedDiscoveryService.feedURLs(in: html, relativeTo: baseURL).map(\.absoluteString),
      ["https://example.com/feed.xml", "https://example.com/atom.xml"]
    )

    let ordinaryPageHTML = """
      <a href="/feeds/news.xml">News</a>
      <a href="/rss.xml#latest">RSS</a>
      <a href="/feeds/news.xml">Duplicate</a>
      """
    XCTAssertEqual(
      RSSFeedDiscoveryService.feedURLs(in: ordinaryPageHTML, relativeTo: baseURL).map(\.absoluteString),
      ["https://example.com/feeds/news.xml", "https://example.com/rss.xml"]
    )
  }

  func testWritesOPMLAndRoundTripsSubscriptionMetadata() throws {
    let feedURL = try XCTUnwrap(
      URL(string: "https://example.com/feed.xml?source=one&format=rss")
    )
    let siteURL = try XCTUnwrap(URL(string: "https://example.com/blog?a=1&b=2"))
    let subscriptions = [
      RSSOPMLSubscription(title: "A & <RSS> \"精选\"", url: feedURL, siteURL: siteURL)
    ]

    let data = try RSSOPMLWriter.makeDocument(
      subscriptions: subscriptions,
      title: "我的 RSS & 阅读列表",
      privacyAction: .redactCredentialQueryValues
    )
    let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(xml.contains("<opml version=\"2.0\">"))
    XCTAssertTrue(xml.contains("我的 RSS &amp; 阅读列表"))
    XCTAssertTrue(xml.contains("A &amp; &lt;RSS&gt; &quot;精选&quot;"))
    XCTAssertTrue(xml.contains("source=one&amp;format=rss"))
    XCTAssertTrue(xml.contains("htmlUrl=\"https://example.com/blog?a=1&amp;b=2\""))
    XCTAssertEqual(try RSSOPMLParser.parse(data: data), subscriptions)
  }

  func testOPMLWriterDeduplicatesFeedsAndRejectsUnsupportedURLs() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    let duplicateData = try RSSOPMLWriter.makeDocument(
      subscriptions: [
        RSSOPMLSubscription(title: "第一个名称", url: url),
        RSSOPMLSubscription(title: "第二个名称", url: url)
      ],
      privacyAction: .redactCredentialQueryValues
    )
    let duplicateXML = try XCTUnwrap(String(data: duplicateData, encoding: .utf8))
    XCTAssertEqual(duplicateXML.components(separatedBy: "<outline ").count - 1, 1)

    let fileURL = try XCTUnwrap(URL(string: "file:///tmp/feed.xml"))
    XCTAssertThrowsError(
      try RSSOPMLWriter.makeDocument(
        subscriptions: [RSSOPMLSubscription(title: "本地文件", url: fileURL)],
        privacyAction: .redactCredentialQueryValues
      )
    ) { error in
      XCTAssertEqual(
        error as? RSSReaderError,
        .invalidOPML("无法导出订阅：地址必须是包含站点域名的 http 或 https URL。")
      )
    }

    XCTAssertThrowsError(
      try RSSOPMLWriter.makeDocument(
        subscriptions: [],
        privacyAction: .redactCredentialQueryValues
      )
    ) { error in
      XCTAssertEqual(error as? RSSReaderError, .noOPMLFeeds)
    }
  }

  func testOPMLParserRejectsOversizedDocuments() {
    let data = Data(repeating: 0x20, count: 5 * 1024 * 1024 + 1)

    XCTAssertThrowsError(try RSSOPMLParser.parse(data: data)) { error in
      XCTAssertEqual(error as? RSSReaderError, .invalidOPML("文件超过 5 MB"))
    }
  }

  func testFeedBodyOfflineCachePolicyDefaultsAndPersists() throws {
    let suiteName = "RSSReaderTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let fileURL = temporaryDirectory(named: "rss-offline-cache-default")
      .appendingPathComponent("reader.sqlite")

    let store = RSSReaderStore(fileURL: fileURL, userDefaults: defaults)
    XCTAssertTrue(store.feedBodyOfflineCacheEnabled)

    store.updateFeedBodyOfflineCacheSettings(enabled: false)
    let reopened = RSSReaderStore(fileURL: fileURL, userDefaults: defaults)

    XCTAssertFalse(reopened.feedBodyOfflineCacheEnabled)
  }

  func testLegacyOfflineCachePreferenceMigratesOnlyToFeedBodyPolicy() throws {
    let suiteName = "RSSReaderTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: RSSReaderStore.automaticOfflineCacheDefaultsKey)
    let fileURL = temporaryDirectory(named: "rss-offline-cache-migration")
      .appendingPathComponent("reader.sqlite")

    let store = RSSReaderStore(fileURL: fileURL, userDefaults: defaults)

    XCTAssertFalse(store.feedBodyOfflineCacheEnabled)
  }

  func testDisablingAutomaticOfflineCacheKeepsMetadataAndCanRefillBodyLater() async throws {
    let suiteName = "RSSReaderTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let rootURL = temporaryDirectory(named: "rss-offline-cache-refresh")
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/offline.xml"))
    let articleURL = try XCTUnwrap(URL(string: "https://example.com/posts/offline"))
    let fetchResult = RSSFeedFetchResult(
      parsedFeed: RSSParsedFeed(
        title: "离线测试订阅",
        articles: [
          RSSParsedArticle(
            id: "offline-article",
            title: "离线测试文章",
            link: articleURL,
            summaryHTML: "<p>文章摘要</p>",
            contentHTML: "<p>完整离线正文</p>"
          )
        ]
      ),
      responseURL: feedURL,
      etag: "offline-etag",
      lastModified: nil,
      notModified: false
    )
    let store = RSSReaderStore(
      fileURL: fileURL,
      fetchOperation: { _, _, _ in fetchResult },
      userDefaults: defaults
    )
    let feedID = try store.addFeed(url: feedURL)
    store.updateFeedBodyOfflineCacheSettings(enabled: false)

    await store.refresh(feedID: feedID)

    let articleID = "\(feedID.uuidString):offline-article"
    let uncachedResult = try await store.loadArticle(id: articleID)
    let uncached = try XCTUnwrap(uncachedResult)
    XCTAssertEqual(uncached.contentHTML, "")
    XCTAssertTrue(uncached.readableSummary.contains("文章摘要"))

    store.updateFeedBodyOfflineCacheSettings(enabled: true)
    await store.refresh(feedID: feedID)

    let cachedResult = try await store.loadArticle(id: articleID)
    let cached = try XCTUnwrap(cachedResult)
    XCTAssertEqual(cached.contentHTML, "<p>完整离线正文</p>")
  }

  func testOPMLSettingsFlowExportsCurrentSubscriptions() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "当前订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/current.xml")),
      siteURL: try XCTUnwrap(URL(string: "https://example.com/"))
    )
    try writeSnapshot(RSSReaderSnapshot(feeds: [feed], articles: []), to: fileURL)

    let store = RSSReaderStore(fileURL: fileURL)
    let subscriptions = try RSSOPMLParser.parse(
      data: RSSOPMLWriter.makeDocument(
        subscriptions: store.feeds.map {
          RSSOPMLSubscription(title: $0.displayTitle, url: $0.url, siteURL: $0.siteURL)
        },
        privacyAction: .redactCredentialQueryValues
      )
    )

    XCTAssertEqual(
      subscriptions,
      [RSSOPMLSubscription(title: "当前订阅", url: feed.url, siteURL: feed.siteURL)]
    )
  }

  private func writeSnapshot(_ snapshot: RSSReaderSnapshot, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
  }

  private func populatedRSSStore(at fileURL: URL) throws -> RSSReaderStore {
    let store = RSSReaderStore(fileURL: fileURL)
    let feedID = try store.addFeed(
      url: try XCTUnwrap(URL(string: "https://example.com/backup.xml")),
      title: "备份测试"
    )
    let feed = try XCTUnwrap(store.feeds.first { $0.id == feedID })
    store.merge([
      RSSParsedArticle(
        id: "backup-article",
        title: "备份文章",
        link: try XCTUnwrap(URL(string: "https://example.com/posts/backup")),
        summaryHTML: "备份摘要",
        contentHTML: "备份正文"
      )
    ], into: feed)
    let article = try XCTUnwrap(store.articleHeaders.first)
    store.setArticleTags(["阅读", "资料"], for: article.id)
    _ = try store.saveHighlight(
      articleID: article.id,
      text: "备份正文",
      note: "后续写作素材",
      tags: ["资料"]
    )
    return store
  }

  private func validRSSBackup(in rootURL: URL) throws -> URL {
    let sourceURL = rootURL.appendingPathComponent("reader.sqlite")
    let backupURL = rootURL.appendingPathComponent("backup.sqlite")
    let store = try populatedRSSStore(at: sourceURL)
    _ = try withExtendedLifetime(store) {
      try RSSReaderBackupService().createBackup(from: sourceURL, at: backupURL)
    }
    return backupURL
  }

  private func temporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func executeSQLite(_ sql: String, at fileURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK,
      let handle else {
      defer { if let handle { sqlite3_close(handle) } }
      throw sqliteTestError(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
    }
    defer { sqlite3_close(handle) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw sqliteTestError(message)
    }
  }

  private func querySQLiteText(_ sql: String, at fileURL: URL) throws -> String {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK,
      let handle else {
      defer { if let handle { sqlite3_close(handle) } }
      throw sqliteTestError(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteTestError(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
      throw sqliteTestError(String(cString: sqlite3_errmsg(handle)))
    }
    return String(cString: value)
  }

  private func querySQLitePlanDetails(_ sql: String, at fileURL: URL) throws -> [String] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK,
      let handle else {
      defer { if let handle { sqlite3_close(handle) } }
      throw sqliteTestError(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteTestError(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    var details: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let value = sqlite3_column_text(statement, 3) {
        details.append(String(cString: value))
      }
    }
    return details
  }

  private func sqliteTestError(_ message: String) -> NSError {
    NSError(
      domain: "RSSReaderTests.SQLite",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
