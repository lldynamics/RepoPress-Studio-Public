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

  func testShortCompleteArticleIsNotAutomaticallyClassifiedAsTruncated() {
    let article = RSSArticle(
      id: "short-complete",
      feedID: UUID(),
      title: "一则短文",
      link: URL(string: "https://example.com/short"),
      summaryHTML: "<p>摘要</p>",
      contentHTML: "<article><p>今天记录一个很短但完整的想法。</p></article>"
    )

    XCTAssertFalse(RSSArticleFullTextService().isTruncatedCandidate(article))
  }

  func testFetchBuildsReadyRecordWithRedirectAndValidators() async throws {
    let sourceURL = try XCTUnwrap(URL(string: "https://example.com/post"))
    let resolvedURL = try XCTUnwrap(URL(string: "https://www.example.com/post"))
    let html = """
    <html><body><article class="post-content"><h1>完整文章</h1>
    <p>第一段是有完整语义的正文，不是导航或登录页面。</p>
    <p>第二段继续补充文章细节，并保留基本排版。</p></article></body></html>
    """
    let client = RSSArticlePageClient(downloadOperation: { _, _, _ in
      (
        Data(html.utf8),
        HTTPURLResponse(
          url: resolvedURL,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "ETag": "article-v2",
            "Last-Modified": "Thu, 27 Aug 2026 00:00:00 GMT",
          ]
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "ready-record",
      feedID: UUID(),
      title: "完整文章",
      link: sourceURL,
      summaryHTML: "<p>摘要</p>"
    )

    let record = try await service.fetchFullTextRecord(for: article)

    XCTAssertEqual(record.status, .ready)
    XCTAssertEqual(record.sourceURL, sourceURL)
    XCTAssertEqual(record.resolvedURL, resolvedURL)
    XCTAssertEqual(record.sourceETag, "article-v2")
    XCTAssertEqual(record.sourceLastModified, "Thu, 27 Aug 2026 00:00:00 GMT")
    XCTAssertEqual(record.sourceContentHash?.count, 64)
    XCTAssertTrue(record.plainText.contains("第二段"))
    XCTAssertEqual(record.extractorIdentifier, RSSArticleDOMExtractionService.extractorIdentifier)
  }

  func testNotModifiedReusesAcceptedCachedRecord() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/post"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 304,
          httpVersion: "HTTP/1.1",
          headerFields: ["ETag": "same"]
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "cached",
      feedID: UUID(),
      title: "Cached",
      link: url,
      summaryHTML: "<p>summary</p>"
    )
    let cached = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<p>cached full text</p>",
      plainText: "cached full text",
      sourceURL: url,
      resolvedURL: url,
      extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
      sourceETag: "same",
      sourceContentHash: "hash",
      confidence: 0.8
    )

    let result = try await service.fetchFullTextRecord(for: article, cachedRecord: cached)

    XCTAssertEqual(result.status, .ready)
    XCTAssertEqual(result.contentHTML, cached.contentHTML)
    XCTAssertEqual(result.sourceContentHash, "hash")
    XCTAssertEqual(result.sourceETag, "same")
  }

  func testChangedSourceNeverReusesOldValidatorsOrBody() async throws {
    let oldURL = try XCTUnwrap(URL(string: "https://old.example.com/post"))
    let newURL = try XCTUnwrap(URL(string: "https://new.example.com/post"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
      XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 304,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "moved-source",
      feedID: UUID(),
      title: "Moved",
      link: newURL
    )
    let cached = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<p>old body</p>",
      plainText: "old body",
      sourceURL: oldURL,
      resolvedURL: oldURL,
      extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
      sourceETag: "old-etag",
      sourceLastModified: "Wed, 26 Aug 2026 00:00:00 GMT",
      confidence: 0.8
    )

    do {
      _ = try await service.fetchFullTextRecord(for: article, cachedRecord: cached)
      XCTFail("A 304 response without a source-compatible cache must fail closed")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("没有可用的全文缓存"))
    }
    let failedRecord = service.failureRecord(
      for: article,
      cachedRecord: cached,
      error: RSSReaderError.network("offline")
    )
    XCTAssertEqual(failedRecord.sourceURL, newURL)
    XCTAssertNil(failedRecord.sourceETag)
    XCTAssertNil(failedRecord.sourceLastModified)
    XCTAssertNil(failedRecord.sourceContentHash)
  }

  func testForceRefreshAndExtractorUpgradeBypassValidators() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/fresh"))
    let html = """
    <html><body><article><h1>Fresh</h1>
    <p>Fresh complete article body with enough prose and punctuation.</p></article></body></html>
    """
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
      return (
        Data(html.utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "force-or-upgrade",
      feedID: UUID(),
      title: "Fresh",
      link: url,
      summaryHTML: "<p>Fresh summary.</p>"
    )
    let oldExtractorCache = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<p>old body</p>",
      plainText: "old body",
      sourceURL: url,
      resolvedURL: url,
      extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: "older-version",
      sourceETag: "old-etag",
      confidence: 0.8
    )

    let upgraded = try await service.fetchFullTextRecord(
      for: article,
      cachedRecord: oldExtractorCache
    )
    XCTAssertEqual(upgraded.status, .ready)
    XCTAssertTrue(upgraded.plainText.contains("Fresh complete"))

    let currentCache = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: upgraded.contentHTML,
      plainText: upgraded.plainText,
      sourceURL: url,
      resolvedURL: url,
      extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
      sourceETag: "current-etag",
      confidence: upgraded.confidence
    )
    _ = try await service.fetchFullTextRecord(
      for: article,
      cachedRecord: currentCache,
      forceRefresh: true
    )
  }

  func testNotModifiedKeepsQualityRejectionAndExtendsBackoff() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/rejected"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 304,
          httpVersion: "HTTP/1.1",
          headerFields: ["ETag": "same-rejection"]
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "cached-rejection",
      feedID: UUID(),
      title: "Rejected",
      link: url
    )
    let previousAttempt = Date(timeIntervalSince1970: 1_700_000_000)
    let cached = RSSArticleFullTextRecord.rejected(
      articleID: article.id,
      sourceURL: url,
      resolvedURL: url,
      extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
      sourceETag: "same-rejection",
      attemptedAt: previousAttempt,
      retryAfter: previousAttempt.addingTimeInterval(60),
      failureMessage: "quality"
    )
    let nextAttempt = previousAttempt.addingTimeInterval(600)

    let result = try await service.fetchFullTextRecord(
      for: article,
      cachedRecord: cached,
      attemptedAt: nextAttempt
    )

    XCTAssertEqual(result.status, .rejected)
    XCTAssertEqual(result.failureMessage, "quality")
    XCTAssertEqual(result.attemptedAt, nextAttempt)
    XCTAssertEqual(
      result.retryAfter,
      nextAttempt.addingTimeInterval(RSSArticleFullTextService.retryDelay)
    )
  }

  func testQualityGateRejectsExtractionThatIsMateriallyWorseThanFeed() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/post"))
    let html = "<article><h1>标题</h1><p>太短的结果。</p></article>"
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data(html.utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/html"]
        )!
      )
    })
    let service = RSSArticleFullTextService(pageClient: client)
    let article = RSSArticle(
      id: "worse",
      feedID: UUID(),
      title: "标题",
      link: url,
      contentHTML: "<p>\(String(repeating: "Feed 已有较长的有效内容。", count: 20))</p>"
    )

    let result = try await service.fetchFullTextRecord(for: article)

    XCTAssertEqual(result.status, .rejected)
    XCTAssertTrue(result.failureMessage?.contains("明显更短") == true)
    XCTAssertNotNil(result.retryAfter)
  }
}
