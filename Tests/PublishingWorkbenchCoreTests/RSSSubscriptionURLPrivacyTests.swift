import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RSSSubscriptionURLPrivacyTests: XCTestCase {
  func testWriterRejectsFeedAndSiteURLUserInfoWithoutEchoingCredentials() throws {
    let safeFeedURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    let credentialFeedURL = try XCTUnwrap(
      URL(string: "https://alice:super-secret@example.com/feed.xml")
    )
    let credentialSiteURL = try XCTUnwrap(
      URL(string: "https://bob:site-secret@example.com/")
    )
    let subscriptions = [
      RSSOPMLSubscription(title: "Feed credentials", url: credentialFeedURL),
      RSSOPMLSubscription(title: "Site credentials", url: safeFeedURL, siteURL: credentialSiteURL),
    ]

    for subscription in subscriptions {
      XCTAssertThrowsError(
        try RSSOPMLWriter.makeDocument(subscriptions: [subscription])
      ) { error in
        guard case let RSSReaderError.invalidOPML(message) = error else {
          return XCTFail("Expected invalidOPML, got \(error)")
        }
        XCTAssertTrue(message.contains("用户名或密码"))
        XCTAssertFalse(message.contains("alice"))
        XCTAssertFalse(message.contains("bob"))
        XCTAssertFalse(message.contains("super-secret"))
        XCTAssertFalse(message.contains("site-secret"))
      }
    }
  }

  func testScannerFindsCredentialQueryNamesWithoutRetainingValues() throws {
    let feedURL = try XCTUnwrap(
      URL(
        string: "https://example.com/feed.xml?api_key=feed-secret&topic=swift&X-Amz-Signature=signed-value"
      )
    )
    let siteURL = try XCTUnwrap(
      URL(string: "https://example.com/?access_token=site-secret&author=demo")
    )
    let report = RSSOPMLWriter.scanExportRisks(
      subscriptions: [RSSOPMLSubscription(title: "Risky", url: feedURL, siteURL: siteURL)]
    )

    XCTAssertTrue(report.hasRisks)
    XCTAssertFalse(report.hasBlockingUserInfo)
    XCTAssertTrue(report.hasSuspectedCredentialQueryParameters)
    XCTAssertEqual(report.affectedSubscriptionCount, 1)
    XCTAssertEqual(
      Set(report.suspectedCredentialQueryParameterNames.map { $0.lowercased() }),
      ["api_key", "x-amz-signature", "access_token"]
    )
    let safeReportText = report.findings.map(\.redactedURL).joined(separator: "\n")
    XCTAssertFalse(safeReportText.contains("feed-secret"))
    XCTAssertFalse(safeReportText.contains("signed-value"))
    XCTAssertFalse(safeReportText.contains("site-secret"))
    XCTAssertTrue(safeReportText.contains("REDACTED"))
  }

  func testScannerDoesNotFlagBenignQueryNamesContainingKeyOrAuthText() throws {
    let url = try XCTUnwrap(
      URL(string: "https://example.com/feed.xml?monkey=one&keyboard=two&author=three&category=four")
    )

    let report = RSSOPMLWriter.scanExportRisks(
      subscriptions: [RSSOPMLSubscription(title: "Benign", url: url)]
    )

    XCTAssertFalse(report.hasRisks)
  }

  func testDefaultWriterRedactsCredentialQueryValues() throws {
    let url = try XCTUnwrap(
      URL(string: "https://example.com/feed.xml?api_key=legacy-secret&topic=swift")
    )

    let data = try RSSOPMLWriter.makeDocument(
      subscriptions: [RSSOPMLSubscription(title: "Legacy", url: url)]
    )
    let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertFalse(xml.contains("legacy-secret"))
    XCTAssertTrue(xml.contains("api_key=REDACTED"))
    XCTAssertTrue(xml.contains("topic=swift"))
  }

  func testRiskReportRedactsEveryQueryValueOnceURLIsSensitive() throws {
    let url = try XCTUnwrap(
      URL(string: "https://alice:secret@example.com/feed.xml?session_id=custom-secret&topic=swift")
    )

    let report = RSSOPMLWriter.scanExportRisks(
      subscriptions: [RSSOPMLSubscription(title: "Sensitive", url: url)]
    )
    let rendered = try XCTUnwrap(report.findings.first?.redactedURL)

    XCTAssertFalse(rendered.contains("alice"))
    XCTAssertFalse(rendered.contains("secret"))
    XCTAssertFalse(rendered.contains("custom-secret"))
    XCTAssertFalse(rendered.contains("topic=swift"))
    XCTAssertTrue(rendered.contains("session_id=REDACTED"))
    XCTAssertTrue(rendered.contains("topic=REDACTED"))
  }

  func testNoRiskLegacyExportStillRoundTripsWithoutPrivacyFindings() throws {
    let feedURL = try XCTUnwrap(
      URL(string: "https://example.com/feed.xml?source=reader&format=rss")
    )
    let siteURL = try XCTUnwrap(URL(string: "https://example.com/blog?lang=zh-Hans"))
    let subscription = RSSOPMLSubscription(
      title: "A & <RSS> \"精选\"",
      url: feedURL,
      siteURL: siteURL
    )

    let report = RSSOPMLWriter.scanExportRisks(subscriptions: [subscription])
    let data = try RSSOPMLWriter.makeDocument(
      subscriptions: [subscription],
      title: "我的 RSS & 阅读列表"
    )

    XCTAssertFalse(report.hasRisks)
    XCTAssertEqual(try RSSOPMLParser.parse(data: data), [subscription])
  }

  func testRedactingExportScrubsCredentialValuesAndKeepsBenignQueries() throws {
    let feedURL = try XCTUnwrap(
      URL(string: "https://example.com/feed.xml?api_key=feed-secret&topic=swift")
    )
    let siteURL = try XCTUnwrap(
      URL(string: "https://example.com/?authToken=site-secret&lang=zh-Hans")
    )

    let result = try RSSOPMLWriter.prepareDocument(
      subscriptions: [RSSOPMLSubscription(title: "Redacted", url: feedURL, siteURL: siteURL)],
      privacyAction: .redactCredentialQueryValues
    )
    let xml = try XCTUnwrap(String(data: result.data, encoding: .utf8))

    XCTAssertEqual(result.exportedSubscriptionCount, 1)
    XCTAssertEqual(result.excludedSubscriptionCount, 0)
    XCTAssertTrue(result.riskReport.hasSuspectedCredentialQueryParameters)
    XCTAssertFalse(xml.contains("feed-secret"))
    XCTAssertFalse(xml.contains("site-secret"))
    XCTAssertTrue(xml.contains("api_key=REDACTED"))
    XCTAssertTrue(xml.contains("authToken=REDACTED"))
    XCTAssertTrue(xml.contains("topic=swift"))
    XCTAssertTrue(xml.contains("lang=zh-Hans"))
  }

  func testExcludingExportDropsRiskySubscriptionsAndReportsCount() throws {
    let safeURL = try XCTUnwrap(URL(string: "https://safe.example.com/feed.xml?topic=swift"))
    let riskyURL = try XCTUnwrap(
      URL(string: "https://risky.example.com/feed.xml?token=secret-value")
    )

    let result = try RSSOPMLWriter.prepareDocument(
      subscriptions: [
        RSSOPMLSubscription(title: "Safe", url: safeURL),
        RSSOPMLSubscription(title: "Risky", url: riskyURL),
      ],
      privacyAction: .excludeSubscriptionsWithCredentialQuery
    )
    let xml = try XCTUnwrap(String(data: result.data, encoding: .utf8))

    XCTAssertEqual(result.exportedSubscriptionCount, 1)
    XCTAssertEqual(result.excludedSubscriptionCount, 1)
    XCTAssertTrue(xml.contains("Safe"))
    XCTAssertFalse(xml.contains("Risky"))
    XCTAssertFalse(xml.contains("secret-value"))
  }

  func testParserRejectsFeedAndSiteURLUserInfo() throws {
    let documents = [
      """
      <?xml version="1.0"?>
      <opml version="2.0"><body>
        <outline text="Feed" type="rss" xmlUrl="https://alice:feed-secret@example.com/feed.xml"/>
      </body></opml>
      """,
      """
      <?xml version="1.0"?>
      <opml version="2.0"><body>
        <outline text="Site" type="rss" xmlUrl="https://example.com/feed.xml" htmlUrl="https://bob:site-secret@example.com/"/>
      </body></opml>
      """,
    ]

    for document in documents {
      XCTAssertThrowsError(try RSSOPMLParser.parse(data: Data(document.utf8))) { error in
        guard case let RSSReaderError.invalidOPML(message) = error else {
          return XCTFail("Expected invalidOPML, got \(error)")
        }
        XCTAssertTrue(message.contains("用户名或密码"))
        XCTAssertFalse(message.contains("feed-secret"))
        XCTAssertFalse(message.contains("site-secret"))
      }
    }
  }

  func testParserRejectsOrdinaryXMLContainingOutline() throws {
    let document = """
    <?xml version="1.0"?>
    <document><body>
      <outline text="Not OPML" xmlUrl="https://example.com/feed.xml"/>
    </body></document>
    """

    XCTAssertThrowsError(try RSSOPMLParser.parse(data: Data(document.utf8))) { error in
      guard case RSSReaderError.invalidOPML = error else {
        return XCTFail("Expected invalidOPML, got \(error)")
      }
    }
  }

  func testWriterRejectsHostlessURLWithoutEchoingQuerySecret() throws {
    let url = try XCTUnwrap(URL(string: "https:feed?token=do-not-echo"))

    XCTAssertThrowsError(
      try RSSOPMLWriter.prepareDocument(
        subscriptions: [RSSOPMLSubscription(title: "", url: url)],
        privacyAction: .redactCredentialQueryValues
      )
    ) { error in
      XCTAssertFalse(error.localizedDescription.contains("do-not-echo"))
    }
  }
}
