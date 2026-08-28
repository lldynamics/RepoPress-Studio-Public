import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct KnowledgeImageMetadata: Codable, Hashable, Sendable {
  public var imageTypeIdentifier: String
  public var pixelWidth: Int
  public var pixelHeight: Int
  public var frameCount: Int
  public var recognizedRegionCount: Int
  public var wasPrivacySanitized: Bool

  public init(
    imageTypeIdentifier: String,
    pixelWidth: Int,
    pixelHeight: Int,
    frameCount: Int,
    recognizedRegionCount: Int,
    wasPrivacySanitized: Bool = false
  ) {
    self.imageTypeIdentifier = imageTypeIdentifier
    self.pixelWidth = max(0, pixelWidth)
    self.pixelHeight = max(0, pixelHeight)
    self.frameCount = max(0, frameCount)
    self.recognizedRegionCount = max(0, recognizedRegionCount)
    self.wasPrivacySanitized = wasPrivacySanitized
  }
}

package struct KnowledgeImageExtraction: Sendable {
  package var metadata: KnowledgeImageMetadata
  package var sections: [KnowledgeExtractedSection]
  package var capturedText: String
  package var warnings: [String]
}

package struct KnowledgeImageOCRService: Sendable {
  private static let maximumByteCount = 25 * 1_024 * 1_024
  private static let maximumDimension = 16_384
  private static let maximumPixelCount = 40_000_000
  private static let maximumOCRDimension = 2_048
  private static let supportedTypeIdentifiers: Set<String> = [
    "public.jpeg", "public.png", "public.heic", "public.heif", "org.webmproject.webp",
  ]

  package init() {}

  package func extract(data: Data, performsOCR: Bool) throws -> KnowledgeImageExtraction {
    try Task.checkCancellation()
    guard data.count <= Self.maximumByteCount else {
      throw KnowledgeLibraryError.sourceLimitExceeded("图片超过 25 MB。")
    }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [
          kCGImageSourceShouldCache: false,
          kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary), let type = CGImageSourceGetType(source)
    else {
      throw KnowledgeLibraryError.unsupportedSource("图片无法由 ImageIO 识别")
    }
    let typeIdentifier = type as String
    guard Self.supportedTypeIdentifiers.contains(typeIdentifier) else {
      throw KnowledgeLibraryError.unsupportedSource("不支持的图片实际类型：\(typeIdentifier)")
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount == 1 else {
      throw KnowledgeLibraryError.unsupportedSource("仅支持单帧 JPEG、PNG、HEIC/HEIF 图片。")
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0,
      width <= Self.maximumDimension, height <= Self.maximumDimension,
      width <= Self.maximumPixelCount / height
    else {
      throw KnowledgeLibraryError.sourceLimitExceeded("图片尺寸超过 16384 边长或 4000 万像素限制。")
    }
    guard performsOCR else {
      return KnowledgeImageExtraction(
        metadata: KnowledgeImageMetadata(
          imageTypeIdentifier: typeIdentifier, pixelWidth: width, pixelHeight: height,
          frameCount: frameCount, recognizedRegionCount: 0),
        sections: [], capturedText: "", warnings: ["已关闭图片 OCR；图片仅以文件名可检索。"]
      )
    }
    guard let image = downsampledImage(source: source, width: width, height: height) else {
      throw KnowledgeLibraryError.unreadableSource("图片无法解码")
    }
    try Task.checkCancellation()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      try Task.checkCancellation()
      return KnowledgeImageExtraction(
        metadata: KnowledgeImageMetadata(
          imageTypeIdentifier: typeIdentifier,
          pixelWidth: width,
          pixelHeight: height,
          frameCount: frameCount,
          recognizedRegionCount: 0
        ),
        sections: [],
        capturedText: "",
        warnings: ["图片可正常导入，但本机 OCR 无法识别；已回退为文件名检索。"]
      )
    }
    try Task.checkCancellation()
    let observations = (request.results ?? []).sorted {
      if $0.boundingBox.maxY != $1.boundingBox.maxY {
        return $0.boundingBox.maxY > $1.boundingBox.maxY
      }
      return $0.boundingBox.minX < $1.boundingBox.minX
    }
    let sections = observations.compactMap { observation -> KnowledgeExtractedSection? in
      guard let candidate = observation.topCandidates(1).first,
        !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      let box = observation.boundingBox
      return KnowledgeExtractedSection(
        locator: "OCR 区域",
        text: candidate.string,
        visualAnchor: KnowledgeVisualAnchor(
          x: Double(box.origin.x), y: Double(box.origin.y),
          width: Double(box.width), height: Double(box.height),
          confidence: Double(candidate.confidence)
        )
      )
    }
    return KnowledgeImageExtraction(
      metadata: KnowledgeImageMetadata(
        imageTypeIdentifier: typeIdentifier, pixelWidth: width, pixelHeight: height,
        frameCount: frameCount, recognizedRegionCount: sections.count),
      sections: sections,
      capturedText: sections.map(\.text).joined(separator: "\n"),
      warnings: sections.isEmpty ? ["图片未识别到文字。"] : ["已在本机使用 Vision OCR 识别图片文字。"]
    )
  }

  private func downsampledImage(source: CGImageSource, width: Int, height: Int) -> CGImage? {
    let maxDimension = max(width, height)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, Self.maximumOCRDimension),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
