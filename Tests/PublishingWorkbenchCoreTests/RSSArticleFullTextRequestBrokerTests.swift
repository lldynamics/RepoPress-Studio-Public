import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RSSArticleFullTextRequestBrokerTests: XCTestCase {
  private enum TestError: Error { case expected }

  private actor Probe {
    var callCount = 0
    var activeCount = 0
    var maximumActiveCount = 0
    var activeCountByHost: [String: Int] = [:]
    var maximumActiveCountByHost: [String: Int] = [:]
    var hasReachedTwoConcurrentRequests = false
    var concurrencyWaiters: [CheckedContinuation<Void, Never>] = []

    func start(host: String) {
      callCount += 1
      activeCount += 1
      activeCountByHost[host, default: 0] += 1
      maximumActiveCount = max(maximumActiveCount, activeCount)
      maximumActiveCountByHost[host] = max(
        maximumActiveCountByHost[host] ?? 0,
        activeCountByHost[host] ?? 0
      )
    }

    func finish(host: String) {
      activeCount -= 1
      activeCountByHost[host, default: 1] -= 1
    }

    func startAndWaitForTwo(host: String) async {
      start(host: host)
      if activeCount >= 2 {
        hasReachedTwoConcurrentRequests = true
        let waiters = concurrencyWaiters
        concurrencyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      } else if !hasReachedTwoConcurrentRequests {
        await withCheckedContinuation { continuation in
          concurrencyWaiters.append(continuation)
        }
      }
    }
  }

  func testDeduplicatesConcurrentRequestsForTheSameArticle() async throws {
    let broker = RSSArticleFullTextRequestBroker()
    let probe = Probe()

    async let first = broker.perform(articleID: "same", host: "example.com") {
      await probe.start(host: "example.com")
      try await Task.sleep(for: .milliseconds(50))
      await probe.finish(host: "example.com")
      return Self.record(articleID: "same")
    }
    async let second = broker.perform(articleID: "same", host: "example.com") {
      await probe.start(host: "example.com")
      try await Task.sleep(for: .milliseconds(50))
      await probe.finish(host: "example.com")
      return Self.record(articleID: "same")
    }

    let records = try await [first, second]
    XCTAssertEqual(records.map(\.articleID), ["same", "same"])
    let callCount = await probe.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testLimitsGlobalAndPerHostConcurrency() async throws {
    let broker = RSSArticleFullTextRequestBroker(
      maximumConcurrentRequests: 2,
      maximumConcurrentRequestsPerHost: 1
    )
    let probe = Probe()

    async let first = Self.run(
      broker: broker,
      probe: probe,
      articleID: "first",
      host: "one.example"
    )
    async let second = Self.run(
      broker: broker,
      probe: probe,
      articleID: "second",
      host: "one.example"
    )
    async let third = Self.run(
      broker: broker,
      probe: probe,
      articleID: "third",
      host: "two.example"
    )

    _ = try await [first, second, third]
    let maximumActiveCount = await probe.maximumActiveCount
    let maximumActiveCountByHost = await probe.maximumActiveCountByHost
    XCTAssertEqual(maximumActiveCount, 2)
    XCTAssertEqual(maximumActiveCountByHost["one.example"], 1)
    XCTAssertEqual(maximumActiveCountByHost["two.example"], 1)
  }

  func testFailureClearsInFlightEntryForRetry() async throws {
    let broker = RSSArticleFullTextRequestBroker()
    let probe = Probe()

    do {
      _ = try await broker.perform(articleID: "retry", host: "example.com") {
        await probe.start(host: "example.com")
        await probe.finish(host: "example.com")
        throw TestError.expected
      }
      XCTFail("首次请求应失败")
    } catch TestError.expected {
      // Expected.
    }

    let retried = try await broker.perform(articleID: "retry", host: "example.com") {
      await probe.start(host: "example.com")
      await probe.finish(host: "example.com")
      return Self.record(articleID: "retry")
    }

    XCTAssertEqual(retried.status, .ready)
    let callCount = await probe.callCount
    XCTAssertEqual(callCount, 2)
  }

  private static func run(
    broker: RSSArticleFullTextRequestBroker,
    probe: Probe,
    articleID: String,
    host: String
  ) async throws -> RSSArticleFullTextRecord {
    try await broker.perform(articleID: articleID, host: host) {
      await probe.startAndWaitForTwo(host: host)
      await probe.finish(host: host)
      return Self.record(articleID: articleID)
    }
  }

  private static func record(articleID: String) -> RSSArticleFullTextRecord {
    .ready(
      articleID: articleID,
      contentHTML: "<p>full text</p>",
      plainText: "full text",
      confidence: 0.9
    )
  }
}
