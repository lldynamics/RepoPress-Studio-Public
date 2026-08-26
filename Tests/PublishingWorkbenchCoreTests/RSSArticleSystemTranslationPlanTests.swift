import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RSSArticleSystemTranslationPlanTests: XCTestCase {
  func testPlanDecodesEntitiesAndSkipsNonVisibleElements() throws {
    let body = """
    <!DOCTYPE html><?xml version="1.0"?>
    <article data-id="keep" onclick="return false">
      <p>Hello &amp; welcome <a href="https://example.com/?a=1&amp;b=2">world &#x27;friend&#x27;</a>.</p>
      <pre><code>if a &lt; b &amp;&amp; b &gt; c</code></pre>
      <script>doNotTranslate(&amp;);</script>
      <style>.hidden { color: red; }</style>
      <p>Tail&nbsp;text</p>
    </article>
    """
    let plan = try makePlan(title: "A &amp; title", body: body)

    XCTAssertEqual(plan.requests.first?.id, "title")
    XCTAssertEqual(plan.requests.first?.sourceText, "A & title")
    XCTAssertEqual(
      plan.requests.dropFirst().map(\.sourceText),
      ["Hello & welcome ", "world 'friend'", ".", "Tail\u{00A0}text"]
    )
    XCTAssertFalse(plan.requests.contains { $0.sourceText.contains("doNotTranslate") })
    XCTAssertFalse(plan.requests.contains { $0.sourceText.contains("if a") })
    XCTAssertFalse(plan.requests.contains { $0.sourceText.contains("DOCTYPE") })
    XCTAssertFalse(plan.requests.contains { $0.sourceText.contains("version=") })
    XCTAssertEqual(plan.requests.map(\.id), ["title", "body.0", "body.1", "body.2", "body.3"])
  }

  func testResultEscapesProviderHTMLAndPreservesSourceMarkupAndAttributes() throws {
    let body = #"<p class="keep"><a href="https://example.com/?q=1&amp;x=2">Source</a></p>"#
    let plan = try makePlan(title: "Original", body: body)
    let result = try plan.makeResult(
      translationsByRequestID: [
        "title": "Translated title",
        "body.0": #"<script>alert("x")</script> & <b>unsafe</b>"#,
      ],
      providerName: "Apple",
      model: "system"
    )

    XCTAssertEqual(result.articleID, "article-1")
    XCTAssertEqual(result.target, .simplifiedChinese)
    XCTAssertEqual(result.providerName, "Apple")
    XCTAssertEqual(result.model, "system")
    XCTAssertEqual(result.sourceCharacterCount, "Original".count + body.count)
    XCTAssertFalse(result.wasInputTruncated)
    XCTAssertTrue(
      result.translatedContentHTML.contains(
        #"<p class="keep"><a href="https://example.com/?q=1&amp;x=2">"#
      )
    )
    XCTAssertTrue(
      result.translatedContentHTML.contains(
        "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &lt;b&gt;unsafe&lt;/b&gt;"
      )
    )
    XCTAssertFalse(result.translatedContentHTML.contains("<script>alert"))
  }

  func testLiteralLessThanInTextRemainsOneVisibleRequest() throws {
    let body = "<p>2 < 3 and 4 &gt; 1</p>"
    let plan = try makePlan(title: "Title", body: body)

    XCTAssertEqual(plan.requests.map(\.sourceText), ["Title", "2 < 3 and 4 > 1"])
    let result = try plan.makeResult(
      translationsByRequestID: ["title": "标题", "body.0": "二小于三"],
      providerName: "Apple",
      model: "system"
    )
    XCTAssertEqual(result.translatedContentHTML, "<p>二小于三</p>")
  }

  func testMissingOrEmptyTranslationFailsClosed() throws {
    let plan = try makePlan(title: "Original", body: "<p>Source</p><p>Second</p>")

    XCTAssertThrowsError(
      try plan.makeResult(
        translationsByRequestID: ["title": "标题"],
        providerName: "Apple",
        model: "system"
      )
    ) { error in
      XCTAssertEqual(error as? RSSArticleTranslationError, .invalidResponse)
    }

    XCTAssertThrowsError(
      try plan.makeResult(
        translationsByRequestID: [
          "title": "标题",
          "body.0": " ",
          "body.1": "第二段",
        ],
        providerName: "Apple",
        model: "system"
      )
    ) { error in
      XCTAssertEqual(error as? RSSArticleTranslationError, .invalidResponse)
    }
  }

  func testEmptyArticleUsesExistingTranslationError() {
    XCTAssertThrowsError(
      try RSSArticleSystemTranslationPlanningService.makePlan(
        article: makeArticle(title: " ", body: ""),
        target: .simplifiedChinese
      )
    ) { error in
      XCTAssertEqual(error as? RSSArticleTranslationError, .emptyArticle)
    }
  }

  func testLongInputRetainsUnplannedOriginalTextAndReportsTruncation() throws {
    let tail = String(repeating: "x", count: 60_100)
    let body = "<p>First</p><p>\(tail)</p>"
    let plan = try makePlan(title: "Original", body: body)

    XCTAssertTrue(plan.wasInputTruncated)
    XCTAssertEqual(plan.sourceCharacterCount, "Original".count + body.count)
    XCTAssertEqual(plan.requests.map(\.id), ["title", "body.0"])

    let result = try plan.makeResult(
      translationsByRequestID: [
        "title": "标题",
        "body.0": "第一段",
      ],
      providerName: "Apple",
      model: "system"
    )
    XCTAssertTrue(result.translatedContentHTML.contains("<p>第一段</p>"))
    XCTAssertTrue(result.translatedContentHTML.contains(tail))
  }

  func testTitleIsLimitedToExistingSafetyBound() throws {
    let title = String(repeating: "t", count: 501)
    let plan = try makePlan(title: title, body: "<p>Body</p>")

    XCTAssertTrue(plan.wasInputTruncated)
    XCTAssertEqual(plan.requests[0].sourceText.count, 500)
    XCTAssertEqual(plan.sourceCharacterCount, 500 + "<p>Body</p>".count)
  }

  func testBackendIsCodableAndExhaustive() throws {
    XCTAssertEqual(RSSArticleTranslationBackend.allCases, [.apple, .ai])
    let data = try JSONEncoder().encode(RSSArticleTranslationBackend.apple)
    XCTAssertEqual(String(data: data, encoding: .utf8), "\"apple\"")
    XCTAssertEqual(
      try JSONDecoder().decode(RSSArticleTranslationBackend.self, from: data),
      .apple
    )
  }

  private func makePlan(title: String, body: String) throws -> RSSArticleSystemTranslationPlan {
    try RSSArticleSystemTranslationPlanningService.makePlan(
      article: makeArticle(title: title, body: body),
      target: .simplifiedChinese
    )
  }

  private func makeArticle(title: String, body: String) -> RSSArticle {
    RSSArticle(
      id: "article-1",
      feedID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      title: title,
      summaryHTML: body,
      contentHTML: body
    )
  }
}
