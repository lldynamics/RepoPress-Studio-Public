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

  func testRefreshRunsPayloadMergeAndPersistenceOffMainActor() async throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/off-main.xml"))
    let store = RSSReaderStore(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      fetchOperation: { url, _, _ in
        let article = RSSParsedArticle(
          id: "off-main-article",
          title: "后台合并",
          link: url,
          summaryHTML: "摘要",
          contentHTML: "正文"
        )
        return RSSFeedFetchResult(
          parsedFeed: RSSParsedFeed(title: "后台合并订阅", articles: [article]),
          responseURL: url,
          etag: nil,
          lastModified: nil,
          notModified: false
        )
      }
    )
    let feedID = try store.addFeed(url: feedURL)

    await store.refresh(feedID: feedID)

    XCTAssertTrue(store.lastRefreshWorkRanOffMainActor)
    XCTAssertEqual(store.articleHeader(id: "\(feedID.uuidString):off-main-article")?.title, "后台合并")
    XCTAssertEqual(store.lastRefreshSummary, RSSRefreshSummary(successCount: 1))
  }

  func testRefreshPreservesUserStateChangedDuringDetachedMerge() async throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/rebase.xml"))
    let gate = RSSRefreshGate()
    let calls = RSSRefreshCallCounter()
    let store = RSSReaderStore(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      fetchOperation: { url, _, _ in
        let call = await calls.next()
        let article = RSSParsedArticle(
          id: "rebase-article",
          title: call == 1 ? "初始标题" : "更新标题",
          link: url,
          summaryHTML: call == 1 ? "初始摘要" : "更新摘要",
          contentHTML: call == 1 ? "初始正文" : "更新正文"
        )
        return RSSFeedFetchResult(
          parsedFeed: RSSParsedFeed(title: "状态保留", articles: [article]),
          responseURL: url,
          etag: nil,
          lastModified: nil,
          notModified: false
        )
      }
    )
    let feedID = try store.addFeed(url: feedURL)
    await store.refresh(feedID: feedID)
    let articleID = "\(feedID.uuidString):rebase-article"

    store.refreshWorkerBeforePersistenceHook = {
      await gate.markStarted()
      await gate.waitForRelease()
    }
    let refreshTask = Task { @MainActor in
      await store.refresh(feedID: feedID)
    }
    await gate.waitForStart()
    store.markRead(articleID, isRead: true)
    store.toggleStarred(articleID)
    store.setArticleTags(["用户标签"], for: articleID)
    await gate.release()
    await refreshTask.value
    store.refreshWorkerBeforePersistenceHook = nil

    let header = try XCTUnwrap(store.articleHeader(id: articleID))
    XCTAssertEqual(header.title, "更新标题")
    XCTAssertTrue(header.isRead)
    XCTAssertTrue(header.isStarred)
    XCTAssertEqual(header.tags, ["用户标签"])

    let reopened = RSSReaderStore(fileURL: rootURL.appendingPathComponent("reader.sqlite"))
    let persisted = try XCTUnwrap(reopened.articleHeader(id: articleID))
    XCTAssertTrue(persisted.isRead)
    XCTAssertTrue(persisted.isStarred)
    XCTAssertEqual(persisted.tags, ["用户标签"])
  }

  func testCancelledRefreshDoesNotCommitAfterDetachedMergeGate() async throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/cancelled.xml"))
    let gate = RSSRefreshGate()
    let store = RSSReaderStore(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      fetchOperation: { url, _, _ in
        let article = RSSParsedArticle(
          id: "cancelled-article",
          title: "不应提交",
          link: url
        )
        return RSSFeedFetchResult(
          parsedFeed: RSSParsedFeed(title: "取消测试", articles: [article]),
          responseURL: url,
          etag: nil,
          lastModified: nil,
          notModified: false
        )
      }
    )
    let feedID = try store.addFeed(url: feedURL)
    store.refreshWorkerBeforePersistenceHook = {
      await gate.markStarted()
      await gate.waitForRelease()
    }
    let refreshTask = Task { @MainActor in
      await store.refresh(feedID: feedID)
    }

    await gate.waitForStart()
    refreshTask.cancel()
    await gate.release()
    await refreshTask.value
    store.refreshWorkerBeforePersistenceHook = nil

    XCTAssertFalse(store.articleHeaders.contains { $0.title == "不应提交" })
    XCTAssertEqual(store.lastRefreshSummary, RSSRefreshSummary(skippedCount: 1))
    let reopened = RSSReaderStore(fileURL: rootURL.appendingPathComponent("reader.sqlite"))
    XCTAssertFalse(reopened.articleHeaders.contains { $0.title == "不应提交" })
  }

  func testRefreshCannotResurrectFeedAfterURLDrift() async throws {
    let rootURL = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let oldURL = try XCTUnwrap(URL(string: "https://example.com/old.xml"))
    let newURL = try XCTUnwrap(URL(string: "https://example.com/new.xml"))
    let gate = RSSRefreshGate()
    let store = RSSReaderStore(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      fetchOperation: { url, _, _ in
        await gate.markStarted()
        await gate.waitForRelease()
        let article = RSSParsedArticle(
          id: "stale-response",
          title: "旧地址响应",
          link: url
        )
        return RSSFeedFetchResult(
          parsedFeed: RSSParsedFeed(title: "旧地址响应", articles: [article]),
          responseURL: url,
          etag: nil,
          lastModified: nil,
          notModified: false
        )
      }
    )
    let feedID = try store.addFeed(url: oldURL)
    let refreshTask = Task { @MainActor in
      await store.refresh(feedID: feedID)
    }

    await gate.waitForStart()
    try store.updateFeedURL(feedID: feedID, newURL: newURL)
    await gate.release()
    await refreshTask.value

    XCTAssertEqual(store.feeds.first(where: { $0.id == feedID })?.url, newURL)
    XCTAssertFalse(store.articleHeaders.contains { $0.title == "旧地址响应" })
    XCTAssertEqual(store.lastRefreshSummary, RSSRefreshSummary(skippedCount: 1))

    let reopened = RSSReaderStore(fileURL: rootURL.appendingPathComponent("reader.sqlite"))
    XCTAssertEqual(reopened.feeds.first(where: { $0.id == feedID })?.url, newURL)
    XCTAssertFalse(reopened.articleHeaders.contains { $0.title == "旧地址响应" })
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

private actor RSSRefreshCallCounter {
  private var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

private actor RSSRefreshGate {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func waitForStart() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func waitForRelease() async {
    if released { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }
}
