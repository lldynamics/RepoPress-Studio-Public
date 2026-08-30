import AppKit
import CoreGraphics
import ImageIO
import PublishingWorkbenchCore
import SwiftUI

private struct KnowledgeDecodedImage: @unchecked Sendable {
  let value: CGImage
}

struct KnowledgeImageDataThumbnailView: View {
  let data: Data
  let requestID: UUID

  @State private var image: KnowledgeDecodedImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.quaternary)
      if let image {
        Image(decorative: image.value, scale: 1)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .task(id: requestID) {
      image = await Self.decodeThumbnail(data: data, maximumPixelSize: 160)
    }
  }

  private static func decodeThumbnail(
    data: Data,
    maximumPixelSize: Int
  ) async -> KnowledgeDecodedImage? {
    await Task.detached(priority: .utility) {
      guard !Task.isCancelled,
        let source = CGImageSourceCreateWithData(
          data as CFData,
          [kCGImageSourceShouldCache: false] as CFDictionary
        )
      else { return nil }
      let options =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
        !Task.isCancelled
      else { return nil }
      return KnowledgeDecodedImage(value: image)
    }.value
  }
}

struct KnowledgeDocumentThumbnailView: View {
  let knowledge: KnowledgeStore
  let document: KnowledgeDocument

  @State private var fileURL: URL?

  var body: some View {
    Group {
      if let fileURL {
        WorkbenchThumbnailView(
          fileURL: fileURL,
          maxPixelSize: WorkbenchThumbnailSizing.listMaxPixelSize,
          cornerRadius: 6
        )
      } else {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .frame(width: 38, height: 38)
    .accessibilityHidden(true)
    .task(id: document.currentRevisionID) {
      fileURL = knowledge.originalFileURL(documentID: document.id)
    }
  }
}

struct KnowledgeImageDocumentView: View {
  let imageURL: URL?
  let title: String
  let ocrText: String
  let highlightedAnchor: KnowledgeVisualAnchor?

  @State private var image: KnowledgeDecodedImage?
  @State private var isLoading = true
  @State private var zoom: CGFloat = 1
  @State private var gestureStartZoom: CGFloat = 1

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      imageToolbar

      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.quaternary.opacity(0.45))

        if isLoading {
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .loading(detail: String(localized: "正在载入图片…"))
            ),
            density: .compactPane
          )
        } else if let image {
          imageCanvas(image.value)
        } else {
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .failure(
                reason: String(localized: "托管副本不可读，可在资料库健康检查中重新验证。")
              )
            ),
            density: .compactPane
          )
        }
      }
      .frame(minHeight: 360, idealHeight: 520, maxHeight: 680)
      .clipped()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(imageAccessibilityLabel)
      .accessibilityValue(imageAccessibilityValue)
      .onDrag {
        guard let imageURL else { return NSItemProvider() }
        return NSItemProvider(contentsOf: imageURL)
          ?? NSItemProvider(object: imageURL as NSURL)
      }

      GroupBox(String(localized: "本机 OCR 文字")) {
        if ocrText.trimmedForPublishing.isEmpty {
          Text("这张图片没有识别到可检索文字；仍可使用标题、说明和标签管理。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text(ocrText)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("图片识别文字")
        }
      }
    }
    .task(id: imageURL) {
      await loadImage()
    }
    .onChange(of: highlightedAnchor) { _, _ in
      zoom = 1
      gestureStartZoom = 1
    }
  }

  private var imageAccessibilityLabel: String {
    if isLoading {
      return String(localized: "正在加载")
    }
    if image == nil {
      return String(localized: "失败")
    }
    return String(format: String(localized: "图片：%@"), title)
  }

  private var imageAccessibilityValue: String {
    if isLoading {
      return String(localized: "正在载入图片…")
    }
    if image == nil {
      return String(
        format: String(localized: "原因：%@"),
        String(localized: "托管副本不可读，可在资料库健康检查中重新验证。")
      )
    }
    return highlightedAnchor == nil
      ? ""
      : String(localized: "已高亮当前搜索命中区域")
  }

  private var imageToolbar: some View {
    HStack(spacing: 8) {
      Label("图片原稿", systemImage: "photo")
        .font(.headline)
      Spacer()
      Button {
        zoom = max(0.5, zoom - 0.25)
        gestureStartZoom = zoom
      } label: {
        Label("缩小", systemImage: "minus.magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .disabled(image == nil || zoom <= 0.5)

      Text("\(Int((zoom * 100).rounded()))%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 40)

      Button {
        zoom = min(4, zoom + 0.25)
        gestureStartZoom = zoom
      } label: {
        Label("放大", systemImage: "plus.magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .disabled(image == nil || zoom >= 4)

      Button("适合") {
        zoom = 1
        gestureStartZoom = 1
      }
      .disabled(image == nil || zoom == 1)

      Divider().frame(height: 18)

      Button {
        guard !ocrText.trimmedForPublishing.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ocrText, forType: .string)
      } label: {
        Label("复制识别文字", systemImage: "doc.on.doc")
      }
      .disabled(ocrText.trimmedForPublishing.isEmpty)

      Menu {
        Button("用系统默认应用打开") {
          if let imageURL { NSWorkspace.shared.open(imageURL) }
        }
        Button("在 Finder 中显示") {
          if let imageURL { NSWorkspace.shared.activateFileViewerSelecting([imageURL]) }
        }
      } label: {
        Label("更多图片操作", systemImage: "ellipsis.circle")
      }
      .disabled(imageURL == nil)
    }
  }

  private func imageCanvas(_ decodedImage: CGImage) -> some View {
    GeometryReader { proxy in
      let canvasSize = proxy.size
      let fittedRect = aspectFitRect(
        imageSize: CGSize(width: decodedImage.width, height: decodedImage.height),
        in: canvasSize
      )
      ZStack(alignment: .topLeading) {
        Image(decorative: decodedImage, scale: 1)
          .resizable()
          .scaledToFit()
          .frame(width: canvasSize.width, height: canvasSize.height)

        if let highlightedAnchor {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 3)
            }
            .frame(
              width: fittedRect.width * CGFloat(highlightedAnchor.width),
              height: fittedRect.height * CGFloat(highlightedAnchor.height)
            )
            .offset(
              x: fittedRect.minX + fittedRect.width * CGFloat(highlightedAnchor.x),
              y: fittedRect.minY
                + fittedRect.height
                * CGFloat(1 - highlightedAnchor.y - highlightedAnchor.height)
            )
            .accessibilityHidden(true)
        }
      }
      .scaleEffect(zoom)
      .frame(width: canvasSize.width, height: canvasSize.height)
      .contentShape(Rectangle())
      .gesture(
        MagnificationGesture()
          .onChanged { value in
            zoom = min(4, max(0.5, gestureStartZoom * value))
          }
          .onEnded { _ in gestureStartZoom = zoom }
      )
    }
  }

  private func aspectFitRect(imageSize: CGSize, in canvasSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
      canvasSize.width > 0, canvasSize.height > 0
    else { return .zero }
    let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
    let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: (canvasSize.width - fittedSize.width) / 2,
      y: (canvasSize.height - fittedSize.height) / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  @MainActor
  private func loadImage() async {
    image = nil
    guard let imageURL else {
      isLoading = false
      return
    }
    isLoading = true
    let result: KnowledgeDecodedImage? = await Task.detached(priority: .userInitiated) {
      () -> KnowledgeDecodedImage? in
      guard !Task.isCancelled,
        let decoded = WorkbenchImageIOThumbnailDecoder.downsampledImage(
          at: imageURL,
          maxPixelSize: WorkbenchThumbnailRequest.maximumPixelSize
        ),
        !Task.isCancelled
      else { return nil }
      return KnowledgeDecodedImage(value: decoded)
    }.value
    guard !Task.isCancelled else { return }
    image = result
    isLoading = false
  }
}
