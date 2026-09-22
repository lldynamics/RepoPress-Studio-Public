import Foundation
import XCTest

@testable import PublishingKnowledgeCore

private final class RSSQueryProgressGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var waitsForProgress = true

  /// The one-shot flag is protected by `lock`; immutable thread-safe semaphores
  /// make cancellation timing deterministic across detached-query boundaries.
  func pauseAtFirstProgressHandlerInvocation() {
    lock.lock()
    let shouldWait = waitsForProgress
    waitsForProgress = false
    lock.unlock()
    guard shouldWait else { return }
    entered.signal()
    release.wait()
  }
}

@MainActor
final class WorkspacePaletteContentSearchTests: XCTestCase {
  func testKnowledgeSearchFindsImportedBodyWithoutPreparingSemanticIndex() async throws {
    let rootURL = try temporaryDirectory(named: "palette-knowledge")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.txt")
    try "资料标题\nOCR 正文包含星海导航。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    _ = try await service.commit(preview)

    let results = try await service.workspacePaletteSearch(query: "星海导航")

    XCTAssertEqual(results.count, 1)
    let hit = try XCTUnwrap(results.first)
    XCTAssertTrue(hit.chunk.content.contains("星海导航"))
    XCTAssertEqual(hit.signals, [.fullText])
  }

  func testRSSSearchFindsPersistedCachedFullTextOutsideVisibleHeaders() async throws {
    let rootURL = try temporaryDirectory(named: "palette-rss")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "缓存测试订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let article = RSSArticle(
      id: "cached-full-text",
      feedID: feed.id,
      title: "普通 RSS 标题",
      link: try XCTUnwrap(URL(string: "https://example.com/article")),
      summaryHTML: "<p>摘要没有关键词。</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
      try database.upsertFullTextRecord(
        .ready(
          articleID: article.id,
          contentHTML: "<p>深空航线连接多个星球。 Cached full text contains cachedbodymarker.</p>",
          plainText: "深空航线连接多个星球。 Cached full text contains cachedbodymarker.",
          sourceURL: article.link,
          resolvedURL: article.link,
          extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
          extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
          confidence: 0.9,
          attemptedAt: Date()
        )
      )
    }
    let store = RSSReaderStore(fileURL: fileURL)
    let revisionBeforeSearch = store.mutationRevision

    for query in ["深空航线", "cachedbodymarker"] {
      let results = try await store.workspacePaletteSearch(query: query)
      XCTAssertEqual(results.map(\.id), [article.id])
      let hit = try XCTUnwrap(results.first)
      XCTAssertTrue(hit.snippet.contains(query))
      XCTAssertEqual(store.mutationRevision, revisionBeforeSearch)
    }
  }

  func testRSSSearchUsesFeedBodyForSnippetWhenNoCachedPageExists() async throws {
    let rootURL = try temporaryDirectory(named: "palette-rss-feed-body")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      title: "正文测试订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let article = RSSArticle(
      id: "feed-body",
      feedID: feed.id,
      title: "标题没有关键词",
      link: try XCTUnwrap(URL(string: "https://example.com/feed-body")),
      summaryHTML: "<p>摘要也没有关键词。</p>",
      contentHTML: "<p>星际港口连接多条航线。 Feed body contains feedbodymarker.</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }
    let store = RSSReaderStore(fileURL: fileURL)

    for query in ["星际港口", "feedbodymarker"] {
      let results = try await store.workspacePaletteSearch(query: query)
      XCTAssertEqual(results.map(\.id), [article.id])
      let hit = try XCTUnwrap(results.first)
      XCTAssertTrue(hit.snippet.contains(query))
    }
  }

  func testRSSSnippetPrefersMatchingSnapshotWhenFeedBodyDoesNotMatch() {
    let feedBody = RSSWorkspacePaletteSearchPresentation.preferredFeedBodyText(
      query: "snapshotmarker",
      contentHTML: "<p>订阅正文没有匹配内容。</p>",
      snapshotHTML: "<p>保存的网页快照含有 snapshotmarker。</p>"
    )

    XCTAssertTrue(feedBody.contains("snapshotmarker"))
  }

  func testEmptyQueriesAvoidContentSearch() async throws {
    let rootURL = try temporaryDirectory(named: "palette-empty")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let rssStore = RSSReaderStore(fileURL: rootURL.appendingPathComponent("reader.sqlite"))

    let libraryResults = try await library.workspacePaletteSearch(query: "   ")
    let rssResults = try await rssStore.workspacePaletteSearch(query: "   ")

    XCTAssertTrue(libraryResults.isEmpty)
    XCTAssertTrue(rssResults.isEmpty)
  }

  func testCancelledRSSHeaderQueryStopsWaitingForDatabaseLock() async throws {
    let rootURL = try temporaryDirectory(named: "rss-cancellable-lock")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let lockWaitStarted = DispatchSemaphore(value: 0)
    let lockHeld = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)
    let queryFinished = DispatchSemaphore(value: 0)
    let database = try RSSReaderDatabase(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      queryHooks: RSSReaderDatabaseQueryHooks(
        didWaitForCancellableLock: { lockWaitStarted.signal() },
        didInvokeProgressHandler: {}
      )
    )
    let feed = RSSFeed(
      title: "可取消锁测试",
      url: try XCTUnwrap(URL(string: "https://example.com/lock.xml"))
    )
    try database.upsertFeed(feed)
    try database.upsertArticles([
      RSSArticle(id: "lock-result", feedID: feed.id, title: "锁等待后仍可查询")
    ])

    let lockOwner = Task.detached {
      database.withLock {
        lockHeld.signal()
        releaseLock.wait()
      }
    }
    await waitForRSSSemaphore(lockHeld)

    let query = Task.detached {
      defer { queryFinished.signal() }
      return try database.articleHeaders(for: .all, searchText: "", unreadOnly: false, limit: 1)
    }
    await waitForRSSSemaphore(lockWaitStarted)
    query.cancel()
    // Prove cancellation completes while another operation still owns the lock.
    await waitForRSSSemaphore(queryFinished)
    releaseLock.signal()
    await lockOwner.value

    do {
      _ = try await query.value
      XCTFail("被取消的查询不应在锁释放后继续执行")
    } catch is CancellationError {
      // Expected cancellation path.
    } catch {
      XCTFail("应报告取消，实际为：\(error)")
    }

    XCTAssertEqual(try database.articleHeaders(limit: 1).map(\.id), ["lock-result"])
    try database.upsertFeed(
      RSSFeed(title: "取消后仍可写入", url: try XCTUnwrap(URL(string: "https://example.com/write.xml")))
    )
    XCTAssertEqual(try database.feeds().count, 2)
  }

  func testCancelledRSSHeaderQueryInterruptsSQLiteAndRestoresFollowingRead() async throws {
    let rootURL = try temporaryDirectory(named: "rss-cancellable-progress")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let progressGate = RSSQueryProgressGate()
    let database = try RSSReaderDatabase(
      fileURL: rootURL.appendingPathComponent("reader.sqlite"),
      queryHooks: RSSReaderDatabaseQueryHooks(
        didWaitForCancellableLock: {},
        didInvokeProgressHandler: { progressGate.pauseAtFirstProgressHandlerInvocation() }
      )
    )
    let feed = RSSFeed(
      title: "可取消计算测试",
      url: try XCTUnwrap(URL(string: "https://example.com/progress.xml"))
    )
    try database.upsertFeed(feed)
    try database.upsertArticles(
      (0..<128).map { index in
        RSSArticle(
          id: "progress-\(index)",
          feedID: feed.id,
          title: "progressmarker \(index)",
          publishedAt: Date(timeIntervalSince1970: Double(index))
        )
      }
    )

    let query = Task.detached {
      try database.articleHeaders(
        for: .all,
        searchText: "progressmarker",
        unreadOnly: false,
        limit: nil
      )
    }
    await waitForRSSSemaphore(progressGate.entered)
    query.cancel()
    progressGate.release.signal()

    do {
      _ = try await query.value
      XCTFail("被取消的 FTS 查询不应返回部分结果")
    } catch is CancellationError {
      // Expected cancellation path.
    } catch {
      XCTFail("应报告取消，实际为：\(error)")
    }

    let followingResults = try database.articleHeaders(
      for: .all,
      searchText: "progressmarker",
      unreadOnly: false,
      limit: nil
    )
    XCTAssertEqual(followingResults.map(\.id).count, 128)
    try database.upsertArticles([
      RSSArticle(id: "progress-after", feedID: feed.id, title: "progressmarker after")
    ])
    XCTAssertEqual(
      try database.articleHeaders(
        for: .all,
        searchText: "progressmarker",
        unreadOnly: false,
        limit: nil
      ).map(\.id).count,
      129
    )
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private func waitForRSSSemaphore(
  _ semaphore: DispatchSemaphore,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let signalled = await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
    }
  }
  XCTAssertTrue(signalled, "Timed out waiting for the query checkpoint", file: file, line: line)
}
