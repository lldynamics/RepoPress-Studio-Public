import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSFeedIssueTests: XCTestCase {
  func testLegacyFeedErrorDecodesIntoStructuredIssueWithoutLosingLastError() throws {
    struct LegacyFeed: Encodable {
      let id: UUID
      let title: String
      let url: URL
      let addedAt: Date
      let lastError: String
    }

    let legacy = LegacyFeed(
      id: UUID(),
      title: "旧订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
      addedAt: Date(timeIntervalSinceReferenceDate: 123),
      lastError: "旧版网络错误"
    )
    let data = try JSONEncoder().encode(legacy)

    let decoded = try JSONDecoder().decode(RSSFeed.self, from: data)

    XCTAssertEqual(decoded.lastError, "旧版网络错误")
    XCTAssertEqual(decoded.lastIssue?.category, .unknown)
    XCTAssertEqual(decoded.lastIssue?.stage, .transport)
    XCTAssertEqual(decoded.lastIssue?.userMessage, "旧版网络错误")
  }

  func testStructuredIssueRoundTripsWithFeed() throws {
    let retryAt = Date(timeIntervalSinceReferenceDate: 500)
    let issue = RSSFeedIssue.http(
      statusCode: 429,
      retryAt: retryAt,
      technicalDetail: "HTTP 429; Retry-After=120",
      occurredAt: Date(timeIntervalSinceReferenceDate: 380)
    )
    let feed = RSSFeed(
      title: "限流订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
      lastIssue: issue
    )

    let decoded = try JSONDecoder().decode(
      RSSFeed.self,
      from: JSONEncoder().encode(feed)
    )

    XCTAssertEqual(decoded.lastIssue, issue)
    XCTAssertEqual(decoded.lastError, issue.userMessage)
    XCTAssertEqual(decoded.nextRetryAt, retryAt)
    XCTAssertEqual(decoded.healthStatus(now: retryAt.addingTimeInterval(-1)), .backingOff)
    XCTAssertEqual(decoded.healthStatus(now: retryAt.addingTimeInterval(1)), .failing)
  }

  func testHTTPFailuresHaveActionableCategoriesAndRetryPolicies() {
    XCTAssertEqual(
      RSSReaderError.httpStatus(401).asFeedIssue().category,
      .authenticationRequired
    )
    XCTAssertEqual(
      RSSReaderError.httpStatus(404).asFeedIssue().retryStrategy,
      .requiresAction
    )
    XCTAssertEqual(
      RSSReaderError.httpStatus(503).asFeedIssue().retryStrategy,
      .automatic
    )
    XCTAssertEqual(
      RSSReaderError.httpStatus(408).asFeedIssue().retryStrategy,
      .automatic
    )

    let retryAt = Date(timeIntervalSinceReferenceDate: 900)
    let rateLimited = RSSFeedIssue.http(statusCode: 429, retryAt: retryAt)
    XCTAssertEqual(rateLimited.category, .rateLimited)
    XCTAssertEqual(rateLimited.retryStrategy, .afterDate)
    XCTAssertEqual(rateLimited.retryAt, retryAt)
    XCTAssertTrue(rateLimited.shouldRetryAutomatically)

    let serviceRetryAt = retryAt.addingTimeInterval(60)
    let unavailable = RSSFeedIssue.http(statusCode: 503, retryAt: serviceRetryAt)
    XCTAssertEqual(unavailable.category, .serverUnavailable)
    XCTAssertEqual(unavailable.retryStrategy, .afterDate)
    XCTAssertEqual(unavailable.retryAt, serviceRetryAt)
  }

  func testPrivateNetworkBlockRequiresUserActionInsteadOfAutomaticRetry() {
    let issue = RSSReaderError.privateNetworkAccessDenied.asFeedIssue()

    XCTAssertEqual(issue.stage, .validation)
    XCTAssertEqual(issue.category, .permissionDenied)
    XCTAssertEqual(issue.retryStrategy, .requiresAction)
    XCTAssertFalse(issue.shouldRetryAutomatically)
    XCTAssertTrue(issue.userMessage.contains("局域网"))
  }

  func testURLErrorClassificationSeparatesOfflineTimeoutTLSAndCancellation() {
    XCTAssertEqual(
      RSSFeedIssue.from(urlError: URLError(.notConnectedToInternet)).category,
      .offline
    )
    XCTAssertEqual(
      RSSFeedIssue.from(urlError: URLError(.timedOut)).category,
      .timeout
    )

    let tls = RSSFeedIssue.from(urlError: URLError(.serverCertificateUntrusted))
    XCTAssertEqual(tls.category, .tlsFailure)
    XCTAssertEqual(tls.retryStrategy, .requiresAction)

    let cancelled = RSSFeedIssue.from(urlError: URLError(.cancelled))
    XCTAssertEqual(cancelled.category, .cancelled)
    XCTAssertEqual(cancelled.retryStrategy, .none)
    XCTAssertFalse(cancelled.shouldRetryAutomatically)
  }

  func testRetryAfterParsesDeltaSecondsAndHTTPDate() throws {
    let now = Date(timeIntervalSince1970: 784_111_777)

    XCTAssertEqual(
      RSSFeedClient.retryDate(from: "120", relativeTo: now),
      now.addingTimeInterval(120)
    )

    let httpDate = try XCTUnwrap(
      RSSFeedClient.retryDate(
        from: "Sun, 06 Nov 1994 08:49:37 GMT",
        relativeTo: now.addingTimeInterval(-60)
      )
    )
    XCTAssertEqual(httpDate.timeIntervalSince1970, 784_111_777, accuracy: 0.001)
    XCTAssertNil(RSSFeedClient.retryDate(from: "not-a-date", relativeTo: now))
  }

  func testValidEmptyRSSAndAtomFeedsParseSuccessfully() throws {
    let rssURL = try XCTUnwrap(URL(string: "https://example.com/rss.xml"))
    let rss = try RSSFeedParser.parse(
      data: Data("<rss version=\"2.0\"><channel><title>新博客</title></channel></rss>".utf8),
      feedURL: rssURL
    )
    XCTAssertEqual(rss.title, "新博客")
    XCTAssertTrue(rss.articles.isEmpty)

    let atomURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))
    let atom = try RSSFeedParser.parse(
      data: Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>空 Atom</title></feed>".utf8),
      feedURL: atomURL
    )
    XCTAssertEqual(atom.title, "空 Atom")
    XCTAssertTrue(atom.articles.isEmpty)
  }

  func testOrdinaryXMLIsNotAcceptedAsAnEmptyFeed() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/document.xml"))

    XCTAssertThrowsError(
      try RSSFeedParser.parse(
        data: Data("<document><title>普通 XML</title></document>".utf8),
        feedURL: url
      )
    ) { error in
      let issue = (error as? RSSReaderError)?.asFeedIssue()
      XCTAssertEqual(issue?.stage, .parsing)
      XCTAssertEqual(issue?.category, .invalidContent)
      XCTAssertEqual(issue?.retryStrategy, .requiresAction)
    }

    XCTAssertThrowsError(
      try RSSFeedParser.parse(
        data: Data("<feed><title>普通 XML</title></feed>".utf8),
        feedURL: url
      )
    )

    XCTAssertThrowsError(
      try RSSFeedParser.parse(
        data: Data("<channel><title>缺少 RSS 根</title></channel>".utf8),
        feedURL: url
      )
    )
  }

  func testClientRejectsUserInfoAndMissingHostWithoutLeakingURL() async throws {
    let client = RSSFeedClient()
    let unsafeURL = try XCTUnwrap(URL(string: "https://reader:secret@example.com/feed.xml"))
    let missingHostURL = try XCTUnwrap(URL(string: "https:feed.xml"))

    for url in [unsafeURL, missingHostURL] {
      do {
        _ = try await client.fetch(feedURL: url)
        XCTFail("应在发起网络请求前拒绝不安全地址")
      } catch {
        let issue = RSSFeedIssue.from(error: error)
        XCTAssertEqual(issue.stage, .validation)
        XCTAssertEqual(issue.category, .invalidAddress)
        XCTAssertEqual(issue.retryStrategy, .requiresAction)
        XCTAssertFalse(error.localizedDescription.contains("secret"))
        XCTAssertFalse(error.localizedDescription.contains("reader"))
      }
    }
  }

  func testParserFailureRetainsSafeMessageAndTechnicalDetail() {
    let issue = RSSReaderError.parseFailed("第 1 行 XML 格式错误").asFeedIssue()

    XCTAssertEqual(issue.stage, .parsing)
    XCTAssertEqual(issue.category, .invalidContent)
    XCTAssertEqual(issue.retryStrategy, .requiresAction)
    XCTAssertEqual(issue.userMessage, "订阅内容不是可识别的 RSS 或 Atom。")
    XCTAssertEqual(issue.technicalDetail, "第 1 行 XML 格式错误")
  }
}
