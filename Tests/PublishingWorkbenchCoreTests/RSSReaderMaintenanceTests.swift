import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RSSReaderMaintenanceTests: XCTestCase {
  func testPruningRemovesOnlyOldReadUnstarredUnhighlightedArticles() throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let defaultsSuite = "RSSReaderMaintenanceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let oldDate = now.addingTimeInterval(-90 * 86_400)
    let recentDate = now.addingTimeInterval(-10 * 86_400)
    let feed = RSSFeed(
      title: "清理测试",
      url: try XCTUnwrap(URL(string: "https://example.com/maintenance.xml"))
    )
    let eligible = RSSArticle(
      id: "eligible",
      feedID: feed.id,
      title: "应该清理",
      publishedAt: oldDate,
      fetchedAt: oldDate,
      readAt: oldDate
    )
    let unread = RSSArticle(
      id: "unread",
      feedID: feed.id,
      title: "未读保留",
      publishedAt: oldDate,
      fetchedAt: oldDate
    )
    let starred = RSSArticle(
      id: "starred",
      feedID: feed.id,
      title: "收藏保留",
      publishedAt: oldDate,
      fetchedAt: oldDate,
      readAt: oldDate,
      isStarred: true
    )
    let highlighted = RSSArticle(
      id: "highlighted",
      feedID: feed.id,
      title: "高亮保留",
      publishedAt: oldDate,
      fetchedAt: oldDate,
      readAt: oldDate
    )
    let recent = RSSArticle(
      id: "recent",
      feedID: feed.id,
      title: "近期保留",
      publishedAt: recentDate,
      fetchedAt: recentDate,
      readAt: recentDate
    )

    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([eligible, unread, starred, highlighted, recent])

    let store = RSSReaderStore(
      fileURL: fileURL,
      userDefaults: defaults
    )
    _ = try store.saveHighlight(
      articleID: highlighted.id,
      text: "需要保留",
      note: "有高亮"
    )

    let summary = store.pruneReadArticles(olderThanDays: 60, now: now)

    XCTAssertEqual(summary.removedArticleCount, 1)
    XCTAssertNil(store.articleHeader(id: eligible.id))
    XCTAssertNotNil(store.articleHeader(id: unread.id))
    XCTAssertNotNil(store.articleHeader(id: starred.id))
    XCTAssertNotNil(store.articleHeader(id: highlighted.id))
    XCTAssertNotNil(store.articleHeader(id: recent.id))

    let reopened = RSSReaderStore(fileURL: fileURL, userDefaults: defaults)
    XCTAssertNil(reopened.articleHeader(id: eligible.id))
    XCTAssertEqual(reopened.articleHeaders.count, 4)
    XCTAssertEqual(reopened.highlights(for: highlighted.id).count, 1)
  }

  func testRefreshUsesConfiguredBoundedConcurrency() async throws {
    XCTAssertEqual(RSSReaderStore.maximumRefreshConcurrency, 6)

    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = RSSRefreshConcurrencyProbe()
    let store = RSSReaderStore(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      fetchOperation: { feedURL, _, _ in
        await probe.enter()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await probe.leave()
        let article = RSSParsedArticle(
          id: feedURL.absoluteString,
          title: "并发测试",
          link: feedURL
        )
        return RSSFeedFetchResult(
          parsedFeed: RSSParsedFeed(title: "并发测试", articles: [article]),
          responseURL: feedURL,
          etag: nil,
          lastModified: nil,
          notModified: false
        )
      }
    )

    for index in 0..<10 {
      _ = try store.addFeed(
        url: try XCTUnwrap(URL(string: "https://example.com/concurrency-\(index).xml"))
      )
    }

    await store.refreshAll()

    let maximum = await probe.maximum()
    XCTAssertGreaterThan(maximum, 1)
    XCTAssertLessThanOrEqual(maximum, RSSReaderStore.maximumRefreshConcurrency)
  }

  func testStarringArticleArchivesMediaAndPersistsIt() async throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let mediaRootURL = rootURL.appendingPathComponent("RSSMedia", isDirectory: true)
    let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/archived.png"))
    let feed = RSSFeed(
      title: "归档测试",
      url: try XCTUnwrap(URL(string: "https://example.com/archive.xml"))
    )
    let article = RSSArticle(
      id: "archive-article",
      feedID: feed.id,
      title: "收藏后归档",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/archive")),
      contentHTML: "<p>正文</p><img src=\"\(imageURL.absoluteString)\">"
    )
    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([article])

    let archiver = RSSMediaArchiver(
      cacheDirectoryURL: mediaRootURL,
      downloadOperation: { request in
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: request.url ?? imageURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
        return (Data([0x89, 0x50, 0x4E, 0x47]), response)
      }
    )
    let store = RSSReaderStore(fileURL: fileURL, mediaArchiver: archiver)

    store.toggleStarred(article.id)
    for _ in 0..<100 {
      if !store.mediaAssets.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let asset = try XCTUnwrap(store.mediaAssets.first)
    XCTAssertEqual(asset.articleID, article.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: asset.localURL(in: mediaRootURL).path))

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.mediaAssets.map(\.id), [asset.id])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: asset.localURL(in: reopened.mediaCacheDirectoryURL).path
      )
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
  }
}

private actor RSSRefreshConcurrencyProbe {
  private var active = 0
  private var maximumActive = 0

  func enter() {
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func leave() {
    active = max(0, active - 1)
  }

  func maximum() -> Int {
    maximumActive
  }
}
