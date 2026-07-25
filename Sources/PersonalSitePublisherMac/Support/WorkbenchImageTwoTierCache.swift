import AppKit
import ImageIO
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class WorkbenchImageTwoTierCache {
  static let shared = WorkbenchImageTwoTierCache()

  private let memoryCache = NSCache<NSString, NSImage>()
  private let fileManager = FileManager.default
  private let diskCacheDirectory: URL
  private let cacheQueue = DispatchQueue(label: "com.jinfang.workbench.imagecache", qos: .userInitiated)

  private init() {
    memoryCache.countLimit = 300
    memoryCache.totalCostLimit = 64 * 1024 * 1024 // 64 MB 内存缓存上限

    let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    diskCacheDirectory = cachesURL.appendingPathComponent("WorkbenchImageThumbnails", isDirectory: true)

    if !fileManager.fileExists(atPath: diskCacheDirectory.path) {
      try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }
  }

  func thumbnail(
    for fileURL: URL,
    maxPixelSize: Int = 256
  ) async -> NSImage? {
    let cacheKey = cacheKey(for: fileURL, maxPixelSize: maxPixelSize)

    // 1. 第一级：查 L1 内存缓存
    if let cachedImage = memoryCache.object(forKey: cacheKey as NSString) {
      return cachedImage
    }

    // 2. 第二级：查 L2 磁盘缓存与 CGImageSource 异步下采样
    let diskFileURL = diskCacheDirectory.appendingPathComponent("\(cacheKey).png")

    return await withCheckedContinuation { continuation in
      cacheQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        // 尝试从磁盘 Cache 目录读取已下采样的图像
        if let diskData = try? Data(contentsOf: diskFileURL),
           let diskImage = NSImage(data: diskData) {
          let cost = Int(diskImage.size.width * diskImage.size.height * 4)
          Task { @MainActor in
            self.memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: cost)
          }
          continuation.resume(returning: diskImage)
          return
        }

        // 磁盘未命中，使用 CGImageSource 进行硬解码下采样生成轻量缩略图
        guard let downsampledImage = self.generateDownsampledThumbnail(
          from: fileURL,
          maxPixelSize: maxPixelSize
        ) else {
          continuation.resume(returning: nil)
          return
        }

        // 保存到磁盘缓存
        if let tiffData = downsampledImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
          try? pngData.write(to: diskFileURL, options: .atomic)
        }

        let cost = Int(downsampledImage.size.width * downsampledImage.size.height * 4)
        Task { @MainActor in
          self.memoryCache.setObject(downsampledImage, forKey: cacheKey as NSString, cost: cost)
        }

        continuation.resume(returning: downsampledImage)
      }
    }
  }

  private nonisolated func generateDownsampledThumbnail(
    from fileURL: URL,
    maxPixelSize: Int
  ) -> NSImage? {
    let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, imageSourceOptions) else {
      return nil
    }

    let downsampleOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    guard let downsampledCGImage = CGImageSourceCreateThumbnailAtIndex(
      imageSource,
      0,
      downsampleOptions as CFDictionary
    ) else {
      return nil
    }

    return NSImage(
      cgImage: downsampledCGImage,
      size: NSSize(width: downsampledCGImage.width, height: downsampledCGImage.height)
    )
  }

  private nonisolated func cacheKey(for fileURL: URL, maxPixelSize: Int) -> String {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
    let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let rawString = "\(fileURL.path)_\(modificationDate)_\(maxPixelSize)"
    return String(rawString.hashValue)
  }

  func clearCache() {
    memoryCache.removeAllObjects()
    try? fileManager.removeItem(at: diskCacheDirectory)
    try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
  }
}

struct WorkbenchThumbnailView: View {
  let fileURL: URL
  var maxPixelSize: Int = 256
  var cornerRadius: CGFloat = 8

  @State private var thumbnailImage: NSImage?
  @State private var isLoading = true

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
    .task(id: fileURL) {
      isLoading = true
      thumbnailImage = await WorkbenchImageTwoTierCache.shared.thumbnail(
        for: fileURL,
        maxPixelSize: maxPixelSize
      )
      isLoading = false
    }
  }
}
