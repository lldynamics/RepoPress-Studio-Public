import AppKit
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import SwiftUI

private final class WorkbenchQuickLookRequest: @unchecked Sendable {
  let value: QLThumbnailGenerator.Request

  init(_ value: QLThumbnailGenerator.Request) {
    self.value = value
  }
}

struct WorkbenchThumbnailRequest: Hashable, Sendable {
  static let maximumPixelSize = 4_096

  let fileURL: URL
  let maxPixelSize: Int
  let displayScale: CGFloat

  init(fileURL: URL, maxPixelSize: Int, displayScale: CGFloat) {
    self.fileURL = fileURL
    self.maxPixelSize = min(max(maxPixelSize, 1), Self.maximumPixelSize)
    self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
  }

  var quickLookRequest: QLThumbnailGenerator.Request {
    let pointSize = CGFloat(maxPixelSize) / displayScale
    return QLThumbnailGenerator.Request(
      fileAt: fileURL,
      size: CGSize(width: pointSize, height: pointSize),
      scale: displayScale,
      representationTypes: .thumbnail
    )
  }
}

enum WorkbenchImageIOThumbnailDecoder {
  static func downsampledImage(
    at fileURL: URL,
    maxPixelSize: Int
  ) -> CGImage? {
    let boundedPixelSize = min(
      max(maxPixelSize, 1),
      WorkbenchThumbnailRequest.maximumPixelSize
    )
    let sourceOptions =
      [
        kCGImageSourceShouldCache: false
      ] as CFDictionary
    guard
      let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
      CGImageSourceGetCount(source) > 0
    else {
      return nil
    }

    let thumbnailOptions =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
      ] as CFDictionary
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        thumbnailOptions
      ),
      image.width <= boundedPixelSize,
      image.height <= boundedPixelSize
    else {
      return nil
    }
    return image
  }
}

struct WorkbenchDecodedImage: @unchecked Sendable {
  let value: CGImage
}

/// Shared, bounded ImageIO cache. The actor coalesces concurrent loads, which
/// is important when a grid and inspector request the same asset.
///
/// ImageIO decoding is deliberately scheduled outside the actor at utility
/// priority. That keeps its disk and pixel work off the view task while the
/// actor limits the amount of that work that may be active at once.
actor WorkbenchThumbnailCache {
  static let shared = WorkbenchThumbnailCache()
  static let defaultMaximumCachedEntries = 180
  static let defaultMaximumCachedBytes = 64 * 1_024 * 1_024
  static let defaultMaximumConcurrentDecodes = 2

  enum LoadPriority: Sendable {
    case visible
    case prefetch
  }

  typealias Decoder = @Sendable (WorkbenchThumbnailRequest) async -> WorkbenchDecodedImage?

  private struct Key: Hashable, Sendable {
    let path: String
    let version: String
    let maxPixelSize: Int
    let displayScale: CGFloat

    init(request: WorkbenchThumbnailRequest, version: String) {
      path = request.fileURL.standardizedFileURL.path
      self.version = version
      maxPixelSize = request.maxPixelSize
      displayScale = request.displayScale
    }
  }

  private struct CacheEntry {
    let value: WorkbenchDecodedImage
    let byteCost: Int
    var lastAccess: UInt64
  }

  private enum FlightState {
    case queued(LoadPriority)
    case active(Task<Void, Never>)
  }

  private struct Flight {
    let request: WorkbenchThumbnailRequest
    var subscribers: [UUID: CheckedContinuation<WorkbenchDecodedImage?, Never>]
    var state: FlightState
  }

  private let maximumCachedEntries: Int
  private let maximumCachedBytes: Int
  private let maximumConcurrentDecodes: Int
  private let decoder: Decoder

  private var values: [Key: CacheEntry] = [:]
  private var cachedBytes = 0
  private var accessCounter: UInt64 = 0
  private var inFlight: [Key: Flight] = [:]
  private var visibleQueue: [Key] = []
  private var prefetchQueue: [Key] = []
  private var activeDecodeCount = 0

  init(
    maximumCachedEntries: Int = WorkbenchThumbnailCache.defaultMaximumCachedEntries,
    maximumCachedBytes: Int = WorkbenchThumbnailCache.defaultMaximumCachedBytes,
    maximumConcurrentDecodes: Int = WorkbenchThumbnailCache.defaultMaximumConcurrentDecodes,
    decoder: @escaping Decoder = { request in
      guard !Task.isCancelled,
        let image = WorkbenchImageIOThumbnailDecoder.downsampledImage(
          at: request.fileURL,
          maxPixelSize: request.maxPixelSize
        )
      else {
        return nil
      }
      return WorkbenchDecodedImage(value: image)
    }
  ) {
    self.maximumCachedEntries = max(maximumCachedEntries, 1)
    self.maximumCachedBytes = max(maximumCachedBytes, 0)
    self.maximumConcurrentDecodes = max(maximumConcurrentDecodes, 1)
    self.decoder = decoder
  }

  func image(
    for request: WorkbenchThumbnailRequest,
    priority: LoadPriority = .visible
  ) async -> WorkbenchDecodedImage? {
    let key = Key(request: request, version: Self.fileVersion(for: request.fileURL))
    let subscriber = UUID()

    return await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      let result = await subscribe(
        to: key,
        request: request,
        priority: priority,
        subscriber: subscriber
      )
      return Task.isCancelled ? nil : result
    } onCancel: {
      Task {
        await self.cancelSubscription(for: key, subscriber: subscriber)
      }
    }
  }

  var cachedByteCount: Int { cachedBytes }
  var cachedEntryCount: Int { values.count }
  var queuedDecodeCount: Int { visibleQueue.count + prefetchQueue.count }
  var currentDecodeCount: Int { activeDecodeCount }
  var subscriberCount: Int { inFlight.values.reduce(0) { $0 + $1.subscribers.count } }

  private func subscribe(
    to key: Key,
    request: WorkbenchThumbnailRequest,
    priority: LoadPriority,
    subscriber: UUID
  ) async -> WorkbenchDecodedImage? {
    guard !Task.isCancelled else { return nil }
    if let entry = values[key] {
      touch(key, entry: entry)
      return entry.value
    }

    return await withCheckedContinuation { continuation in
      if var flight = inFlight[key] {
        flight.subscribers[subscriber] = continuation
        if case .queued(.prefetch) = flight.state, case .visible = priority {
          // A cell that became visible upgrades an already queued prefetch
          // instead of leaving that shared request behind newer visible work.
          flight.state = .queued(.visible)
          prefetchQueue.removeAll { $0 == key }
          visibleQueue.append(key)
        }
        inFlight[key] = flight
        return
      }

      inFlight[key] = Flight(
        request: request,
        subscribers: [subscriber: continuation],
        state: .queued(priority)
      )
      enqueue(key, priority: priority)
      startQueuedDecodes()
    }
  }

  private func cancelSubscription(for key: Key, subscriber: UUID) {
    guard var flight = inFlight[key],
      let continuation = flight.subscribers.removeValue(forKey: subscriber)
    else {
      return
    }

    continuation.resume(returning: nil)
    guard flight.subscribers.isEmpty else {
      inFlight[key] = flight
      return
    }

    switch flight.state {
    case .queued:
      inFlight.removeValue(forKey: key)
      visibleQueue.removeAll { $0 == key }
      prefetchQueue.removeAll { $0 == key }
    case .active(let task):
      // Keep the flight until its detached task acknowledges cancellation, so
      // it continues to count toward the decode limit in the meantime.
      inFlight[key] = flight
      task.cancel()
    }
  }

  private func enqueue(_ key: Key, priority: LoadPriority) {
    switch priority {
    case .visible:
      visibleQueue.append(key)
    case .prefetch:
      prefetchQueue.append(key)
    }
  }

  private func dequeueNextKey() -> Key? {
    while !visibleQueue.isEmpty {
      let key = visibleQueue.removeFirst()
      if inFlight[key] != nil { return key }
    }
    while !prefetchQueue.isEmpty {
      let key = prefetchQueue.removeFirst()
      if inFlight[key] != nil { return key }
    }
    return nil
  }

  private func startQueuedDecodes() {
    while activeDecodeCount < maximumConcurrentDecodes,
      let key = dequeueNextKey(),
      var flight = inFlight[key]
    {
      guard case .queued = flight.state else { continue }
      activeDecodeCount += 1
      let request = flight.request
      let decoder = self.decoder
      let task = Task.detached(priority: .utility) { [cache = self] in
        guard !Task.isCancelled else {
          await cache.completeDecode(for: key, result: nil)
          return
        }
        let result = await decoder(request)
        await cache.completeDecode(
          for: key,
          result: Task.isCancelled ? nil : result
        )
      }
      flight.state = .active(task)
      inFlight[key] = flight
    }
  }

  private func completeDecode(for key: Key, result: WorkbenchDecodedImage?) {
    guard var flight = inFlight.removeValue(forKey: key) else { return }
    activeDecodeCount = max(activeDecodeCount - 1, 0)

    // A view can reappear before an unsubscribed decode acknowledges cancel.
    // New subscribers need a fresh decode, not that cancelled task's result.
    if case .active(let task) = flight.state, task.isCancelled,
      !flight.subscribers.isEmpty
    {
      flight.state = .queued(.visible)
      inFlight[key] = flight
      enqueue(key, priority: .visible)
      startQueuedDecodes()
      return
    }

    if let result, !flight.subscribers.isEmpty {
      insert(result, for: key)
    }
    for continuation in flight.subscribers.values {
      continuation.resume(returning: result)
    }
    startQueuedDecodes()
  }

  private func touch(_ key: Key, entry: CacheEntry) {
    accessCounter &+= 1
    var updatedEntry = entry
    updatedEntry.lastAccess = accessCounter
    values[key] = updatedEntry
  }

  private func insert(_ value: WorkbenchDecodedImage, for key: Key) {
    let byteCost = Self.byteCost(of: value)
    if let previous = values.removeValue(forKey: key) {
      cachedBytes = max(cachedBytes - previous.byteCost, 0)
    }
    accessCounter &+= 1
    values[key] = CacheEntry(value: value, byteCost: byteCost, lastAccess: accessCounter)
    let (newTotal, overflow) = cachedBytes.addingReportingOverflow(byteCost)
    cachedBytes = overflow ? Int.max : newTotal
    evictLeastRecentlyUsedEntriesIfNeeded()
  }

  private func evictLeastRecentlyUsedEntriesIfNeeded() {
    while values.count > maximumCachedEntries || cachedBytes > maximumCachedBytes {
      guard
        let leastRecentlyUsed = values.min(by: { lhs, rhs in
          lhs.value.lastAccess < rhs.value.lastAccess
        })
      else {
        return
      }
      let removed = values.removeValue(forKey: leastRecentlyUsed.key)
      cachedBytes = max(cachedBytes - (removed?.byteCost ?? 0), 0)
    }
  }

  private static func byteCost(of image: WorkbenchDecodedImage) -> Int {
    let (cost, overflow) = image.value.bytesPerRow.multipliedReportingOverflow(
      by: image.value.height)
    return overflow ? Int.max : cost
  }

  private static func fileVersion(for url: URL) -> String {
    let values = try? url.resourceValues(
      forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
    )
    let identifier = values?.fileResourceIdentifier.map(String.init(describing:)) ?? ""
    return
      "\(identifier):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
  }
}

enum WorkbenchThumbnailSizing {
  static let listMaxPixelSize = 120
}

struct WorkbenchThumbnailView: View {
  @Environment(\.displayScale) private var displayScale

  let fileURL: URL
  var maxPixelSize: Int = 256
  var cornerRadius: CGFloat = 8

  @State private var thumbnailImage: NSImage?
  @State private var isLoading = true

  private var thumbnailRequest: WorkbenchThumbnailRequest {
    WorkbenchThumbnailRequest(
      fileURL: fileURL,
      maxPixelSize: maxPixelSize,
      displayScale: displayScale
    )
  }

  var body: some View {
    ZStack {
      if let thumbnailImage {
        Image(nsImage: thumbnailImage)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Rectangle()
            .fill(.ultraThinMaterial)
          if isLoading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "photo")
              .font(.system(size: 24))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .task(id: thumbnailRequest) {
      await loadThumbnail(for: thumbnailRequest)
    }
  }

  @MainActor
  private func loadThumbnail(for request: WorkbenchThumbnailRequest) async {
    thumbnailImage = nil
    isLoading = true

    if let decodedImage = await imageIOThumbnail(for: request) {
      guard !Task.isCancelled else { return }
      thumbnailImage = NSImage(
        cgImage: decodedImage.value,
        size: NSSize(
          width: decodedImage.value.width,
          height: decodedImage.value.height
        )
      )
      isLoading = false
      return
    }

    guard !Task.isCancelled else { return }

    // QLThumbnailGenerator documents that cancellation uses the same request
    // instance, but the Objective-C request type has no Sendable annotation.
    let quickLookRequest = WorkbenchQuickLookRequest(request.quickLookRequest)
    let image: NSImage? = await withTaskCancellationHandler {
      do {
        let representation = try await QLThumbnailGenerator.shared
          .generateBestRepresentation(for: quickLookRequest.value)
        try Task.checkCancellation()
        return representation.nsImage
      } catch {
        return nil
      }
    } onCancel: {
      QLThumbnailGenerator.shared.cancel(quickLookRequest.value)
    }

    guard !Task.isCancelled else { return }
    thumbnailImage = image
    isLoading = false
  }

  private func imageIOThumbnail(
    for request: WorkbenchThumbnailRequest
  ) async -> WorkbenchDecodedImage? {
    return await withTaskCancellationHandler {
      await WorkbenchThumbnailCache.shared.image(for: request)
    } onCancel: {
      // Shared work is intentionally not cancelled by one cell; another
      // visible cell may be awaiting the same decode.
    }
  }
}
