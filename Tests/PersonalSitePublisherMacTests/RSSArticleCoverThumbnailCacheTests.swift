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
  private let dataByPath: [String: Data]

  init(delay: Duration = .milliseconds(200), dataByPath: [String: Data] = [:]) {
    self.delay = delay
    self.dataByPath = dataByPath
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
    return (dataByPath[request.url!.path] ?? Data([1, 2, 3]), response)
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
    let cache = makeCache(probe: probe, maximumConcurrentRequests: 2)
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

  func testByteBudgetEvictsLeastRecentlyUsedDataAndTracksActualSizes() async {
    let firstData = Data(repeating: 0xA1, count: 4)
    let secondData = Data(repeating: 0xB2, count: 3)
    let thirdData = Data(repeating: 0xC3, count: 6)
    let probe = CoverDownloadProbe(
      delay: .zero,
      dataByPath: ["/first.png": firstData, "/second.png": secondData, "/third.png": thirdData]
    )
    let cache = makeCache(probe: probe, maximumCachedBytes: 10)
    let firstURL = URL(string: "https://example.com/first.png")!
    let secondURL = URL(string: "https://example.com/second.png")!
    let thirdURL = URL(string: "https://example.com/third.png")!

    let firstResult = await cache.data(for: firstURL)
    let secondResult = await cache.data(for: secondURL)
    XCTAssertEqual(firstResult, firstData)
    XCTAssertEqual(secondResult, secondData)
    await assertCacheState(cache, entries: 2, bytes: 7)

    let refreshedFirst = await cache.data(for: firstURL)
    let thirdResult = await cache.data(for: thirdURL)
    let retainedFirst = await cache.data(for: firstURL)
    let retainedThird = await cache.data(for: thirdURL)
    XCTAssertEqual(refreshedFirst, firstData)
    XCTAssertEqual(thirdResult, thirdData)
    XCTAssertEqual(retainedFirst, firstData)
    XCTAssertEqual(retainedThird, thirdData)
    let startedBeforeRetry = await probe.started
    XCTAssertEqual(startedBeforeRetry, 3)
    await assertCacheState(cache, entries: 2, bytes: 10)

    let retriedSecond = await cache.data(for: secondURL)
    let startedAfterRetry = await probe.started
    XCTAssertEqual(retriedSecond, secondData)
    XCTAssertEqual(startedAfterRetry, 4)
    await assertCacheState(cache, entries: 2, bytes: 9)
  }

  func testEntryCountLimitRemainsNinetySixAndRefreshesOnHit() async {
    let probe = CoverDownloadProbe(delay: .zero)
    let cache = makeCache(probe: probe)
    let urls = (0..<97).map { URL(string: "https://example.com/count-\($0).png")! }
    for url in urls.prefix(96) {
      let result = await cache.data(for: url)
      XCTAssertEqual(result, Data([1, 2, 3]))
    }
    await assertCacheState(cache, entries: 96, bytes: 288)

    let refreshedFirst = await cache.data(for: urls[0])
    let newest = await cache.data(for: urls[96])
    let retainedFirst = await cache.data(for: urls[0])
    XCTAssertEqual(refreshedFirst, Data([1, 2, 3]))
    XCTAssertEqual(newest, Data([1, 2, 3]))
    XCTAssertEqual(retainedFirst, Data([1, 2, 3]))
    let startedBeforeRetry = await probe.started
    XCTAssertEqual(startedBeforeRetry, 97)
    await assertCacheState(cache, entries: 96, bytes: 288)

    let retriedSecond = await cache.data(for: urls[1])
    let startedAfterRetry = await probe.started
    XCTAssertEqual(retriedSecond, Data([1, 2, 3]))
    XCTAssertEqual(startedAfterRetry, 98)
    await assertCacheState(cache, entries: 96, bytes: 288)
  }

  func testOversizedResultIsDeliveredWithoutEvictingRetainedData() async {
    let smallData = Data([1, 2])
    let probe = CoverDownloadProbe(delay: .zero, dataByPath: ["/small.png": smallData])
    let cache = makeCache(probe: probe, maximumCachedBytes: 2)
    let smallURL = URL(string: "https://example.com/small.png")!
    let oversizedURL = URL(string: "https://example.com/oversized.png")!

    let smallResult = await cache.data(for: smallURL)
    let oversizedResult = await cache.data(for: oversizedURL)
    let oversizedRetry = await cache.data(for: oversizedURL)
    let retainedSmall = await cache.data(for: smallURL)
    XCTAssertEqual(smallResult, smallData)
    XCTAssertEqual(oversizedResult, Data([1, 2, 3]))
    XCTAssertEqual(oversizedRetry, Data([1, 2, 3]))
    XCTAssertEqual(retainedSmall, smallData)
    let started = await probe.started
    XCTAssertEqual(started, 3)
    await assertCacheState(cache, entries: 1, bytes: 2)
  }

  func testZeroAndNegativeByteBudgetsDisableRetention() async {
    let url = URL(string: "https://example.com/uncached.png")!
    for budget in [0, -1] {
      let probe = CoverDownloadProbe(delay: .zero)
      let cache = makeCache(probe: probe, maximumCachedBytes: budget)
      let first = await cache.data(for: url)
      let second = await cache.data(for: url)
      XCTAssertEqual(first, Data([1, 2, 3]))
      XCTAssertEqual(second, Data([1, 2, 3]))
      let started = await probe.started
      XCTAssertEqual(started, 2)
      await assertCacheState(cache, entries: 0, bytes: 0)
    }
  }

  func testPressureClearsCacheAndKeepsActiveAndQueuedConsumersUntilRecovery() async throws {
    let probe = StubbornCoverDownloadProbe()
    let cache = makeCache(probe: probe, maximumConcurrentRequests: 1)
    let warmURL = URL(string: "https://example.com/warm.png")!
    let activeURL = URL(string: "https://example.com/active.png")!
    let queuedURL = URL(string: "https://example.com/queued.png")!
    let warm = Task { await cache.data(for: warmURL) }
    try await waitUntil { await probe.started == 1 }
    await probe.complete(1)
    let warmResult = await warm.value
    XCTAssertEqual(warmResult, Data([1]))
    await assertCacheState(cache, entries: 1, bytes: 1)

    let active = Task { await cache.data(for: activeURL) }
    try await waitUntil { await probe.started == 2 }
    let cancelledConsumer = Task { await cache.data(for: activeURL) }
    try await waitUntil { await cache.pendingConsumerCount(for: activeURL) == 2 }
    cancelledConsumer.cancel()
    let cancelledResult = await cancelledConsumer.value
    XCTAssertNil(cancelledResult)
    let queued = Task { await cache.data(for: queuedURL) }
    try await waitUntil { await cache.pendingConsumerCount(for: queuedURL) == 1 }

    await cache.setCacheRetentionEnabled(false, generation: 1)
    await assertCacheState(cache, entries: 0, bytes: 0)
    let activeConsumers = await cache.pendingConsumerCount(for: activeURL)
    let queuedConsumers = await cache.pendingConsumerCount(for: queuedURL)
    let startedDuringPressure = await probe.started
    XCTAssertEqual(activeConsumers, 1)
    XCTAssertEqual(queuedConsumers, 1)
    XCTAssertEqual(startedDuringPressure, 2)

    await probe.complete(2)
    let activeResult = await active.value
    XCTAssertEqual(activeResult, Data([2]))
    await assertCacheState(cache, entries: 0, bytes: 0)
    try await waitUntil { await probe.started == 3 }
    await probe.complete(3)
    let queuedResult = await queued.value
    XCTAssertEqual(queuedResult, Data([3]))
    await assertCacheState(cache, entries: 0, bytes: 0)

    await cache.setCacheRetentionEnabled(true, generation: 2)
    let recovered = Task { await cache.data(for: activeURL) }
    try await waitUntil { await probe.started == 4 }
    await probe.complete(4)
    let recoveredResult = await recovered.value
    let cachedResult = await cache.data(for: activeURL)
    XCTAssertEqual(recoveredResult, Data([4]))
    XCTAssertEqual(cachedResult, Data([4]))
    let startedAfterRecovery = await probe.started
    XCTAssertEqual(startedAfterRecovery, 4)
    await assertCacheState(cache, entries: 1, bytes: 1)
  }

  func testOlderGenerationCannotRestoreOrDisableRetention() async {
    let probe = CoverDownloadProbe(delay: .zero)
    let cache = makeCache(probe: probe)
    let url = URL(string: "https://example.com/generation.png")!
    let initial = await cache.data(for: url)
    XCTAssertEqual(initial, Data([1, 2, 3]))

    await cache.setCacheRetentionEnabled(false, generation: 4)
    await cache.setCacheRetentionEnabled(true, generation: 3)
    let pressured = await cache.data(for: url)
    XCTAssertEqual(pressured, Data([1, 2, 3]))
    await assertCacheState(cache, entries: 0, bytes: 0)

    await cache.setCacheRetentionEnabled(true, generation: 5)
    let recovered = await cache.data(for: url)
    await cache.setCacheRetentionEnabled(false, generation: 4)
    let retained = await cache.data(for: url)
    XCTAssertEqual(recovered, Data([1, 2, 3]))
    XCTAssertEqual(retained, Data([1, 2, 3]))
    let started = await probe.started
    XCTAssertEqual(started, 3)
    await assertCacheState(cache, entries: 1, bytes: 3)
  }

  func testMatchingGenerationCanChangeRetention() async {
    let probe = CoverDownloadProbe(delay: .zero)
    let cache = makeCache(probe: probe)
    let url = URL(string: "https://example.com/matching-generation.png")!

    await cache.setCacheRetentionEnabled(false, generation: 0)
    let disabledResult = await cache.data(for: url)
    XCTAssertEqual(disabledResult, Data([1, 2, 3]))
    await assertCacheState(cache, entries: 0, bytes: 0)

    await cache.setCacheRetentionEnabled(true, generation: 0)
    let enabledResult = await cache.data(for: url)
    XCTAssertEqual(enabledResult, Data([1, 2, 3]))
    await assertCacheState(cache, entries: 1, bytes: 3)
  }

  private func makeCache(
    probe: CoverDownloadProbe,
    maximumConcurrentRequests: Int = 4,
    maximumQueuedRequests: Int = 128,
    maximumCachedBytes: Int = RSSArticleCoverThumbnailCache.defaultMaximumCachedBytes
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
      maximumQueuedRequests: maximumQueuedRequests,
      maximumCachedBytes: maximumCachedBytes
    )
  }

  private func makeCache(
    probe: StubbornCoverDownloadProbe,
    maximumConcurrentRequests: Int
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
      maximumConcurrentRequests: maximumConcurrentRequests
    )
  }

  private func assertCacheState(
    _ cache: RSSArticleCoverThumbnailCache,
    entries: Int,
    bytes: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let entryCount = await cache.cachedEntryCount
    let byteCount = await cache.cachedByteCount
    XCTAssertEqual(entryCount, entries, file: file, line: line)
    XCTAssertEqual(byteCount, bytes, file: file, line: line)
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
