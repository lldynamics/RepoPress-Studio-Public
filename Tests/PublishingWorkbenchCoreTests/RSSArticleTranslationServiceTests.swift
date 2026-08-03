import XCTest
@testable import PublishingWorkbenchCore

final class RSSArticleTranslationServiceTests: XCTestCase {
  func testTargetPresetsAndCustomLanguageAreStable() throws {
    XCTAssertEqual(
      RSSArticleTranslationTarget.preset(for: "en"),
      .english
    )

    let custom = try XCTUnwrap(
      RSSArticleTranslationTarget.custom(language: "Português (Brasil)")
    )
    XCTAssertEqual(custom.displayName, "Português (Brasil)")
    XCTAssertTrue(custom.languageCode.hasPrefix("custom:"))
    XCTAssertNil(RSSArticleTranslationTarget.custom(language: " \n "))
  }

  func testParserAcceptsFencedJSONAndPreservesTranslatedHTML() throws {
    let target = RSSArticleTranslationTarget.english
    let result = try XCTUnwrap(
      RSSArticleTranslationResponseParser.parse(
        """
        ```json
        {"title":"Translated title","content_html":"<h2>Heading</h2><pre><code>let x = 1</code></pre>"}
        ```
        """,
        articleID: "article-1",
        target: target,
        providerName: "Local model",
        model: "llama3.1",
        sourceCharacterCount: 42,
        wasInputTruncated: false
      )
    )

    XCTAssertEqual(result.articleID, "article-1")
    XCTAssertEqual(result.translatedTitle, "Translated title")
    XCTAssertEqual(
      result.translatedContentHTML,
      "<h2>Heading</h2><pre><code>let x = 1</code></pre>"
    )
    XCTAssertEqual(result.providerName, "Local model")
  }

  func testParserRejectsEmptyOrNonJSONResponses() {
    XCTAssertNil(
      RSSArticleTranslationResponseParser.parse(
        "not JSON",
        articleID: "article-1",
        target: .english,
        providerName: "Local model",
        model: "llama3.1",
        sourceCharacterCount: 10,
        wasInputTruncated: false
      )
    )
    XCTAssertNil(
      RSSArticleTranslationResponseParser.parse(
        "{\"title\":\"\",\"content_html\":\"<p>Body</p>\"}",
        articleID: "article-1",
        target: .english,
        providerName: "Local model",
        model: "llama3.1",
        sourceCharacterCount: 10,
        wasInputTruncated: false
      )
    )
  }

  func testApplyingTranslationPreservesArticleMetadata() throws {
    let article = RSSArticle(
      id: "article-1",
      feedID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      title: "Original title",
      link: URL(string: "https://example.com/article"),
      author: "Author",
      publishedAt: Date(timeIntervalSince1970: 123),
      summaryHTML: "<p>Original summary</p>",
      contentHTML: "<p>Original body</p>",
      fetchedAt: Date(timeIntervalSince1970: 456),
      readAt: Date(timeIntervalSince1970: 789),
      isStarred: true,
      tags: ["swift"]
    )
    let result = RSSArticleTranslationResult(
      articleID: article.id,
      target: .simplifiedChinese,
      translatedTitle: "翻译标题",
      translatedContentHTML: "<p>翻译正文</p>",
      providerName: "本地模型",
      model: "llama3.1",
      sourceCharacterCount: 20,
      wasInputTruncated: false
    )

    let translated = result.applying(to: article)
    XCTAssertEqual(translated.title, "翻译标题")
    XCTAssertEqual(translated.contentHTML, "<p>翻译正文</p>")
    XCTAssertEqual(translated.summaryHTML, "<p>翻译正文</p>")
    XCTAssertEqual(translated.link, article.link)
    XCTAssertEqual(translated.author, article.author)
    XCTAssertEqual(translated.publishedAt, article.publishedAt)
    XCTAssertEqual(translated.readAt, article.readAt)
    XCTAssertEqual(translated.isStarred, article.isStarred)
    XCTAssertEqual(translated.tags, article.tags)
  }
}
