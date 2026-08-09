import AppKit
import CryptoKit
import ImageIO
import os
import PublishingWorkbenchCore
import SwiftUI

private let imageCacheLogger = Logger(
  subsystem: "com.jinfang.PersonalSitePublisherMac",
  category: "WorkbenchImageTwoTierCache"
)

struct WorkbenchThumbnailCachePolicy: Sendable {
  let formatVersion: Int
  let maximumPixelSize: Int
  let maximumDiskEntryByteCount: Int
  let maximumDiskCacheByteCount: Int
  let maximumDiskEntryCount: Int
  let maximumDiskEntryAge: TimeInterval
  let maintenanceInterval: TimeInterval
  let maintenanceMarkerName: String

  static let production = WorkbenchThumbnailCachePolicy(
    formatVersion: 2,
    maximumPixelSize: 4_096,
    maximumDiskEntryByteCount: 16 * 1_024 * 1_024,
    maximumDiskCacheByteCount: 256 * 1_024 * 1_024,
    maximumDiskEntryCount: 2_000,
    maximumDiskEntryAge: 30 * 24 * 60 * 60,
    maintenanceInterval: 10 * 60,
    maintenanceMarkerName: ".maintenance-v2"
  )
}

@MainActor
final class WorkbenchImageTwoTierCache {
  private struct ThumbnailData: Sendable {
    let imageData: Data
    let diskData: Data?
  }

  static let shared = WorkbenchImageTwoTierCache()

  private let memoryCache = NSCache<NSString, NSImage>()
  private let fileManager = FileManager.default
  private let diskCacheDirectory: URL
  private let policy: WorkbenchThumbnailCachePolicy
  private let cacheQueue = DispatchQueue(label: "com.jinfang.workbench.imagecache", qos: .userInitiated)
  private var memoryCacheGeneration = 0

  init(
    diskCacheDirectory: URL? = nil,
    policy: WorkbenchThumbnailCachePolicy = .production
  ) {
    self.policy = policy
    memoryCache.countLimit = 300
    memoryCache.totalCostLimit = 64 * 1024 * 1024 // 64 MB 内存缓存上限

    if let diskCacheDirectory {
      self.diskCacheDirectory = diskCacheDirectory
    } else {
      let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      self.diskCacheDirectory = cachesURL.appendingPathComponent(
        "WorkbenchImageThumbnails",
        isDirectory: true
      )
    }

    if !fileManager.fileExists(atPath: self.diskCacheDirectory.path) {
      do {
        try fileManager.createDirectory(
          at: self.diskCacheDirectory,
          withIntermediateDirectories: true
        )
      } catch {
        imageCacheLogger.error(
          "Thumbnail cache directory creation failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    let directoryURL = self.diskCacheDirectory
    cacheQueue.async {
      Self.performDiskMaintenance(at: directoryURL, policy: policy, force: true)
    }
  }

  func thumbnail(
    for fileURL: URL,
    maxPixelSize: Int = 256
  ) async -> NSImage? {
    let policy = self.policy
    let normalizedMaxPixelSize = min(
      max(maxPixelSize, 1),
      policy.maximumPixelSize
    )
    let cacheKey = Self.cacheKey(
      for: fileURL,
      maxPixelSize: normalizedMaxPixelSize,
      formatVersion: policy.formatVersion
    )
    let memoryCacheGeneration = self.memoryCacheGeneration

    // 1. 第一级：查 L1 内存缓存
    if let cachedImage = memoryCache.object(forKey: cacheKey as NSString) {
      return cachedImage
    }

    // 2. 第二级：查 L2 磁盘缓存与 CGImageSource 异步下采样
    let diskFileURL = diskCacheDirectory.appendingPathComponent("\(cacheKey).png")
    let diskCacheDirectory = self.diskCacheDirectory

    return await withCheckedContinuation { continuation in
      cacheQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        // 尝试从磁盘 Cache 目录读取已下采样的图像
        if let diskImageData = Self.loadDiskThumbnailData(
          at: diskFileURL,
          maximumByteCount: policy.maximumDiskEntryByteCount
        ) {
          Task { @MainActor in
            guard let diskImage = NSImage(data: diskImageData) else {
              continuation.resume(returning: nil)
              return
            }
            if self.memoryCacheGeneration == memoryCacheGeneration {
              let cost = Self.memoryCost(of: diskImage)
              self.memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: cost)
            }
            continuation.resume(returning: diskImage)
          }
          return
        }

        // 磁盘未命中，使用 CGImageSource 进行硬解码下采样生成轻量缩略图
        guard let generatedThumbnail = Self.generateDownsampledThumbnailData(
          from: fileURL,
          maxPixelSize: normalizedMaxPixelSize
        ) else {
          continuation.resume(returning: nil)
          return
        }

        // 保存到磁盘缓存
        if let pngData = generatedThumbnail.diskData,
           pngData.count <= policy.maximumDiskEntryByteCount {
          do {
            try pngData.write(to: diskFileURL, options: .atomic)
          } catch {
            imageCacheLogger.error(
              "Thumbnail cache write failed for \(diskFileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
          Self.performDiskMaintenance(
            at: diskCacheDirectory,
            policy: policy,
            force: false
          )
        }

        Task { @MainActor in
          guard let downsampledImage = NSImage(data: generatedThumbnail.imageData) else {
            continuation.resume(returning: nil)
            return
          }
          if self.memoryCacheGeneration == memoryCacheGeneration {
            let cost = Self.memoryCost(of: downsampledImage)
            self.memoryCache.setObject(downsampledImage, forKey: cacheKey as NSString, cost: cost)
          }
          continuation.resume(returning: downsampledImage)
        }
      }
    }
  }

  private nonisolated static func generateDownsampledThumbnailData(
    from fileURL: URL,
    maxPixelSize: Int
  ) -> ThumbnailData? {
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

    let image = NSImage(
      cgImage: downsampledCGImage,
      size: NSSize(width: downsampledCGImage.width, height: downsampledCGImage.height)
    )
    guard let imageData = image.tiffRepresentation else {
      return nil
    }
    let diskData = NSBitmapImageRep(data: imageData)?.representation(
      using: .png,
      properties: [:]
    )
    return ThumbnailData(imageData: imageData, diskData: diskData)
  }

  private nonisolated static func cacheKey(
    for fileURL: URL,
    maxPixelSize: Int,
    formatVersion: Int
  ) -> String {
    let normalizedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
    let resourceValues = try? normalizedURL.resourceValues(
      forKeys: [.contentModificationDateKey, .fileSizeKey]
    )
    let modificationDateBits = resourceValues?
      .contentModificationDate?
      .timeIntervalSince1970
      .bitPattern ?? 0
    let fileSize = resourceValues?.fileSize ?? -1
    let rawKey = [
      "v\(formatVersion)",
      normalizedURL.path,
      String(modificationDateBits),
      String(fileSize),
      String(maxPixelSize)
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(rawKey.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func clearCache() async {
    memoryCache.removeAllObjects()
    memoryCacheGeneration &+= 1
    let directoryURL = diskCacheDirectory
    await withCheckedContinuation { continuation in
      cacheQueue.async {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directoryURL)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        continuation.resume()
      }
    }
  }

  func waitForPendingDiskOperations() async {
    await withCheckedContinuation { continuation in
      cacheQueue.async {
        continuation.resume()
      }
    }
  }

  private nonisolated static func loadDiskThumbnailData(
    at fileURL: URL,
    maximumByteCount: Int
  ) -> Data? {
    let fileManager = FileManager.default
    let resourceValues = try? fileURL.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard resourceValues?.isRegularFile == true,
          resourceValues?.isSymbolicLink != true,
          let fileSize = resourceValues?.fileSize,
          fileSize > 0,
          fileSize <= maximumByteCount,
          let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
          NSImage(data: data) != nil else {
      try? fileManager.removeItem(at: fileURL)
      return nil
    }

    try? fileManager.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: fileURL.path
    )
    return data
  }

  private nonisolated static func memoryCost(of image: NSImage) -> Int {
    let pixelWidth = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
    let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
    return max(pixelWidth, 1) * max(pixelHeight, 1) * 4
  }

  private nonisolated static func performDiskMaintenance(
    at directoryURL: URL,
    policy: WorkbenchThumbnailCachePolicy,
    force: Bool
  ) {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let now = Date()
    let markerURL = directoryURL.appendingPathComponent(
      policy.maintenanceMarkerName
    )
    if !force,
       let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
       let lastMaintenanceDate = attributes[.modificationDate] as? Date,
       now.timeIntervalSince(lastMaintenanceDate)
         < policy.maintenanceInterval {
      return
    }

    let resourceKeys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey
    ]
    guard let fileURLs = try? fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    var validEntries: [(url: URL, byteCount: Int, lastAccessedAt: Date)] = []
    for fileURL in fileURLs {
      let values = try? fileURL.resourceValues(forKeys: resourceKeys)
      let isValidCacheFile = isCurrentCacheFile(fileURL)
        && values?.isRegularFile == true
        && values?.isSymbolicLink != true
      guard isValidCacheFile,
            let byteCount = values?.fileSize,
            byteCount > 0,
            byteCount <= policy.maximumDiskEntryByteCount,
            let lastAccessedAt = values?.contentModificationDate,
            now.timeIntervalSince(lastAccessedAt)
              <= policy.maximumDiskEntryAge else {
        try? fileManager.removeItem(at: fileURL)
        continue
      }
      validEntries.append((fileURL, byteCount, lastAccessedAt))
    }

    var totalByteCount = validEntries.reduce(0) { $0 + $1.byteCount }
    var entryCount = validEntries.count
    if totalByteCount > policy.maximumDiskCacheByteCount
      || entryCount > policy.maximumDiskEntryCount {
      for entry in validEntries.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
        guard totalByteCount > policy.maximumDiskCacheByteCount
          || entryCount > policy.maximumDiskEntryCount else {
          break
        }
        do {
          try fileManager.removeItem(at: entry.url)
          totalByteCount -= entry.byteCount
          entryCount -= 1
        } catch {
          continue
        }
      }
    }

    if !fileManager.fileExists(atPath: markerURL.path) {
      _ = fileManager.createFile(atPath: markerURL.path, contents: Data())
    }
    try? fileManager.setAttributes(
      [.modificationDate: now],
      ofItemAtPath: markerURL.path
    )
  }

  private nonisolated static func isCurrentCacheFile(_ fileURL: URL) -> Bool {
    guard fileURL.pathExtension.lowercased() == "png" else {
      return false
    }
    let key = fileURL.deletingPathExtension().lastPathComponent
    return key.count == 64 && key.allSatisfy(\.isHexDigit)
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
