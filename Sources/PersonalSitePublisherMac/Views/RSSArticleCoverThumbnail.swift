import AppKit
import Foundation
import ImageIO
import PublishingWorkbenchCore
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

  private let loader = RSSArticleCoverImageLoader(
    maximumByteCount: RSSArticleCoverImageLoader.defaultMaximumByteCount
  )
  private let maximumCacheEntryCount = 96
  private var cachedData: [URL: Data] = [:]
  private var cacheOrder: [URL] = []
  private var inFlight: [URL: Task<Data?, Never>] = [:]

  func data(for imageURL: URL) async -> Data? {
    let key = imageURL.absoluteURL
    if let cached = cachedData[key] {
      return cached
    }
    if let task = inFlight[key] {
      return await task.value
    }

    let loader = loader
    let task = Task<Data?, Never> {
      do {
        let sourceData = try await loader.load(from: key)
        return Self.downsampledPNGData(
          from: sourceData,
          maximumPixelSize: RSSArticleCoverThumbnailPresentation.maximumPixelSize
        )
      } catch {
        return nil
      }
    }
    inFlight[key] = task

    let result = await task.value
    inFlight[key] = nil
    if let result {
      cachedData[key] = result
      cacheOrder.removeAll { $0 == key }
      cacheOrder.append(key)
      trimCacheIfNeeded()
    }
    return result
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
