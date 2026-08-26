import Foundation
import PublishingWorkbenchCore
import WebKit
import XCTest

@testable import PersonalSitePublisherMac

final class WebContentNetworkSecurityTests: XCTestCase {
  func testRSSReaderNeverEmitsUncachedNetworkImageSources() throws {
    let article = RSSArticle(
      id: "network-image-boundary",
      feedID: UUID(),
      title: "Untrusted images",
      link: try XCTUnwrap(URL(string: "https://publisher.example/articles/1")),
      contentHTML: """
        <p>正文仍应保留。</p>
        <img src="http://localhost:8080/one.png" alt="localhost">
        <img src="http://127.0.0.1/two.png" alt="IPv4 loopback">
        <img src="http://10.0.0.8/three.png" alt="RFC1918">
        <img src="http://169.254.169.254/four.png" alt="link local">
        <img src="http://[::1]/five.png" alt="IPv6 loopback">
        <img src="HTTPS://rebind.example.test/six.png" alt="DNS hostname">
        <img src="//cdn.example.test/seven.png" alt="scheme relative">
        """
    )

    let rendered = RSSArticleHTMLRenderer.render(
      article: article,
      allowRemoteImages: true
    )

    XCTAssertTrue(rendered.contains("<p>正文仍应保留。</p>"))
    XCTAssertFalse(rendered.contains("src=\"http://"))
    XCTAssertFalse(rendered.contains("src=\"https://"))
    XCTAssertFalse(rendered.lowercased().contains("src=\"https://"))
    XCTAssertFalse(rendered.contains("localhost:8080"))
    XCTAssertFalse(rendered.contains("169.254.169.254"))
    XCTAssertFalse(rendered.contains("rebind.example.test"))
    XCTAssertTrue(rendered.contains("IPv4 loopback"))
    XCTAssertTrue(rendered.contains("DNS hostname"))
  }

  func testRSSReaderContentSecurityPolicyAllowsOnlyNonNetworkImages() {
    let article = RSSArticle(
      id: "network-image-csp",
      feedID: UUID(),
      title: "CSP",
      contentHTML: "<p>正文</p>"
    )

    let rendered = RSSArticleHTMLRenderer.render(
      article: article,
      allowRemoteImages: true
    )

    XCTAssertTrue(rendered.contains("default-src 'none'"))
    XCTAssertTrue(rendered.contains("img-src data: file:"))
    XCTAssertFalse(rendered.contains("img-src https:"))
    XCTAssertFalse(rendered.contains("img-src http:"))
    XCTAssertTrue(rendered.contains("connect-src 'none'"))
  }

  @MainActor
  func testMarkdownExportWebViewAddsFailClosedHTTPContentRule() async throws {
    let data = Data(MarkdownExportWebContentSecurity.contentRuleListJSON.utf8)
    let rules = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    )
    let rule = try XCTUnwrap(rules.first)
    let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
    let action = try XCTUnwrap(rule["action"] as? [String: Any])

    XCTAssertEqual(trigger["url-filter"] as? String, "^https?://")
    XCTAssertEqual(trigger["url-filter-is-case-sensitive"] as? Bool, false)
    XCTAssertEqual(action["type"] as? String, "block")

    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "markdown-export-rule-store-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let configuration = try await MarkdownExportWebContentSecurity.makeConfiguration(
      ruleListStore: WKContentRuleListStore(url: storeURL)
    )
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
  }
}
