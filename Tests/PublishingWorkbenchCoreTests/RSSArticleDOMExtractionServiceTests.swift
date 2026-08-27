import CoreFoundation
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSArticleDOMExtractionServiceTests: XCTestCase {
  private let service = RSSArticleDOMExtractionService()
  private let sourceURL = URL(string: "https://example.com/posts/reading")!

  func testChoosesTheReadableArticleAmongSeveralArticleNodes() throws {
    let html = """
      <html><head>
        <title>长期阅读方法 - 示例站</title>
        <meta name="author" content="程作者">
      </head><body>
        <nav><a href="/">首页</a><a href="/login">登录</a></nav>
        <article class="recommendation"><h2>推荐</h2><p>广告摘要。</p></article>
        <article class="post-content" role="article">
          <h1>长期阅读方法</h1>
          <p>第一段讨论如何保存高质量文章，并去除导航与广告。</p>
          <p>第二段解释正文候选评分，应该保留这段有意义的内容。</p>
          <aside>订阅邮件</aside>
        </article>
        <footer>版权与友情链接</footer>
      </body></html>
      """

    let result = try service.extract(
      data: Data(html.utf8),
      sourceURL: sourceURL,
      expectedTitle: "长期阅读方法"
    )

    XCTAssertEqual(result.title, "长期阅读方法 - 示例站")
    XCTAssertEqual(result.author, "程作者")
    XCTAssertTrue(result.plainText.contains("保存高质量文章"))
    XCTAssertTrue(result.plainText.contains("正文候选评分"))
    XCTAssertFalse(result.plainText.contains("广告摘要"))
    XCTAssertFalse(result.plainText.contains("首页"))
    XCTAssertFalse(result.plainText.contains("订阅邮件"))
    XCTAssertGreaterThan(result.confidence, 0)
    XCTAssertEqual(result.sourceURL, sourceURL)
  }

  func testTidyDOMAndMarkdownPipelinePreserveRichTextStructure() throws {
    let html = """
      <main class="article-body"><h1>格式保留</h1>
        <p>这是 <strong>重点</strong>，包含 <a href="https://example.com/reference">参考链接</a>。</p>
        <p>下面是列表：<ul><li>第一项</li><li><em>第二项</em><ol><li>嵌套项</li></ol></li></ul></p>
        <table><tr><th>名称</th><th>值</th></tr><tr><td>A</td><td>1</td></tr></table>
        <pre><code class="language-swift">let value = "safe"</code></pre>
      </main>
      """

    let result = try service.extract(data: Data(html.utf8), sourceURL: sourceURL)

    XCTAssertTrue(result.contentHTML.contains("<strong>重点</strong>"))
    XCTAssertTrue(result.contentHTML.contains("href=\"https://example.com/reference\""))
    XCTAssertTrue(result.contentHTML.contains("<ul>"))
    XCTAssertTrue(result.contentHTML.contains("<ol>"))
    XCTAssertTrue(result.contentHTML.contains("<table>"))
    XCTAssertTrue(result.contentHTML.contains("<pre><code class=\"language-swift\">"))
    XCTAssertTrue(result.contentHTML.contains("let value = &quot;safe&quot;"))
    XCTAssertFalse(result.contentHTML.contains("<script"))
  }

  func testResolvesRelativeLinksAndImagesAgainstSourceURL() throws {
    let html = """
      <article class="entry-content">
        <p>请查看 <a href="../guide/page.html?utm_source=rss#intro">指南</a>。</p>
        <p><img src="/images/diagram.png?utm_campaign=feed" alt="结构图"></p>
      </article>
      """

    let result = try service.extract(data: Data(html.utf8), sourceURL: sourceURL)

    XCTAssertTrue(result.contentHTML.contains("https://example.com/guide/page.html#intro"))
    XCTAssertTrue(result.contentHTML.contains("https://example.com/images/diagram.png"))
    XCTAssertFalse(result.contentHTML.contains("utm_source"))
    XCTAssertFalse(result.contentHTML.contains("utm_campaign"))
  }

  func testRejectsLoginAndNavigationShell() {
    let html = """
      <html><body>
        <nav>首页 产品 登录 注册</nav>
        <div class="login-shell"><h1>请登录</h1><p>登录后继续阅读。</p><form><input name="email"></form></div>
      </body></html>
      """

    XCTAssertThrowsError(try service.extract(data: Data(html.utf8), sourceURL: sourceURL)) {
      error in
      XCTAssertEqual(error as? RSSArticleDOMExtractionError, .noReadableContent)
    }
  }

  func testShortChineseArticleIsNotRejectedByFixedLengthGate() throws {
    let html = "<article><h1>一则短文</h1><p>今天记录一个很短但完整的想法。</p></article>"

    let result = try service.extract(
      data: Data(html.utf8),
      sourceURL: sourceURL,
      expectedTitle: "一则短文"
    )

    XCTAssertTrue(result.plainText.contains("完整的想法"))
    XCTAssertFalse(result.plainText.isEmpty)
  }

  func testDecodesDeclaredISO8859AndPreservesText() throws {
    let html = """
      <html><head><meta charset="ISO-8859-1"></head><body><article><h1>Café</h1>
        <p>Crème brûlée is a complete short article.</p>
      </article></body></html>
      """
    let bytes = try XCTUnwrap(html.data(using: .isoLatin1))

    let result = try service.extract(data: bytes, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("Café"))
    XCTAssertTrue(result.plainText.contains("Crème brûlée"))
  }

  func testUnknownDeclaredEncodingFailsExplicitly() {
    let html = "<meta charset=\"x-unsupported-encoding\"><article><p>正文</p></article>"

    XCTAssertThrowsError(try service.extract(data: Data(html.utf8), sourceURL: sourceURL)) {
      error in
      guard case .unsupportedEncoding(let name) = error as? RSSArticleDOMExtractionError else {
        return XCTFail("应报告不支持的编码，实际为：\(error)")
      }
      XCTAssertEqual(name, "x-unsupported-encoding")
    }
  }

  func testDecodesDeclaredGB18030() throws {
    let html = """
      <html><head><meta charset="gb18030"></head><body>
        <article><h1>中文旧站</h1><p>这是一段使用 GB18030 编码的完整正文。</p></article>
      </body></html>
      """
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )
    let data = try XCTUnwrap(html.data(using: encoding))

    let result = try service.extract(data: data, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("中文旧站"))
    XCTAssertTrue(result.plainText.contains("完整正文"))
  }

  func testDecodesDeclaredShiftJIS() throws {
    let html = """
      <html><head><meta charset="Shift_JIS"></head><body>
        <article><h1>日本語の記事</h1><p>これはシフトJISで書かれた本文です。</p></article>
      </body></html>
      """
    let data = try XCTUnwrap(html.data(using: .shiftJIS))

    let result = try service.extract(data: data, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("日本語の記事"))
    XCTAssertTrue(result.plainText.contains("本文です"))
  }

  func testUsesHTTPEncodingHintWhenDocumentHasNoMetaCharset() throws {
    let html = """
      <html><body><article><h1>中文标题</h1><p>这段正文只在 HTTP 头里声明字符编码。</p></article></body></html>
      """
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )
    let data = try XCTUnwrap(html.data(using: encoding))

    let result = try service.extract(
      data: data,
      sourceURL: sourceURL,
      textEncodingName: "gb18030"
    )

    XCTAssertTrue(result.plainText.contains("中文标题"))
    XCTAssertTrue(result.plainText.contains("HTTP 头"))
  }

  func testInfersUndeclaredGBKBeforeSingleByteFallback() throws {
    let html = """
      <html><body><article><h1>无声明中文标题</h1>
        <p>这是一段没有 charset 声明、使用 GBK 编码的正文。</p>
      </article></body></html>
      """
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
      )
    )
    let data = try XCTUnwrap(html.data(using: encoding))

    let result = try service.extract(data: data, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("无声明中文标题"))
    XCTAssertTrue(result.plainText.contains("使用 GBK 编码"))
  }

  func testInfersUndeclaredGB18030BeforeSingleByteFallback() throws {
    let html = """
      <html><body><article><h1>无声明国标标题</h1>
        <p>这是一段没有 charset 声明、使用 GB18030 编码的正文。</p>
      </article></body></html>
      """
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )
    let data = try XCTUnwrap(html.data(using: encoding))

    let result = try service.extract(data: data, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("无声明国标标题"))
    XCTAssertTrue(result.plainText.contains("使用 GB18030 编码"))
  }

  func testInfersUndeclaredShiftJISBeforeSingleByteFallback() throws {
    let html = """
      <html><body><article><h1>文字コードのない記事</h1>
        <p>これは charset 宣言がないシフトJISの本文です。</p>
      </article></body></html>
      """
    let data = try XCTUnwrap(html.data(using: .shiftJIS))

    let result = try service.extract(data: data, sourceURL: sourceURL)

    XCTAssertTrue(result.plainText.contains("文字コードのない記事"))
    XCTAssertTrue(result.plainText.contains("シフトJISの本文です"))
  }

  func testRejectsDOMThatExceedsNodeBudget() {
    let repeated = String(repeating: "<div><p>重复节点。</p></div>", count: 40_000)
    let html = "<html><body>\(repeated)</body></html>"

    XCTAssertThrowsError(try service.extract(data: Data(html.utf8), sourceURL: sourceURL)) {
      error in
      XCTAssertEqual(error as? RSSArticleDOMExtractionError, .documentTooComplex)
    }
  }

  func testRejectsHTMLBeyondByteBudgetBeforeParsing() {
    let data = Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1)

    XCTAssertThrowsError(try service.extract(data: data, sourceURL: sourceURL)) { error in
      XCTAssertEqual(error as? RSSArticleDOMExtractionError, .documentTooComplex)
    }
  }

  func testRejectsDOMThatExceedsDepthBudget() {
    let depth = 300
    let html =
      "<html><body>"
      + String(repeating: "<div>", count: depth)
      + "<p>深层正文。</p>"
      + String(repeating: "</div>", count: depth)
      + "</body></html>"

    XCTAssertThrowsError(try service.extract(data: Data(html.utf8), sourceURL: sourceURL)) {
      error in
      XCTAssertEqual(error as? RSSArticleDOMExtractionError, .documentTooComplex)
    }
  }
}
