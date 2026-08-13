import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSReaderBootstrapTests: XCTestCase {
  @MainActor
  func testBootstrapLoadsBoundedHeaderPageThenCompletesWithoutDroppingRows() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderBootstrapTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "Bootstrap feed",
      url: try XCTUnwrap(URL(string: "https://example.com/feed"))
    )
    let articles = (0..<5).map { offset in
      RSSArticle(
        id: "article-\(offset)",
        feedID: feed.id,
        title: "Article \(offset)",
        publishedAt: Date(timeIntervalSince1970: TimeInterval(5 - offset)),
        contentHTML: "<p>Body \(offset)</p>"
      )
    }
    let snapshot = RSSReaderSnapshot(feeds: [feed], articles: articles)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let bootstrap = await RSSReaderStore.prepareBootstrap(
      fileURL: fileURL,
      pageSize: 2
    )
    XCTAssertEqual(bootstrap.articleHeaders.count, 2)
    XCTAssertEqual(bootstrap.articleCount, 5)
    XCTAssertFalse(bootstrap.loadedAllArticleHeaders)

    let store = RSSReaderStore(fileURL: fileURL, bootstrap: bootstrap)
    XCTAssertEqual(store.articleHeaders.count, 2)
    XCTAssertEqual(store.articleHeaderCount, 5)
    store.markRead("article-4")
    XCTAssertNil(store.articleHeaders.first(where: { $0.id == "article-4" }))
    XCTAssertEqual(store.statusMessage, "RSS 文章索引仍在加载，请稍后重试。")
    store.merge(
      [
        RSSParsedArticle(
          id: "partial-refresh-must-not-merge",
          title: "Must wait for the complete index"
        )
      ],
      into: feed
    )
    XCTAssertNil(
      store.articleHeaders.first(where: { $0.title == "Must wait for the complete index" })
    )
    await store.loadRemainingArticleHeadersIfNeeded()
    XCTAssertTrue(store.articleHeadersAreComplete)
    XCTAssertEqual(store.articleHeaders.count, 5)
    XCTAssertEqual(Set(store.articleHeaders.map(\.id)), Set(articles.map(\.id)))
  }

  @MainActor
  func testCustomFileManagerIsUsedForLegacyBootstrap() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RSSReaderBootstrapCustomManager-\(UUID().uuidString)", isDirectory: true)
    let manager = FileManager()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "Custom manager feed",
      url: try XCTUnwrap(URL(string: "https://example.com/custom"))
    )
    var snapshot = RSSReaderSnapshot(feeds: [feed])
    snapshot.schemaVersion = RSSReaderSnapshot.currentSchemaVersion
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let bootstrap = await RSSReaderStore.prepareBootstrap(
      fileURL: fileURL,
      fileManager: manager,
      pageSize: 10
    )
    XCTAssertEqual(bootstrap.feeds.map(\.id), [feed.id])
    XCTAssertEqual(bootstrap.statusMessage, "已将旧版 RSS 缓存迁移到 SQLite，原 JSON 已保留为备份。")
    XCTAssertTrue(manager.fileExists(atPath: RSSReaderStore.databaseFileURL(for: fileURL).path))
  }
}
