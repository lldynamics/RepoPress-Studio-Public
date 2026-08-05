import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSArticleHTMLRendererTests: XCTestCase {
  func testRenderedArticleUsesCenteredGoldenReadingColumn() {
    let article = RSSArticle(
      id: "golden-reading-column",
      feedID: UUID(),
      title: "舒适阅读",
      contentHTML: "<p>正文列应在大屏下保持稳定宽度，并使用舒适行高。</p>"
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(rendered.contains("max-width: 780px"))
    XCTAssertTrue(rendered.contains("margin: 0 auto"))
    XCTAssertTrue(rendered.contains("line-height: var(--rss-line-spacing)"))
    XCTAssertTrue(rendered.contains("--rss-line-spacing: 1.65"))
  }

  func testRenderedArticleKeepsHeaderAndBodyInOneScrollableDocument() {
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let article = RSSArticle(
      id: "unified-document",
      feedID: UUID(),
      title: "标题 <需要转义>",
      author: "作者",
      publishedAt: publishedAt,
      contentHTML: "<p>正文第一段</p>"
    )

    let rendered = RSSArticleHTMLRenderer.render(
      article: article,
      feedTitle: "我的订阅",
      readingMinutes: 3,
      allowRemoteImages: false
    )

    XCTAssertTrue(rendered.contains("<article id=\"rss-article-container\">"))
    XCTAssertTrue(rendered.contains("<header class=\"rss-article-header\">"))
    XCTAssertTrue(rendered.contains("<main id=\"rss-article-body\">"))
    XCTAssertTrue(rendered.contains("标题 &lt;需要转义&gt;"))
    XCTAssertTrue(rendered.contains("我的订阅"))
    XCTAssertTrue(rendered.contains("作者"))
    XCTAssertTrue(rendered.contains("约 3 分钟读完"))
    XCTAssertLessThan(
      rendered.range(of: "<header class=\"rss-article-header\">")!.lowerBound,
      rendered.range(of: "<main id=\"rss-article-body\">")!.lowerBound
    )
  }

  func testHasRenderableBodyRejectsOnlyNonRenderableMarkup() {
    let feedID = UUID()
    let articles = [
      RSSArticle(id: "blank", feedID: feedID, title: "Blank", contentHTML: "  \n  "),
      RSSArticle(
        id: "blocked",
        feedID: feedID,
        title: "Blocked",
        contentHTML: "<script>alert(1)</script><style>body { display: none }</style>"
      ),
      RSSArticle(
        id: "structure-only",
        feedID: feedID,
        title: "Structure",
        contentHTML: "<div><br></div>"
      ),
    ]

    for article in articles {
      XCTAssertFalse(
        RSSArticleHTMLRenderer.hasRenderableBody(article: article),
        "Expected \(article.id) to remain an empty-body state"
      )
    }
  }

  func testRenderableBodyFallsBackToSafeSummary() {
    let article = RSSArticle(
      id: "summary-fallback",
      feedID: UUID(),
      title: "Summary fallback",
      summaryHTML: "<p>摘要正文</p>",
      contentHTML: "<script>alert(1)</script>"
    )

    XCTAssertTrue(RSSArticleHTMLRenderer.hasRenderableBody(article: article))
    XCTAssertTrue(
      RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)
        .contains("<p>摘要正文</p>")
    )
  }

  func testMalformedDangerousBlockCannotSuppressSafeSummary() {
    let article = RSSArticle(
      id: "truncated-script",
      feedID: UUID(),
      title: "Fallback",
      summaryHTML: "<p>这是一段安全的中文摘要，应当被正常显示。</p>",
      contentHTML: "<script>alert('truncated')"
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(RSSArticleHTMLRenderer.hasRenderableBody(article: article))
    XCTAssertTrue(rendered.contains("这是一段安全的中文摘要"))
    XCTAssertTrue(rendered.contains("<html lang=\"zh-CN\">"))
    XCTAssertFalse(rendered.contains("alert('truncated')"))
  }

  func testSelfClosingDangerousTagDoesNotConsumeFollowingBody() {
    let article = RSSArticle(
      id: "self-closing-iframe",
      feedID: UUID(),
      title: "Self-closing iframe",
      contentHTML: "<iframe src=\"https://embed.invalid\"/><p>自闭合标签后的正文必须保留。</p>"
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(RSSArticleHTMLRenderer.hasRenderableBody(article: article))
    XCTAssertTrue(rendered.contains("<p>自闭合标签后的正文必须保留。</p>"))
    XCTAssertFalse(rendered.contains("<iframe"))
  }

  func testAttributeSanitizerDoesNotPromoteNestedOrDataAttributes() throws {
    let article = RSSArticle(
      id: "attribute-boundaries",
      feedID: UUID(),
      title: "Attribute boundaries",
      link: try XCTUnwrap(URL(string: "https://example.com/article")),
      contentHTML: """
        <a data-href="https://data.invalid/promoted">data</a>
        <a title='label href="https://nested.invalid/promoted"'>nested</a>
        <a href="/real">real</a>
        """
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertFalse(rendered.contains("data.invalid"))
    XCTAssertFalse(rendered.contains("nested.invalid"))
    XCTAssertTrue(rendered.contains("href=\"https://example.com/real\""))
  }

  func testAttributeEntitiesAreDecodedBeforeURLValidationAndEscapedOnce() throws {
    let article = RSSArticle(
      id: "attribute-entities",
      feedID: UUID(),
      title: "Attribute entities",
      link: try XCTUnwrap(URL(string: "https://example.com/article")),
      contentHTML: """
        <a href="/search?a=1&amp;b=2">query</a>
        <a href="&#106;avascript:alert(1)">unsafe</a>
        """
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(rendered.contains("href=\"https://example.com/search?a=1&amp;b=2\""))
    XCTAssertFalse(rendered.contains("amp;amp"))
    XCTAssertFalse(rendered.contains("javascript:"))
  }

  func testZeroWidthEntitiesDoNotCountAsRenderableBody() {
    let article = RSSArticle(
      id: "zero-width-only",
      feedID: UUID(),
      title: "Zero width",
      contentHTML: "<span>&#8203;&zwnj;&#x200D;&#65279;</span>"
    )

    XCTAssertFalse(RSSArticleHTMLRenderer.hasRenderableBody(article: article))
  }

  func testInvalidImageFallsBackToSummaryInsteadOfShowingRemotePlaceholder() {
    let article = RSSArticle(
      id: "invalid-image",
      feedID: UUID(),
      title: "Invalid image",
      summaryHTML: "<p>图片地址失效时仍应显示摘要。</p>",
      contentHTML: "<img src=\"javascript:alert(1)\">"
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(rendered.contains("图片地址失效时仍应显示摘要"))
    XCTAssertFalse(rendered.contains("远程图片已关闭"))
    XCTAssertFalse(rendered.contains("javascript:"))
  }

  func testKeepsReadableStructureAndRemovesExecutableContent() throws {
    let article = RSSArticle(
      id: "rich-article",
      feedID: UUID(),
      title: "结构化文章",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/rich")),
      contentHTML: """
        <h2>标题</h2>
        <p>段落 <strong>重点</strong></p>
        <ul><li>列表项</li></ul>
        <blockquote>引用</blockquote>
        <pre><code>let value = 1</code></pre>
        <a href="/source">来源链接</a>
        <a href="javascript:alert(1)">危险链接</a>
        <img src="https://cdn.example.com/image.jpg" alt="图片">
        <script>alert('xss')</script>
        <iframe src="https://evil.example"></iframe>
        """
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(rendered.contains("<h2>标题</h2>"))
    XCTAssertTrue(rendered.contains("<ul><li>列表项</li></ul>"))
    XCTAssertTrue(rendered.contains("<blockquote>引用</blockquote>"))
    XCTAssertTrue(rendered.contains("<pre><code>let value = 1</code></pre>"))
    XCTAssertTrue(rendered.contains("https://example.com/source"))
    XCTAssertFalse(rendered.contains("javascript:"))
    XCTAssertFalse(rendered.contains("<script"))
    XCTAssertFalse(rendered.contains("<iframe"))
    XCTAssertFalse(rendered.contains("src=\"https://cdn.example.com/image.jpg\""))
    XCTAssertTrue(rendered.contains("远程图片已关闭"))
  }

  func testRemoteImageIsOnlyIncludedAfterExplicitOptIn() throws {
    let article = RSSArticle(
      id: "image-article",
      feedID: UUID(),
      title: "图片文章",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/image")),
      contentHTML: "<p>正文</p><img src=\"/image.jpg\" alt=\"封面\">"
    )

    let blocked = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)
    let allowed = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: true)

    XCTAssertFalse(blocked.contains("src=\"https://example.com/image.jpg\""))
    XCTAssertTrue(allowed.contains("src=\"https://example.com/image.jpg\""))
    XCTAssertTrue(allowed.contains("loading=\"lazy\""))
  }

  func testArchivedImageIsRenderedWhenRemoteImagesAreDisabled() throws {
    let cacheURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSArticleHTMLRendererTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let relativePath = "article/image.jpg"
    let localURL = cacheURL.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([0xFF, 0xD8, 0xFF]).write(to: localURL)

    let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.com/image.jpg"))
    let article = RSSArticle(
      id: "archived-image-article",
      feedID: UUID(),
      title: "离线图片",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/archived-image")),
      contentHTML: "<img src=\"\(remoteURL.absoluteString)\">"
    )
    let asset = RSSMediaAsset(
      articleID: article.id,
      remoteURL: remoteURL,
      relativePath: relativePath,
      contentType: "image/jpeg",
      byteCount: 3
    )

    let rendered = RSSArticleHTMLRenderer.render(
      article: article,
      allowRemoteImages: false,
      mediaAssets: [asset],
      mediaCacheDirectoryURL: cacheURL
    )

    XCTAssertTrue(rendered.contains("src=\"\(localURL.absoluteString)\""))
    XCTAssertFalse(rendered.contains("远程图片已关闭"))
  }

  func testUnknownContainersKeepTheirReadableText() {
    let article = RSSArticle(
      id: "unknown-containers",
      feedID: UUID(),
      title: "Unknown containers",
      contentHTML: "<custom-shell><legacy-wrap>正文 <strong>重点</strong></legacy-wrap></custom-shell>"
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(RSSArticleHTMLRenderer.hasRenderableBody(article: article))
    XCTAssertTrue(rendered.contains("正文 <strong>重点</strong>"))
    XCTAssertFalse(rendered.contains("<custom-shell"))
    XCTAssertFalse(rendered.contains("<legacy-wrap"))
  }

  func testSemanticHTML5TagsKeepStructureButDropSourceAttributes() {
    let article = RSSArticle(
      id: "semantic-html",
      feedID: UUID(),
      title: "Semantic HTML",
      contentHTML: """
        <article id="post" style="display:none" onclick="alert(1)">
          <section><span class="lede" data-source="feed">正文 <b>重点</b></span></section>
          <figure><img src="https://cdn.example.com/image.jpg"><figcaption>图注</figcaption></figure>
          <hr><main>内层主体</main><small>补充说明</small>
          <details open><summary>展开阅读</summary><p>隐藏段落</p></details>
          <mark>来源标记</mark><script>alert('xss')</script>
        </article>
        """
    )

    let rendered = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)

    XCTAssertTrue(rendered.contains("<article>"))
    XCTAssertTrue(rendered.contains("<section><span>正文 <b>重点</b></span></section>"))
    XCTAssertTrue(rendered.contains("<figure>"))
    XCTAssertTrue(rendered.contains("<figcaption>图注</figcaption>"))
    XCTAssertTrue(rendered.contains("<hr>"))
    XCTAssertTrue(rendered.contains("<div>内层主体</div>"))
    XCTAssertTrue(rendered.contains("<details><summary>展开阅读</summary>"))
    XCTAssertTrue(rendered.contains("<mark>来源标记</mark>"))
    XCTAssertFalse(rendered.contains("id=\"post\""))
    XCTAssertFalse(rendered.contains("style=\"display:none\""))
    XCTAssertFalse(rendered.contains("onclick="))
    XCTAssertFalse(rendered.contains("class=\"lede\""))
    XCTAssertFalse(rendered.contains("data-source="))
    XCTAssertFalse(rendered.contains("<details open"))
    XCTAssertFalse(rendered.contains("<script"))
  }

  func testDocumentLanguageComesFromArticleContent() {
    let english = RSSArticle(
      id: "english",
      feedID: UUID(),
      title: "Swift package release notes",
      contentHTML: "<p>This release improves reading and search.</p>"
    )
    let chinese = RSSArticle(
      id: "chinese",
      feedID: UUID(),
      title: "新版阅读器发布",
      contentHTML: "<p>本次更新改善了文章列表和搜索。</p>"
    )

    XCTAssertTrue(
      RSSArticleHTMLRenderer.render(article: english, allowRemoteImages: false)
        .contains("<html lang=\"en\">")
    )
    XCTAssertTrue(
      RSSArticleHTMLRenderer.render(article: chinese, allowRemoteImages: false)
        .contains("<html lang=\"zh-CN\">")
    )
  }
}
