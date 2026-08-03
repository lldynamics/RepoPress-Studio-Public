import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSArticleWorkflowTests: XCTestCase {
  func testHighlightBlockquoteContainsExcerptSourceAndNote() throws {
    let article = RSSArticle(
      id: "news-1",
      feedID: UUID(),
      title: "一篇 [值得引用] 的文章",
      link: try XCTUnwrap(URL(string: "https://example.com/news-1")),
      contentHTML: "<p>原文正文</p>"
    )
    let highlight = RSSArticleHighlight(
      id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
      articleID: article.id,
      text: "第一行\n第二行",
      note: "保留这个观点"
    )

    let markdown = RSSArticleWorkflow.insertionMarkdown(
      article: article,
      highlight: highlight,
      style: .blockquote
    )

    XCTAssertTrue(markdown.contains("> 第一行\n> 第二行"))
    XCTAssertTrue(markdown.contains("> — [一篇 \\[值得引用\\] 的文章]"))
    XCTAssertTrue(markdown.contains("注：保留这个观点"))
    XCTAssertTrue(markdown.contains("RSS 高亮"))
  }

  func testFootnoteAppendsOneStableDefinition() throws {
    let article = RSSArticle(
      id: "news-1",
      feedID: UUID(),
      title: "参考文章",
      link: try XCTUnwrap(URL(string: "https://example.com/news-1")),
      contentHTML: "<p>原文正文</p>"
    )
    let highlight = RSSArticleHighlight(
      id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
      articleID: article.id,
      text: "可核对的摘录"
    )

    let reference = RSSArticleWorkflow.insertionMarkdown(
      article: article,
      highlight: highlight,
      style: .footnote
    )
    let firstBody = RSSArticleWorkflow.appendingFootnote(
      to: "正文\n\n\(reference)",
      article: article,
      highlight: highlight
    )
    let secondBody = RSSArticleWorkflow.appendingFootnote(
      to: firstBody,
      article: article,
      highlight: highlight
    )

    XCTAssertTrue(reference.hasPrefix("[^rss-news-1-"))
    XCTAssertTrue(firstBody.contains("## RSS 来源"))
    XCTAssertTrue(firstBody.contains("可核对的摘录"))
    XCTAssertEqual(secondBody, firstBody)
  }
}
