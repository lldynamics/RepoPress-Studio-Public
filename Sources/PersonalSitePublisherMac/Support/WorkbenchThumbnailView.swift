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

private struct WorkbenchDecodedImage: @unchecked Sendable {
  let value: CGImage
}

/// Shared, bounded ImageIO cache.  The actor also coalesces concurrent loads,
/// which is important when a grid and inspector request the same asset.
private actor WorkbenchThumbnailCache {
  static let shared = WorkbenchThumbnailCache()
  private var values: [Key: WorkbenchDecodedImage] = [:]
  private var inFlight: [Key: Task<WorkbenchDecodedImage?, Never>] = [:]
  private let capacity = 180

  func image(for request: WorkbenchThumbnailRequest) async -> WorkbenchDecodedImage? {
    let key = Key(request: request, version: fileVersion(for: request.fileURL))
    if let value = values[key] { return value }
    if let task = inFlight[key] { return await task.value }
    let task: Task<WorkbenchDecodedImage?, Never> = Task.detached(priority: .utility) {
      guard
        !Task.isCancelled,
        let image = WorkbenchImageIOThumbnailDecoder.downsampledImage(
          at: request.fileURL,
          maxPixelSize: request.maxPixelSize
        ),
        !Task.isCancelled
      else {
        return nil
      }
      return WorkbenchDecodedImage(value: image)
    }
    inFlight[key] = task
    let result = await task.value
    inFlight[key] = nil
    if let result {
      if values.count >= capacity { values.removeValue(forKey: values.keys.first!) }
      values[key] = result
    }
    return result
  }

  private struct Key: Hashable {
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

  private func fileVersion(for url: URL) -> String {
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
