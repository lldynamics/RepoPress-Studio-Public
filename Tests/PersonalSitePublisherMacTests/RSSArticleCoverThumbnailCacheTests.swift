import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

private actor CoverDownloadProbe {
  private(set) var started = 0
  private(set) var active = 0
  private(set) var peak = 0
  private(set) var cancelled = 0
  let delay: Duration

  init(delay: Duration = .milliseconds(200)) {
    self.delay = delay
  }

  func download(
    request: URLRequest,
    maximumByteCount: Int,
    allowsPrivateNetworkAccess: Bool
  ) async throws -> (Data, HTTPURLResponse) {
    started += 1
    active += 1
    peak = max(peak, active)
    do {
      try await Task.sleep(for: delay)
      active -= 1
    } catch {
      cancelled += 1
      active -= 1
      throw error
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "image/png"]
    )!
    return (Data([1, 2, 3]), response)
  }
}

private actor StubbornCoverDownloadProbe {
  private(set) var started = 0
  private var completions: [Int: CheckedContinuation<Data, Never>] = [:]

  func download(
    request: URLRequest,
    maximumByteCount: Int,
    allowsPrivateNetworkAccess: Bool
  ) async throws -> (Data, HTTPURLResponse) {
    started += 1
    let number = started
    // Deliberately ignore cancellation to expose a late old completion.
    let data = await withCheckedContinuation { continuation in
      completions[number] = continuation
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "image/png"]
    )!
    return (data, response)
  }

  func complete(_ number: Int) {
    completions.removeValue(forKey: number)?.resume(returning: Data([UInt8(number)]))
  }
}

final class RSSArticleCoverThumbnailCacheTests: XCTestCase {
  func testCancellingOneConsumerKeepsSharedDownloadAlive() async throws {
    let probe = CoverDownloadProbe()
    let cache = makeCache(probe: probe)
    let url = URL(string: "https://example.com/shared.png")!
    let first = Task { await cache.data(for: url) }
    try await waitUntil { await cache.pendingConsumerCount(for: url) == 1 }
    let second = Task { await cache.data(for: url) }
    try await waitUntil { await cache.pendingConsumerCount(for: url) == 2 }

    first.cancel()
    let cancelledResult = await first.value
    XCTAssertNil(cancelledResult)
    let sharedResult = await second.value
    XCTAssertEqual(sharedResult, Data([1, 2, 3]))
    let started = await probe.started
    let cancelled = await probe.cancelled
    XCTAssertEqual(started, 1)
    XCTAssertEqual(cancelled, 0)
  }

  func testLastConsumerCancelsDownloadAndLaterSubscriptionRetries() async throws {
    let probe = CoverDownloadProbe()
    let cache = makeCache(probe: probe, maximumConcurrentRequests: 1)
    let url = URL(string: "https://example.com/retry.png")!
    let first = Task { await cache.data(for: url) }
    try await waitUntil { await probe.started == 1 }
    first.cancel()
    let cancelledResult = await first.value
    XCTAssertNil(cancelledResult)
    try await waitUntil { await probe.cancelled == 1 }

    let retry = Task { await cache.data(for: url) }
    let retryResult = await retry.value
    let started = await probe.started
    XCTAssertEqual(retryResult, Data([1, 2, 3]))
    XCTAssertEqual(started, 2)
  }

  func testGlobalConcurrencyAndQueuedRequestLimit() async throws {
    let probe = CoverDownloadProbe(delay: .milliseconds(600))
    let cache = makeCache(
      probe: probe,
      maximumConcurrentRequests: 2,
      maximumQueuedRequests: 2
    )
    let urls = (0..<4).map { URL(string: "https://example.com/cover-\($0).png")! }
    let first = urls.prefix(2).map { url in Task { await cache.data(for: url) } }
    try await waitUntil { await probe.started == 2 }
    let queued = urls.suffix(2).map { url in Task { await cache.data(for: url) } }
    for url in urls.suffix(2) {
      try await waitUntil { await cache.pendingConsumerCount(for: url) == 1 }
    }
    for task in first + queued {
      let result = await task.value
      XCTAssertEqual(result, Data([1, 2, 3]))
    }
    let started = await probe.started
    let peak = await probe.peak
    XCTAssertEqual(started, 4)
    XCTAssertEqual(peak, 2)
  }

  func testFullQueueDropsOldPendingConsumerAndAllowsResubscription() async throws {
    let probe = CoverDownloadProbe(delay: .milliseconds(800))
    let cache = makeCache(
      probe: probe,
      maximumConcurrentRequests: 1,
      maximumQueuedRequests: 1
    )
    let activeURL = URL(string: "https://example.com/active.png")!
    let evictedURL = URL(string: "https://example.com/evicted.png")!
    let newestURL = URL(string: "https://example.com/newest.png")!
    let active = Task { await cache.data(for: activeURL) }
    try await waitUntil { await probe.started == 1 }
    let evicted = Task { await cache.data(for: evictedURL) }
    try await waitUntil { await cache.pendingConsumerCount(for: evictedURL) == 1 }
    let newest = Task { await cache.data(for: newestURL) }
    try await waitUntil { await cache.pendingConsumerCount(for: newestURL) == 1 }
    let evictedResult = await evicted.value
    let activeResult = await active.value
    let newestResult = await newest.value
    let resubscribedResult = await cache.data(for: evictedURL)
    let started = await probe.started
    let peak = await probe.peak
    XCTAssertNil(evictedResult)
    XCTAssertEqual(activeResult, Data([1, 2, 3]))
    XCTAssertEqual(newestResult, Data([1, 2, 3]))
    XCTAssertEqual(resubscribedResult, Data([1, 2, 3]))
    XCTAssertEqual(started, 3)
    XCTAssertEqual(peak, 1)
  }

  func testLateCancelledCompletionDoesNotReplaceNewRequestForSameURL() async throws {
    let probe = StubbornCoverDownloadProbe()
    let cache = RSSArticleCoverThumbnailCache(
      loader: RSSArticleCoverImageLoader(
        downloadOperation: { request, maximumByteCount, allowsPrivateNetworkAccess in
          try await probe.download(
            request: request,
            maximumByteCount: maximumByteCount,
            allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
          )
        }
      ),
      maximumConcurrentRequests: 2
    )
    let url = URL(string: "https://example.com/late.png")!
    let first = Task { await cache.data(for: url) }
    try await waitUntil { await probe.started == 1 }
    first.cancel()
    let cancelledResult = await first.value
    XCTAssertNil(cancelledResult)

    let second = Task { await cache.data(for: url) }
    try await waitUntil { await probe.started == 2 }
    await probe.complete(1)
    await probe.complete(2)
    let freshResult = await second.value
    let cachedResult = await cache.data(for: url)
    XCTAssertEqual(freshResult, Data([2]))
    XCTAssertEqual(cachedResult, Data([2]))
  }

  private func makeCache(
    probe: CoverDownloadProbe,
    maximumConcurrentRequests: Int = 4,
    maximumQueuedRequests: Int = 128
  ) -> RSSArticleCoverThumbnailCache {
    RSSArticleCoverThumbnailCache(
      loader: RSSArticleCoverImageLoader(
        downloadOperation: { request, maximumByteCount, allowsPrivateNetworkAccess in
          try await probe.download(
            request: request,
            maximumByteCount: maximumByteCount,
            allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
          )
        }
      ),
      maximumConcurrentRequests: maximumConcurrentRequests,
      maximumQueuedRequests: maximumQueuedRequests
    )
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    for _ in 0..<100 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for thumbnail request state")
  }
}
