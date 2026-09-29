import AppKit
import Foundation
import ImageIO
import PublishingKnowledgeCore
import SwiftUI

enum RSSArticleCoverThumbnailPresentation {
  static let dimension: CGFloat = 64
  static let cornerRadius: CGFloat = 10
  static let maximumPixelSize = 192
  static let accessibilityIdentifierPrefix = "rss-article-cover-thumbnail"
}

/// Shares bounded, downsampled cover data between rows so scrolling the RSS
/// list does not repeatedly decode the same remote image at full resolution.
actor RSSArticleCoverThumbnailCache {
  static let shared = RSSArticleCoverThumbnailCache()

  private struct Request {
    let id: UUID
    var consumers: [UUID: CheckedContinuation<Data?, Never>]
    var task: Task<Void, Never>?
  }

  private let loader: RSSArticleCoverImageLoader
  private let maximumConcurrentRequests: Int
  private let maximumQueuedRequests: Int
  private let maximumCacheEntryCount = 96
  private var cachedData: [URL: Data] = [:]
  private var cacheOrder: [URL] = []
  private var requests: [URL: Request] = [:]
  private var queue: [(url: URL, requestID: UUID)] = []
  private var activeRequestCount = 0

  init(
    loader: RSSArticleCoverImageLoader = RSSArticleCoverImageLoader(
      maximumByteCount: RSSArticleCoverImageLoader.defaultMaximumByteCount
    ),
    maximumConcurrentRequests: Int = 4,
    maximumQueuedRequests: Int = 128
  ) {
    self.loader = loader
    self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    self.maximumQueuedRequests = max(1, maximumQueuedRequests)
  }

  func data(for imageURL: URL) async -> Data? {
    let key = imageURL.absoluteURL
    if let cached = cachedData[key] {
      return cached
    }
    let consumerID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: nil)
        } else {
          addConsumer(consumerID, for: key, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.removeConsumer(consumerID, for: key) }
    }
  }

  private func addConsumer(
    _ consumerID: UUID,
    for key: URL,
    continuation: CheckedContinuation<Data?, Never>
  ) {
    if var request = requests[key] {
      request.consumers[consumerID] = continuation
      requests[key] = request
      return
    }
    let requestID = UUID()
    requests[key] = Request(
      id: requestID,
      consumers: [consumerID: continuation],
      task: nil
    )
    if queue.count >= maximumQueuedRequests {
      let oldest = queue.removeFirst()
      if let evicted = requests[oldest.url], evicted.id == oldest.requestID {
        requests[oldest.url] = nil
        for consumer in evicted.consumers.values {
          consumer.resume(returning: nil)
        }
      }
    }
    queue.append((key, requestID))
    startQueuedRequests()
  }

  private func removeConsumer(_ consumerID: UUID, for key: URL) {
    guard var request = requests[key],
      let continuation = request.consumers.removeValue(forKey: consumerID)
    else { return }
    continuation.resume(returning: nil)
    if request.consumers.isEmpty {
      // Remove immediately so a new subscriber gets a fresh request. The old
      // task still occupies its concurrency slot until cancellation finishes.
      requests[key] = nil
      request.task?.cancel()
      if request.task == nil {
        queue.removeAll { $0.url == key && $0.requestID == request.id }
      }
    } else {
      requests[key] = request
    }
    startQueuedRequests()
  }

  private func startQueuedRequests() {
    while activeRequestCount < maximumConcurrentRequests, !queue.isEmpty {
      let next = queue.removeFirst()
      guard var request = requests[next.url], request.id == next.requestID else { continue }
      let loader = loader
      activeRequestCount += 1
      request.task = Task {
        let result: Data?
        do {
          let sourceData = try await loader.load(from: next.url)
          try Task.checkCancellation()
          result = Self.downsampledPNGData(
            from: sourceData,
            maximumPixelSize: RSSArticleCoverThumbnailPresentation.maximumPixelSize
          )
        } catch {
          result = nil
        }
        finishRequest(for: next.url, requestID: next.requestID, result: result)
      }
      requests[next.url] = request
    }
  }

  private func finishRequest(for key: URL, requestID: UUID, result: Data?) {
    activeRequestCount -= 1
    if let request = requests[key], request.id == requestID {
      requests[key] = nil
      if let result {
        cachedData[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        trimCacheIfNeeded()
      }
      for continuation in request.consumers.values {
        continuation.resume(returning: result)
      }
    }
    startQueuedRequests()
  }

  func pendingConsumerCount(for imageURL: URL) -> Int {
    requests[imageURL.absoluteURL]?.consumers.count ?? 0
  }

  private func trimCacheIfNeeded() {
    while cacheOrder.count > maximumCacheEntryCount {
      let evictedURL = cacheOrder.removeFirst()
      cachedData[evictedURL] = nil
    }
  }

  private nonisolated static func downsampledPNGData(
    from sourceData: Data,
    maximumPixelSize: Int
  ) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions),
          let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ] as CFDictionary
          ) else {
      return sourceData
    }

    let outputData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      outputData as CFMutableData,
      "public.png" as CFString,
      1,
      nil
    ) else {
      return sourceData
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return sourceData
    }
    return outputData as Data
  }
}

struct RSSArticleCoverThumbnail: View {
  let articleID: String
  let url: URL

  @State private var image: NSImage?
  @State private var didFail = false

  var body: some View {
    ZStack {
      Color.secondary.opacity(0.10)

      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else if didFail {
        Image(systemName: "photo")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.tertiary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(
      width: RSSArticleCoverThumbnailPresentation.dimension,
      height: RSSArticleCoverThumbnailPresentation.dimension
    )
    .clipShape(
      RoundedRectangle(
        cornerRadius: RSSArticleCoverThumbnailPresentation.cornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: RSSArticleCoverThumbnailPresentation.cornerRadius,
        style: .continuous
      )
      .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("文章封面缩略图")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier(
      "\(RSSArticleCoverThumbnailPresentation.accessibilityIdentifierPrefix)-\(articleID)"
    )
    .help("文章封面")
    .task(id: url) {
      await loadImage()
    }
  }

  private var accessibilityValue: String {
    if image != nil { return "已加载" }
    if didFail { return "加载失败" }
    return "正在加载"
  }

  @MainActor
  private func loadImage() async {
    image = nil
    didFail = false

    guard let data = await RSSArticleCoverThumbnailCache.shared.data(for: url),
          !Task.isCancelled else {
      if !Task.isCancelled { didFail = true }
      return
    }

    image = NSImage(data: data)
    didFail = image == nil
  }
}
