import Foundation
import PublishingCoreSupport
import XCTest

final class PublishedArticleURLDiscoveryTests: XCTestCase {
  private let base = URL(string: "https://chengjinfang.com/")!
  private let path = "content/posts/2026/RepoPress Studio使用DeepSeek官方API教程.md"

  func testRanksActualZolaURLUsingRouteAndASCIIClues() {
    let xml = """
      <urlset><url><loc>https://chengjinfang.com/posts/2026/other-post/</loc></url>
      <url><loc>https://chengjinfang.com/posts/2026/repopress-studioshi-yong-deepseekguan-fang-apijiao-cheng/</loc></url>
      <url><loc>https://chengjinfang.com/about/</loc></url></urlset>
      """
    let result = PublishedArticleURLDiscovery().candidates(
      baseURL: base, sitemapText: xml, markdownPath: path, expectedTitle: "ignored")
    XCTAssertEqual(
      result.first?.absoluteString,
      "https://chengjinfang.com/posts/2026/repopress-studioshi-yong-deepseekguan-fang-apijiao-cheng/"
    )
  }

  func testRanksMatchingURLEvenWhenItAppearsAfterCandidateLimit() {
    let decoys = (0..<40).map {
      "<url><loc>https://chengjinfang.com/posts/2026/unrelated-\($0)/</loc></url>"
    }.joined()
    let actual =
      "<url><loc>https://chengjinfang.com/posts/2026/repopress-studioshi-yong-deepseekguan-fang-apijiao-cheng/</loc></url>"
    let result = PublishedArticleURLDiscovery().candidates(
      baseURL: base, sitemapText: "<urlset>\(decoys)\(actual)</urlset>", markdownPath: path)
    XCTAssertEqual(
      result.first?.absoluteString,
      "https://chengjinfang.com/posts/2026/repopress-studioshi-yong-deepseekguan-fang-apijiao-cheng/"
    )
    XCTAssertEqual(result.count, PublishedArticleURLDiscovery.maximumCandidates)
  }

  func testFiltersCrossOriginAndNonHTTPLocations() {
    let xml =
      "<urlset><url><loc>https://evil.example/posts/2026/repopress-studio/</loc></url><url><loc>ftp://chengjinfang.com/posts/2026/a/</loc></url><url><loc>https://chengjinfang.com/posts/2026/good/</loc></url></urlset>"
    let result = PublishedArticleURLDiscovery().candidates(
      baseURL: base, sitemapText: xml, markdownPath: path)
    XCTAssertEqual(result.map(\.absoluteString), ["https://chengjinfang.com/posts/2026/good/"])
  }

  func testRejectsInvalidOrOversizedXML() {
    let discovery = PublishedArticleURLDiscovery()
    XCTAssertTrue(
      discovery.candidates(baseURL: base, sitemapText: "<urlset><url>", markdownPath: path).isEmpty)
    let oversized = String(
      repeating: "x", count: PublishedArticleURLDiscovery.maximumSitemapBytes + 1)
    XCTAssertTrue(
      discovery.candidates(baseURL: base, sitemapText: oversized, markdownPath: path).isEmpty)
  }

  func testNoASCIIMarkersStillReturnsStableBoundedFallback() {
    let urls = (0..<100).map {
      "<url><loc>https://chengjinfang.com/posts/2026/候选\($0)/</loc></url>"
    }.joined()
    let xml = "<urlset>\(urls)</urlset>"
    let discovery = PublishedArticleURLDiscovery()
    let first = discovery.candidates(
      baseURL: base, sitemapText: xml, markdownPath: "content/posts/2026/中文文章.md")
    let second = discovery.candidates(
      baseURL: base, sitemapText: xml, markdownPath: "content/posts/2026/中文文章.md")
    XCTAssertEqual(first.count, PublishedArticleURLDiscovery.maximumCandidates)
    XCTAssertEqual(first, second)
  }
}
