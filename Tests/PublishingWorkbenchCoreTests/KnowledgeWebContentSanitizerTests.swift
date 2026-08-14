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

  func testSanitizerRemovesSocialEngagementControlsAndKeepsRelatedProse() {
    let html = """
    <html><body>
      <article>
        <h1>社交平台导入</h1>
        <p>正文会解释如何查看发布记录，也会回复读者提出的问题。</p>
        <div class="engagement-bar">
          <span>查看 2.3 万</span><span>回复 128</span><span>点赞 900</span>
        </div>
        <button data-testid="reply">回复</button>
        <p>互动数量不是衡量内容质量的唯一标准。</p>
      </article>
    </body></html>
    """

    let result = KnowledgeWebContentSanitizer().sanitize(html: html)
    let text = result.sections.map(\.text).joined(separator: "\n")

    XCTAssertTrue(text.contains("如何查看发布记录"))
    XCTAssertTrue(text.contains("回复读者提出的问题"))
    XCTAssertTrue(text.contains("互动数量不是衡量内容质量的唯一标准"))
    XCTAssertFalse(text.contains("2.3 万"))
    XCTAssertFalse(text.contains("回复 128"))
    XCTAssertFalse(text.contains("点赞 900"))
    XCTAssertGreaterThanOrEqual(result.removedNoiseBlockCount, 2)
  }

  func testExtractedSocialTextDropsChineseEnglishAndIconMetricRows() {
    let text = """
    # 正文标题

    这是应该长期保存的社交平台正文。
    浏览量 18.4万
    互动数量
    2,031 条回复 · 6.2 万次点赞 · 304 次转发
    [查看全部 2,031 条回复](https://example.com/replies)
    1.2M views · 45K likes · 800 reposts
    View 2,031 replies
    💬 128 · 🔁 35 · ❤️ 900
    回复 转发 点赞
    这是正文的最后一段。
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.contains("应该长期保存"))
    XCTAssertTrue(cleaned.contains("正文的最后一段"))
    XCTAssertFalse(cleaned.contains("18.4万"))
    XCTAssertFalse(cleaned.components(separatedBy: .newlines).contains("互动数量"))
    XCTAssertFalse(cleaned.contains("2,031"))
    XCTAssertFalse(cleaned.contains("45K likes"))
    XCTAssertFalse(cleaned.contains("💬 128"))
    XCTAssertFalse(cleaned.contains("回复 转发 点赞"))
  }

  func testExtractedSocialTextKeepsSentencesAndFencedCodeUsingInteractionWords() {
    let text = """
    请查看完整说明，并回复用户提出的问题。
    互动数量不是衡量内容质量的唯一标准。
    请回复 12 条评论并说明判断理由。

    ```text
    回复 12
    120 views
    ```
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.contains("请查看完整说明"))
    XCTAssertTrue(cleaned.contains("互动数量不是衡量内容质量"))
    XCTAssertTrue(cleaned.contains("请回复 12 条评论并说明判断理由"))
    XCTAssertTrue(cleaned.contains("回复 12"))
    XCTAssertTrue(cleaned.contains("120 views"))
  }

  func testExtractedSocialTextDropsCountFirstActionsReplyPermissionsAndNewPostPrompts() {
    let text = """
    这是需要保留的帖子正文。
    428 回复 · 3.1K 点赞 · 91 转发
    谁可以回复此帖子？
    仅限你关注的人可以回复
    查看 12 条新帖子
    Show 8 new posts
    回复
    428
    转发
    91
    正文结束。
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.contains("需要保留"))
    XCTAssertTrue(cleaned.contains("正文结束"))
    XCTAssertFalse(cleaned.contains("428 回复"))
    XCTAssertFalse(cleaned.contains("谁可以回复"))
    XCTAssertFalse(cleaned.contains("仅限你关注"))
    XCTAssertFalse(cleaned.contains("新帖子"))
    XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("new posts"))
    XCTAssertFalse(cleaned.components(separatedBy: .newlines).contains("428"))
    XCTAssertFalse(cleaned.components(separatedBy: .newlines).contains("91"))
  }

  func testExtractedSocialTextDropsCurrentChineseReplyAndNewPostChromeWithCounts() {
    let text = """
    这段正文应保留并用于 AI 检索。
    查看新帖子
    12
    所有人可以回复
    36
    查看新推文 8
    所有用户均可回复
    文章结尾也应保留。
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)
    let lines = cleaned.components(separatedBy: .newlines)

    XCTAssertTrue(cleaned.contains("正文应保留"))
    XCTAssertTrue(cleaned.contains("文章结尾"))
    XCTAssertFalse(cleaned.contains("查看新帖子"))
    XCTAssertFalse(cleaned.contains("所有人可以回复"))
    XCTAssertFalse(cleaned.contains("查看新推文"))
    XCTAssertFalse(cleaned.contains("所有用户均可回复"))
    XCTAssertFalse(lines.contains("12"))
    XCTAssertFalse(lines.contains("36"))
  }

  func testExtractedSocialTextKeepsAnUnrelatedStandaloneNumber() {
    let text = """
    章节编号

    2026
    2027

    这个数字属于正文，不是互动区。
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.components(separatedBy: .newlines).contains("2026"))
    XCTAssertTrue(cleaned.components(separatedBy: .newlines).contains("2027"))
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

  func testBrowserCaptureFallbackTextRemovesSocialInteractionMetrics() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-social-clean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/social-post")),
      title: "社交平台正文",
      contentText: """
      这段内容应该进入资料库和搜索索引。
      浏览量 12.6万
      428 replies · 3.1K likes · 91 reposts
      查看全部 428 条回复
      """,
      originalHTML: nil
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(candidate.capturedText, capture.contentText)
    XCTAssertTrue(candidate.normalizedText.contains("应该进入资料库和搜索索引"))
    XCTAssertFalse(candidate.normalizedText.contains("12.6万"))
    XCTAssertFalse(candidate.normalizedText.contains("428 replies"))
    XCTAssertFalse(candidate.normalizedText.contains("查看全部"))

    let result = try await service.commit(preview)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    XCTAssertEqual(try service.capturedText(documentID: documentID), capture.contentText)
    XCTAssertTrue(try service.normalizedText(documentID: documentID).contains("应该进入资料库"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("12.6万"))
    XCTAssertFalse(try service.search(query: "12.6万").contains {
      $0.signals.contains(.fullText)
    })

    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("store/library.sqlite")
    )
    let revision = try XCTUnwrap(database.currentRevision(documentID: documentID))
    let capturedReference = try XCTUnwrap(revision.capturedTextStorageReference)
    XCTAssertEqual(
      try String(
        contentsOf: rootURL
          .appendingPathComponent("store")
          .appendingPathComponent(capturedReference),
        encoding: .utf8
      ),
      capture.contentText
    )
  }

  func testBrowserFallbackTextCanBeRecleanedOfflineWithoutRestoringSocialNoise() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-fallback-reclean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/social-fallback")),
      title: "社交平台纯文本归档",
      contentText: """
      这是需要用于 AI 检索的正文。
      查看新帖子
      12
      所有人可以回复
      36
      """,
      originalHTML: nil
    )
    let importResult = try await service.commit(
      try await service.makeBrowserImportPreview(capture: capture)
    )
    let documentID = try XCTUnwrap(importResult.documentIDs.first)

    let previews = try await service.makeLocalContentRepairPreviews(
      documentIDs: [documentID],
      includingCurrentParserVersion: true
    )
    let preview = try XCTUnwrap(previews.first)
    let recleanedText = try XCTUnwrap(preview.importPreview.candidates.first?.normalizedText)

    XCTAssertTrue(recleanedText.contains("需要用于 AI 检索的正文"))
    XCTAssertFalse(recleanedText.contains("查看新帖子"))
    XCTAssertFalse(recleanedText.contains("所有人可以回复"))
    XCTAssertFalse(recleanedText.components(separatedBy: .newlines).contains("12"))
    XCTAssertFalse(recleanedText.components(separatedBy: .newlines).contains("36"))

    _ = try await service.applyLocalContentRepairs(previews)
    XCTAssertFalse(try service.search(query: "所有人可以回复").contains {
      $0.signals.contains(.fullText)
    })
    XCTAssertEqual(try service.capturedText(documentID: documentID), capture.contentText)
  }

  func testLegacyHTMLImportCanReadOriginalArchiveWithoutCapturedTextSidecar() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-legacy-original-view-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("social.html")
    try """
    <html><body>
      <nav>旧归档导航</nav>
      <article>
        <h1>旧社交帖子</h1>
        <p>这是需要阅读和检索的正文。</p>
        <p>浏览量 12.6万</p>
      </article>
    </body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertNil(preview.candidates.first?.capturedText)
    let result = try await service.commit(preview)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let originalText = try XCTUnwrap(service.capturedText(documentID: documentID))

    XCTAssertTrue(originalText.contains("旧归档导航"))
    XCTAssertTrue(originalText.contains("浏览量 12.6万"))
    XCTAssertTrue(originalText.contains("需要阅读和检索的正文"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("旧归档导航"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("12.6万"))
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

  func testExistingBloggerReadingTextDropsCombinedAtomFooterAndStrayBracket() {
    let text = """
    # 正文标题

    这是应该保留的文章结尾。
    [
    [主页](https://example.blogspot.com/) [订阅](https://example.blogspot.com/feeds/posts/default) 博文评论 (Atom)
    """

    let cleaned = KnowledgeWebContentSanitizer().sanitizeExtractedReadingText(text)

    XCTAssertTrue(cleaned.contains("应该保留的文章结尾"))
    XCTAssertFalse(cleaned.contains("[主页]"))
    XCTAssertFalse(cleaned.contains("订阅"))
    XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("Atom"))
    XCTAssertFalse(cleaned.components(separatedBy: .newlines).contains("["))
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

  func testSanitizerExtractsRichMarkdownWithCodeLanguageAndInlineFormatting() {
    let html = """
    <html><body><article>
      <h1>代码与排版测试</h1>
      <p>这里有 <strong>加粗重点</strong> 和 <em>斜体强调</em> 以及 <del>已废弃的废话</del>。</p>
      <p>请使用 <code>swift build</code> 构建项目。</p>
      <pre class="language-swift"><code>func greet() -> String { "Hello" }</code></pre>
      <img src="https://example.com/cover.png" alt="封面配图">
    </article></body></html>
    """

    let result = KnowledgeWebContentSanitizer().sanitize(html: html)
    let text = result.sections.map(\.text).joined(separator: "\n")

    XCTAssertTrue(text.contains("**加粗重点**"))
    XCTAssertTrue(text.contains("`swift build`"))
    XCTAssertTrue(text.contains("~~已废弃的废话~~"))
    XCTAssertTrue(text.contains("```swift"))
    XCTAssertTrue(text.contains("func greet() -> String"))
    XCTAssertTrue(text.contains("![封面配图](https://example.com/cover.png)"))
  }
}
