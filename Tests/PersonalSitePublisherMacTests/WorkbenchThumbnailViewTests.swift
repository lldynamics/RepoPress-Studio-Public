import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import XCTest
@testable import PersonalSitePublisherMac

final class WorkbenchThumbnailViewTests: XCTestCase {
  func testRequestConvertsPixelBudgetToDisplayPoints() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 512,
      displayScale: 2
    )

    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 256, height: 256))
    XCTAssertEqual(request.quickLookRequest.scale, 2)
    XCTAssertEqual(request.quickLookRequest.representationTypes, .thumbnail)
  }

  func testRequestClampsPixelBudget() {
    let tooSmall = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/small.png"),
      maxPixelSize: 0,
      displayScale: 1
    )
    let tooLarge = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/large.png"),
      maxPixelSize: 8_192,
      displayScale: 1
    )

    XCTAssertEqual(tooSmall.quickLookRequest.size, CGSize(width: 1, height: 1))
    XCTAssertEqual(tooLarge.quickLookRequest.size, CGSize(width: 4_096, height: 4_096))
  }

  func testRequestFallsBackToUnitScaleForInvalidDisplayScale() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 128,
      displayScale: .nan
    )

    XCTAssertEqual(request.quickLookRequest.scale, 1)
    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 128, height: 128))
  }

  func testImageIOThumbnailRespectsPixelBudgetFor4KImage() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("workbench-thumbnail-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let width = 4_096
    let height = 2_160
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let thumbnail = try XCTUnwrap(
      WorkbenchImageIOThumbnailDecoder.downsampledImage(
        at: url,
        maxPixelSize: WorkbenchThumbnailSizing.listMaxPixelSize
      )
    )
    XCTAssertLessThanOrEqual(thumbnail.width, WorkbenchThumbnailSizing.listMaxPixelSize)
    XCTAssertLessThanOrEqual(thumbnail.height, WorkbenchThumbnailSizing.listMaxPixelSize)
  }

  func testCacheLimitsConcurrentUtilityDecodesAndPrioritizesVisibleRequests() async throws {
    let image = try makeDecodedImage()
    let decoder = SuspendedThumbnailDecoder()
    let cache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: 1_024 * 1_024,
      maximumConcurrentDecodes: 1,
      decoder: { request in await decoder.decode(request) }
    )
    let first = request(named: "first")
    let prefetch = request(named: "prefetch")
    let visible = request(named: "visible")

    let firstTask = Task { await cache.image(for: first) }
    let firstDidStart = await waitUntil { await decoder.startedCount == 1 }
    XCTAssertTrue(firstDidStart)
    let prefetchTask = Task {
      await cache.image(for: prefetch, priority: .prefetch)
    }
    let visibleTask = Task {
      await cache.image(for: visible, priority: .visible)
    }

    let queuedRequestsArrived = await waitUntil { await cache.queuedDecodeCount == 2 }
    let maximumActiveCount = await decoder.maximumActiveCount
    let currentDecodeCount = await cache.currentDecodeCount
    XCTAssertTrue(queuedRequestsArrived)
    XCTAssertEqual(maximumActiveCount, 1)
    XCTAssertEqual(currentDecodeCount, 1)

    await decoder.release(first, with: image)
    let visibleDidStart = await waitUntil { await decoder.startedCount == 2 }
    let startedRequests = await decoder.startedRequests
    let finalMaximumActiveCount = await decoder.maximumActiveCount
    XCTAssertTrue(visibleDidStart)
    XCTAssertEqual(startedRequests.dropFirst().first?.fileURL, visible.fileURL)
    XCTAssertEqual(finalMaximumActiveCount, 1)

    await decoder.release(visible, with: image)
    let prefetchDidStart = await waitUntil { await decoder.startedCount == 3 }
    XCTAssertTrue(prefetchDidStart)
    await decoder.release(prefetch, with: image)

    let firstResult = await firstTask.value
    let visibleResult = await visibleTask.value
    let prefetchResult = await prefetchTask.value
    XCTAssertNotNil(firstResult)
    XCTAssertNotNil(visibleResult)
    XCTAssertNotNil(prefetchResult)
  }

  func testCacheCoalescesSameKeyAndCancellingOneSubscriberKeepsDecodeAlive() async throws {
    let image = try makeDecodedImage()
    let decoder = SuspendedThumbnailDecoder()
    let cache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: 1_024 * 1_024,
      maximumConcurrentDecodes: 2,
      decoder: { request in await decoder.decode(request) }
    )
    let request = request(named: "shared")

    let cancelledSubscriber = Task { await cache.image(for: request) }
    let didStart = await waitUntil { await decoder.startedCount == 1 }
    XCTAssertTrue(didStart)
    let survivingSubscriber = Task { await cache.image(for: request) }

    let bothSubscribed = await waitUntil { await cache.subscriberCount == 2 }
    XCTAssertTrue(bothSubscribed)
    cancelledSubscriber.cancel()
    let cancelledResult = await cancelledSubscriber.value
    let startedCountAfterCancellation = await decoder.startedCount
    XCTAssertNil(cancelledResult)
    XCTAssertEqual(startedCountAfterCancellation, 1)

    await decoder.release(request, with: image)
    let survivingResult = await survivingSubscriber.value
    let finalStartedCount = await decoder.startedCount
    XCTAssertNotNil(survivingResult)
    XCTAssertEqual(finalStartedCount, 1)
  }

  func testCacheCancelsQueuedAndUnsubscribedDecode() async throws {
    let image = try makeDecodedImage()
    let decoder = SuspendedThumbnailDecoder()
    let cache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: 1_024 * 1_024,
      maximumConcurrentDecodes: 1,
      decoder: { request in await decoder.decode(request) }
    )
    let active = request(named: "active")
    let queued = request(named: "queued")

    let activeTask = Task { await cache.image(for: active) }
    let activeDidStart = await waitUntil { await decoder.startedCount == 1 }
    XCTAssertTrue(activeDidStart)
    let queuedTask = Task { await cache.image(for: queued) }
    let queuedDidArrive = await waitUntil { await cache.queuedDecodeCount == 1 }
    XCTAssertTrue(queuedDidArrive)

    queuedTask.cancel()
    let queuedResult = await queuedTask.value
    let queuedDecodeCount = await cache.queuedDecodeCount
    let startedCountAfterQueuedCancellation = await decoder.startedCount
    XCTAssertNil(queuedResult)
    XCTAssertEqual(queuedDecodeCount, 0)
    XCTAssertEqual(startedCountAfterQueuedCancellation, 1)

    await decoder.release(active, with: image)
    let activeResult = await activeTask.value
    let finalStartedCount = await decoder.startedCount
    XCTAssertNotNil(activeResult)
    XCTAssertEqual(finalStartedCount, 1)
  }

  func testCacheCancelsActiveDecodeWhenAllSubscribersLeaveAndCleansUpFailure() async throws {
    let image = try makeDecodedImage()
    let suspendedDecoder = SuspendedThumbnailDecoder()
    let cache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: 1_024 * 1_024,
      maximumConcurrentDecodes: 1,
      decoder: { request in await suspendedDecoder.decode(request) }
    )
    let cancelledRequest = request(named: "cancelled")

    let task = Task { await cache.image(for: cancelledRequest) }
    let didStart = await waitUntil { await suspendedDecoder.startedCount == 1 }
    XCTAssertTrue(didStart)
    task.cancel()
    let cancelledResult = await task.value
    let decoderDidCancel = await waitUntil { await suspendedDecoder.cancellationCount == 1 }
    let cacheDidFinish = await waitUntil { await cache.currentDecodeCount == 0 }
    let cachedEntryCount = await cache.cachedEntryCount
    XCTAssertNil(cancelledResult)
    XCTAssertTrue(decoderDidCancel)
    XCTAssertTrue(cacheDidFinish)
    XCTAssertEqual(cachedEntryCount, 0)

    let sequence = ThumbnailResultSequence(results: [.failure, .image(image)])
    let failureCache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: 1_024 * 1_024,
      maximumConcurrentDecodes: 1,
      decoder: { _ in await sequence.nextResult() }
    )
    let failedRequest = request(named: "failure")

    let failureResult = await failureCache.image(for: failedRequest)
    let retryResult = await failureCache.image(for: failedRequest)
    let sequenceCallCount = await sequence.callCount
    XCTAssertNil(failureResult)
    XCTAssertNotNil(retryResult)
    XCTAssertEqual(sequenceCallCount, 2)
  }

  func testNewSubscriberRetriesWhileCancelledDecodeIsStillFinishing() async throws {
    let image = try makeDecodedImage()
    let decoder = SuspendedThumbnailDecoder(ignoresCancellation: true)
    let cache = WorkbenchThumbnailCache(
      maximumConcurrentDecodes: 1,
      decoder: { request in await decoder.decode(request) }
    )
    let request = request(named: "reappeared")
    let oldTask = Task { await cache.image(for: request) }
    let started = await waitUntil { await decoder.startedCount == 1 }
    XCTAssertTrue(started)
    oldTask.cancel()
    let oldResult = await oldTask.value
    XCTAssertNil(oldResult)
    let newTask = Task { await cache.image(for: request) }
    let subscribed = await waitUntil { await cache.subscriberCount == 1 }
    XCTAssertTrue(subscribed)
    await decoder.release(request, with: image)
    let restarted = await waitUntil { await decoder.startedCount == 2 }
    XCTAssertTrue(restarted)
    await decoder.release(request, with: image)
    let newResult = await newTask.value
    XCTAssertNotNil(newResult)
    let maximumActive = await decoder.maximumActiveCount
    XCTAssertEqual(maximumActive, 1)
  }

  func testCacheEvictsLeastRecentlyUsedEntriesByDecodedByteCost() async throws {
    let image = try makeDecodedImage(width: 8, height: 4, bytesPerRow: 64)
    let byteCost = image.value.bytesPerRow * image.value.height
    let decoder = CountingThumbnailDecoder(image: image)
    let cache = WorkbenchThumbnailCache(
      maximumCachedEntries: 10,
      maximumCachedBytes: byteCost * 2 + byteCost / 2,
      maximumConcurrentDecodes: 2,
      decoder: { request in await decoder.decode(request) }
    )
    let first = request(named: "lru-first")
    let second = request(named: "lru-second")
    let third = request(named: "lru-third")

    let firstResult = await cache.image(for: first)
    let secondResult = await cache.image(for: second)
    let refreshedFirstResult = await cache.image(for: first)  // Refresh first's LRU position.
    let thirdResult = await cache.image(for: third)
    let cachedEntryCount = await cache.cachedEntryCount
    let cachedByteCount = await cache.cachedByteCount
    let firstCallCount = await decoder.callCount(for: first)
    let secondCallCount = await decoder.callCount(for: second)
    let thirdCallCount = await decoder.callCount(for: third)
    XCTAssertNotNil(firstResult)
    XCTAssertNotNil(secondResult)
    XCTAssertNotNil(refreshedFirstResult)
    XCTAssertNotNil(thirdResult)
    XCTAssertEqual(cachedEntryCount, 2)
    XCTAssertLessThanOrEqual(cachedByteCount, byteCost * 2 + byteCost / 2)
    XCTAssertEqual(firstCallCount, 1)
    XCTAssertEqual(secondCallCount, 1)
    XCTAssertEqual(thirdCallCount, 1)

    let reloadedSecondResult = await cache.image(for: second)
    let reloadedSecondCallCount = await decoder.callCount(for: second)
    XCTAssertNotNil(reloadedSecondResult)
    XCTAssertEqual(reloadedSecondCallCount, 2)
  }

  private func request(named name: String) -> WorkbenchThumbnailRequest {
    WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/workbench-thumbnail-cache-\(name).png"),
      maxPixelSize: 128,
      displayScale: 1
    )
  }

  private func makeDecodedImage(
    width: Int = 8,
    height: Int = 8,
    bytesPerRow: Int = 0
  ) throws -> WorkbenchDecodedImage {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    return WorkbenchDecodedImage(value: try XCTUnwrap(context.makeImage()))
  }

  private func waitUntil(
    iterations: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<iterations {
      if await condition() { return true }
      await Task.yield()
    }
    return false
  }
}

private actor SuspendedThumbnailDecoder {
  private let ignoresCancellation: Bool

  init(ignoresCancellation: Bool = false) {
    self.ignoresCancellation = ignoresCancellation
  }

  private var continuations: [String: CheckedContinuation<WorkbenchDecodedImage?, Never>] = [:]
  private(set) var startedRequests: [WorkbenchThumbnailRequest] = []
  private(set) var activeCount = 0
  private(set) var maximumActiveCount = 0
  private(set) var cancellationCount = 0

  var startedCount: Int { startedRequests.count }

  func decode(_ request: WorkbenchThumbnailRequest) async -> WorkbenchDecodedImage? {
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    let key = request.fileURL.path
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        startedRequests.append(request)
        continuations[key] = continuation
      }
    } onCancel: {
      Task { await self.cancel(key) }
    }
    activeCount = max(activeCount - 1, 0)
    return result
  }

  func release(_ request: WorkbenchThumbnailRequest, with image: WorkbenchDecodedImage) {
    continuations.removeValue(forKey: request.fileURL.path)?.resume(returning: image)
  }

  private func cancel(_ key: String) {
    cancellationCount += 1
    guard !ignoresCancellation else { return }
    continuations.removeValue(forKey: key)?.resume(returning: nil)
  }
}

private actor ThumbnailResultSequence {
  enum Result: Sendable {
    case failure
    case image(WorkbenchDecodedImage)
  }

  private var results: [Result]
  private(set) var callCount = 0

  init(results: [Result]) {
    self.results = results
  }

  func nextResult() -> WorkbenchDecodedImage? {
    callCount += 1
    guard !results.isEmpty else { return nil }
    switch results.removeFirst() {
    case .failure:
      return nil
    case .image(let image):
      return image
    }
  }
}

private actor CountingThumbnailDecoder {
  private let image: WorkbenchDecodedImage
  private var calls: [String: Int] = [:]

  init(image: WorkbenchDecodedImage) {
    self.image = image
  }

  func decode(_ request: WorkbenchThumbnailRequest) -> WorkbenchDecodedImage? {
    calls[request.fileURL.path, default: 0] += 1
    return image
  }

  func callCount(for request: WorkbenchThumbnailRequest) -> Int {
    calls[request.fileURL.path, default: 0]
  }
}
