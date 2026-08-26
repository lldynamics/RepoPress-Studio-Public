import AppKit
import QuickLookThumbnailing
import SwiftUI

private final class WorkbenchQuickLookRequest: @unchecked Sendable {
  let value: QLThumbnailGenerator.Request

  init(_ value: QLThumbnailGenerator.Request) {
    self.value = value
  }
}

struct WorkbenchThumbnailRequest: Hashable {
  private static let maximumPixelSize = 4_096

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

  private func loadThumbnail(for request: WorkbenchThumbnailRequest) async {
    thumbnailImage = nil
    isLoading = true

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
}
