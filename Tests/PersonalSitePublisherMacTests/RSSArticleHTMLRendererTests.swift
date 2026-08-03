import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSArticleHTMLRendererTests: XCTestCase {
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
