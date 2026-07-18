import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeWebContentSanitizerTests: XCTestCase {
  func testSanitizerPrefersArticleAndRemovesPageChromeAndInteractionNoise() throws {
    let html = """
    <!doctype html>
    <html lang="zh-CN">
      <head>
        <title>页面标题</title>
        <meta content="测试作者" name="author">
        <meta property="og:title" content="长期阅读方法">
        <meta content="保存真正有价值的正文" name="description">
        <script>window.secret = "脚本噪声"</script>
      </head>
      <body>
        <nav>首页 登录 注册</nav>
        <article class="post-content">
          <header>
            <h1>长期阅读方法</h1>
            <div class="share-toolbar">分享到社交网络</div>
          </header>
          <p>第一段讨论如何保存高质量文章，并去除导航与广告。</p>
          <aside>订阅我们的新闻邮件</aside>
          <h2>建立长期资料库</h2>
          <p>第二段保留标题、段落与&nbsp;语义结构。</p>
          <section class="comments">评论区的无关讨论</section>
        </article>
        <footer>版权与友情链接</footer>
      </body>
    </html>
    """

    let result = KnowledgeWebContentSanitizer().sanitize(html: html)

    XCTAssertEqual(result.title, "长期阅读方法")
    XCTAssertEqual(result.authors, ["测试作者"])
    XCTAssertEqual(result.language, "zh-CN")
    XCTAssertEqual(result.summary, "保存真正有价值的正文")
    XCTAssertTrue(result.selectedMainContent)
    XCTAssertGreaterThan(result.removedNoiseBlockCount, 0)
    XCTAssertEqual(result.sections.map(\.headingPath), [
      "长期阅读方法",
      "长期阅读方法 › 建立长期资料库",
    ])
    let text = result.sections.map(\.text).joined(separator: "\n")
    XCTAssertTrue(text.contains("保存高质量文章"))
    XCTAssertTrue(text.contains("语义结构"))
    XCTAssertFalse(text.contains("首页"))
    XCTAssertFalse(text.contains("分享到"))
    XCTAssertFalse(text.contains("订阅我们的"))
    XCTAssertFalse(text.contains("评论区"))
    XCTAssertFalse(text.contains("脚本噪声"))
    XCTAssertFalse(text.contains("友情链接"))
  }

  func testSanitizerFallbackRemovesNoiseAndKeepsSafeMarkdownLinks() {
    let html = """
    <html><body>
      <div class="top-menu">菜单 登录</div>
      <div>
        <h1>没有 article 标签的文章</h1>
        <p>正文仍应被提取。</p>
        <p>Cookie 技术的工作原理也是这篇文章的正文主题。</p>
        <p><a href="https://example.com/reference">参考资料</a></p>
        <p><a href="javascript:alert(1)">危险链接</a></p>
      </div>
      <div id="cookie-consent">We use cookies. Accept all.</div>
    </body></html>
    """

    let result = KnowledgeWebContentSanitizer().sanitize(html: html)
    let text = result.sections.map(\.text).joined(separator: "\n")

    XCTAssertFalse(result.selectedMainContent)
    XCTAssertTrue(text.contains("正文仍应被提取"))
    XCTAssertTrue(text.contains("Cookie 技术的工作原理"))
    XCTAssertTrue(text.contains("[参考资料](https://example.com/reference)"))
    XCTAssertTrue(text.contains("危险链接"))
    XCTAssertFalse(text.contains("javascript:"))
    XCTAssertFalse(text.contains("Accept all"))
    XCTAssertFalse(text.contains("菜单 登录"))
  }

  func testHTMLImportUsesSanitizedSectionsForNormalizedTextAndSearch() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-clean-web-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("article.html")
    try """
    <html><head><title>净化导入测试</title></head><body>
      <nav>导航专用噪声词</nav>
      <main>
        <h1>资料库正文</h1>
        <p>真正正文介绍离线语义检索和长期保存。</p>
        <div class="advertisement">广告专用噪声词</div>
      </main>
      <footer>页脚专用噪声词</footer>
    </body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertTrue(candidate.normalizedText.contains("离线语义检索"))
    XCTAssertFalse(candidate.normalizedText.contains("导航专用噪声词"))
    XCTAssertFalse(candidate.normalizedText.contains("广告专用噪声词"))
    XCTAssertFalse(candidate.normalizedText.contains("页脚专用噪声词"))
    XCTAssertTrue(candidate.warnings.contains { $0.contains("净化") })

    _ = try await service.commit(preview)
    XCTAssertFalse(try service.search(query: "离线语义检索").isEmpty)
    XCTAssertFalse(try service.search(query: "广告专用噪声词").contains {
      $0.signals.contains(.fullText)
    })
  }

  func testBrowserCaptureReSanitizesOriginalHTMLBeforeBuildingPreview() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-clean-web-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let originalHTML = """
    <html><body>
      <nav>浏览器导航噪声</nav>
      <article><h1>浏览器正文</h1><p>插件保存后仍由应用再次净化。</p></article>
      <footer>浏览器页脚噪声</footer>
    </body></html>
    """
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/clean-article")),
      title: "浏览器正文",
      contentText: "这是插件回退文本，不应覆盖可用的原始 HTML。",
      originalHTML: originalHTML
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(candidate.originalData, Data(originalHTML.utf8))
    XCTAssertTrue(candidate.normalizedText.contains("应用再次净化"))
    XCTAssertFalse(candidate.normalizedText.contains("浏览器导航噪声"))
    XCTAssertFalse(candidate.normalizedText.contains("浏览器页脚噪声"))
    XCTAssertFalse(candidate.normalizedText.contains("插件回退文本"))
    XCTAssertTrue(candidate.warnings.contains { $0.contains("重新净化") })
  }

  func testExistingBloggerReadingTextDropsTrailingShareAndCommentChrome() {
    let text = """
    # 正文标题

    这一段是已经保存到资料库里的正文，应继续显示。通过电子邮件发送BlogThis!分享到 Twitter 分享到 Facebook
    ![](https://resources.blogblog.com/img/icon18_edit_allbkg.gif)
    没有评论:
    发表评论
    https://www.blogger.com/comment/frame/123456
    较新的博文
    较早的博文
    博客归档
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.contains("已经保存到资料库里的正文"))
    XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("BlogThis"))
    XCTAssertFalse(cleaned.contains("resources.blogblog.com"))
    XCTAssertFalse(cleaned.contains("没有评论"))
    XCTAssertFalse(cleaned.contains("发表评论"))
    XCTAssertFalse(cleaned.contains("blogger.com/comment"))
    XCTAssertFalse(cleaned.contains("较新的博文"))
    XCTAssertFalse(cleaned.contains("较早的博文"))
    XCTAssertFalse(cleaned.contains("博客归档"))
  }

  func testBloggerPageFixtureKeepsPostAndDropsCommentsArchiveAndEmbeddedFrames() {
    let html = """
    <!doctype html>
    <html lang="zh-CN">
      <head><title>结构性优势</title></head>
      <body>
        <div id="navbar">搜索此博客</div>
        <main id="main">
          <article class="post hentry">
            <h1 class="post-title">结构性优势</h1>
            <div class="post-body entry-content">
              <p>一，长期积累会形成难以复制的知识结构。</p>
              <h2>竞争较少</h2>
              <p>三，可以积累结构性优势，因为竞争较少。</p>
            </div>
            <div class="post-footer">通过电子邮件发送BlogThis!分享到 Twitter</div>
            <section id="comments"><h4>没有评论：</h4><p>发表评论</p></section>
            <iframe src="https://www.blogger.com/comment/frame/123456"></iframe>
          </article>
        </main>
        <aside class="sidebar">
          <h2>供稿人</h2><p>站点管理员</p>
          <h2>博客归档</h2><a href="/2024/01">2024</a>
        </aside>
        <footer>较新的博文 较早的博文</footer>
      </body>
    </html>
    """

    let result = KnowledgeWebContentSanitizer().sanitize(html: html)
    let text = result.sections.map(\.text).joined(separator: "\n")

    XCTAssertTrue(text.contains("难以复制的知识结构"))
    XCTAssertTrue(text.contains("可以积累结构性优势"))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("BlogThis"))
    XCTAssertFalse(text.contains("没有评论"))
    XCTAssertFalse(text.contains("发表评论"))
    XCTAssertFalse(text.contains("blogger.com/comment"))
    XCTAssertFalse(text.contains("供稿人"))
    XCTAssertFalse(text.contains("博客归档"))
    XCTAssertFalse(text.contains("较新的博文"))
  }

  func testSanitizerExtractsQuotedPrintableHTMLFromMHTMLArchive() throws {
    let mhtml = """
    From: <Saved by Blink>
    Content-Type: multipart/related; boundary="page-boundary"

    --page-boundary
    Content-Type: text/html; charset=UTF-8
    Content-Transfer-Encoding: quoted-printable

    <html><body><article><h1>MHTML =E6=AD=A3=E6=96=87</h1><p>=E6=9C=AC=E5=9C=B0=E5=BD=92=E6=A1=A3=E5=8F=AF=E4=BB=A5=E9=87=8D=E6=96=B0=E5=87=80=E5=8C=96=E3=80=82</p></article></body></html>
    --page-boundary--
    """

    let result = try KnowledgeWebContentSanitizer().sanitize(
      data: Data(mhtml.utf8),
      sourceName: "archive.mhtml"
    )
    let text = result.sections.map(\.text).joined(separator: "\n")

    XCTAssertTrue(result.sections.compactMap(\.headingPath).contains { $0.contains("MHTML 正文") })
    XCTAssertTrue(text.contains("本地归档可以重新净化"))
    XCTAssertFalse(text.contains("Saved by Blink"))
  }
}
