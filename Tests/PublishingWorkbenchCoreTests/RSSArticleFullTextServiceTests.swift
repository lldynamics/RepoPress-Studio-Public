import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RSSArticleFullTextServiceTests: XCTestCase {
  func testIsTruncatedCandidate() {
    let service = RSSArticleFullTextService()

    let shortArticleWithLink = RSSArticle(
      id: "art-1",
      feedID: UUID(),
      title: "短文章",
      link: URL(string: "https://example.com/post/1"),
      summaryHTML: "<p>这是一篇只有一句话的截断摘要。</p>",
      contentHTML: ""
    )
    XCTAssertTrue(service.isTruncatedCandidate(shortArticleWithLink))

    let shortArticleNoLink = RSSArticle(
      id: "art-2",
      feedID: UUID(),
      title: "无链接短文章",
      link: nil,
      summaryHTML: "<p>没有链接无法抓取全文。</p>",
      contentHTML: ""
    )
    XCTAssertFalse(service.isTruncatedCandidate(shortArticleNoLink))

    let longArticle = RSSArticle(
      id: "art-3",
      feedID: UUID(),
      title: "长篇完整文章",
      link: URL(string: "https://example.com/post/3"),
      summaryHTML: "<p>摘要</p>",
      contentHTML: String(repeating: "<p>这是一段包含丰富细节和完整阐述的长文章段落内容，不需要重新抓取全文。</p>", count: 20)
    )
    XCTAssertFalse(service.isTruncatedCandidate(longArticle))
  }

  func testFetchFullTextThrowsOnMissingLink() async {
    let service = RSSArticleFullTextService()
    let article = RSSArticle(
      id: "art-no-link",
      feedID: UUID(),
      title: "无链接",
      link: nil
    )

    do {
      _ = try await service.fetchFullText(for: article)
      XCTFail("应当抛出错误")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("有效的原文网页链接"))
    }
  }
}
