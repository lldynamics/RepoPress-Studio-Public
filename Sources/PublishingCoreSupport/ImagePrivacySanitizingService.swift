import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Identifies a metadata family that can disclose information about an image's
/// origin, author, camera, or location.
public enum ImagePrivacySensitiveMetadata: String, CaseIterable, Hashable, Sendable {
  case gps
  case exif
  case exifAux
  case iptc
  case tiffAuthorOrDevice
  case maker
  case xmp
  case photoshop
}

/// A value-only report of the metadata ImageIO can read from the first frame.
public struct ImagePrivacyInspection: Equatable, Sendable {
  public let imageTypeIdentifier: String
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let orientation: Int?
  public let frameCount: Int
  public let sensitiveMetadata: Set<ImagePrivacySensitiveMetadata>

  public var requiresSanitization: Bool {
    !sensitiveMetadata.isEmpty
  }

  public init(
    imageTypeIdentifier: String,
    pixelWidth: Int,
    pixelHeight: Int,
    orientation: Int?,
    frameCount: Int,
    sensitiveMetadata: Set<ImagePrivacySensitiveMetadata>
  ) {
    self.imageTypeIdentifier = imageTypeIdentifier
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.orientation = orientation
    self.frameCount = frameCount
    self.sensitiveMetadata = sensitiveMetadata
  }
}

public enum ImagePrivacySanitizationMethod: String, Equatable, Sendable {
  /// ImageIO copied the encoded image data while replacing its properties.
  case metadataCopy
  /// ImageIO decoded the image then wrote a clean encoded image as a fallback.
  case decodedReencode
}

public struct ImagePrivacySanitizationResult: Equatable, Sendable {
  public let sourceURL: URL
  public let destinationURL: URL
  public let method: ImagePrivacySanitizationMethod
  public let originalInspection: ImagePrivacyInspection
  public let sanitizedInspection: ImagePrivacyInspection

  /// Compatibility spelling for callers that treat sanitization as an input /
  /// output transformation.
  public var outputInspection: ImagePrivacyInspection {
    sanitizedInspection
  }

  public init(
    sourceURL: URL,
    destinationURL: URL,
    method: ImagePrivacySanitizationMethod,
    originalInspection: ImagePrivacyInspection,
    sanitizedInspection: ImagePrivacyInspection
  ) {
    self.sourceURL = sourceURL
    self.destinationURL = destinationURL
    self.method = method
    self.originalInspection = originalInspection
    self.sanitizedInspection = sanitizedInspection
  }
}

public enum ImagePrivacySanitizingError: LocalizedError, Equatable, Sendable {
  case sourceUnavailable(path: String)
  case destinationMustDiffer(path: String)
  case destinationExists(path: String)
  case unsupportedImage(typeIdentifier: String?)
  case multiFrameImage(frameCount: Int)
  case invalidImage(reason: String)
  case writeFailed(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let path):
      return "图片源文件不可读取：\(path)"
    case .destinationMustDiffer(let path):
      return "脱敏副本不能覆盖原图：\(path)"
    case .destinationExists(let path):
      return "脱敏副本目标已存在：\(path)"
    case .unsupportedImage(let typeIdentifier):
      return "不支持的图片类型：\(typeIdentifier ?? "未知类型")"
    case .multiFrameImage(let frameCount):
      return "为避免破坏动画或多帧图片，已拒绝处理 \(frameCount) 帧图片。"
    case .invalidImage(let reason):
      return "图片无效：\(reason)"
    case .writeFailed(let path, let reason):
      return "无法写入脱敏副本：\(path)。\(reason)"
    }
  }
}

/// Reads and removes common identifying metadata from a single-frame raster
/// image. The original file is never changed: output is staged beside the
/// requested destination and only published after a clean re-inspection.
public struct ImagePrivacySanitizingService: Sendable {
  public init() {}

  public func inspect(at sourceURL: URL) throws -> ImagePrivacyInspection {
    let source = try validatedSource(at: sourceURL)
    return try inspection(for: source)
  }

  @discardableResult
  public func sanitize(
    at sourceURL: URL,
    to destinationURL: URL
  ) throws -> ImagePrivacySanitizationResult {
    let sourceURL = sourceURL.standardizedFileURL
    let destinationURL = destinationURL.standardizedFileURL
    guard sourceURL != destinationURL else {
      throw ImagePrivacySanitizingError.destinationMustDiffer(path: sourceURL.path)
    }

    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw ImagePrivacySanitizingError.destinationExists(path: destinationURL.path)
    }
    guard fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path) else {
      throw ImagePrivacySanitizingError.writeFailed(
        path: destinationURL.path,
        reason: "目标目录不存在。"
      )
    }

    let source = try validatedSource(at: sourceURL)
    let originalInspection = try inspection(for: source)
    guard originalInspection.frameCount == 1 else {
      throw ImagePrivacySanitizingError.multiFrameImage(
        frameCount: originalInspection.frameCount
      )
    }
    guard let imageType = CGImageSourceGetType(source) else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "缺少图片类型。")
    }

    let sourceProperties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      ?? [:]
    let metadataCopyOverrides = metadataCopyOverrides(for: sourceProperties)
    let decodedProperties = decodedReencodeProperties(from: sourceProperties)
    let sourceExtension = sourceURL.pathExtension
    let stagingFilename =
      sourceExtension.isEmpty
      ? ".image-privacy-\(UUID().uuidString.lowercased()).stage"
      : ".image-privacy-\(UUID().uuidString.lowercased()).stage.\(sourceExtension)"
    let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      stagingFilename
    )
    defer { try? fileManager.removeItem(at: stagingURL) }

    let method: ImagePrivacySanitizationMethod
    let sanitizedInspection: ImagePrivacyInspection
    if writeMetadataCopy(
      source: source,
      imageType: imageType,
      properties: metadataCopyOverrides,
      to: stagingURL
    ), let verifiedInspection = cleanInspection(at: stagingURL) {
      method = .metadataCopy
      sanitizedInspection = verifiedInspection
    } else {
      try? fileManager.removeItem(at: stagingURL)
      guard
        writeDecodedReencode(
          source: source,
          imageType: imageType,
          properties: decodedProperties,
          to: stagingURL
        ), let verifiedInspection = cleanInspection(at: stagingURL)
      else {
        throw ImagePrivacySanitizingError.writeFailed(
          path: destinationURL.path,
          reason: "ImageIO 未能编码可复检的脱敏副本。"
        )
      }
      method = .decodedReencode
      sanitizedInspection = verifiedInspection
    }

    do {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    } catch {
      throw ImagePrivacySanitizingError.writeFailed(
        path: destinationURL.path,
        reason: error.localizedDescription
      )
    }
    return ImagePrivacySanitizationResult(
      sourceURL: sourceURL,
      destinationURL: destinationURL,
      method: method,
      originalInspection: originalInspection,
      sanitizedInspection: sanitizedInspection
    )
  }

  private func validatedSource(at sourceURL: URL) throws -> CGImageSource {
    let fileManager = FileManager.default
    guard fileManager.isReadableFile(atPath: sourceURL.path),
      let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else {
      throw ImagePrivacySanitizingError.sourceUnavailable(path: sourceURL.path)
    }
    guard
      let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      ), let imageType = CGImageSourceGetType(source)
    else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "ImageIO 无法读取该文件。")
    }
    let typeIdentifier = imageType as String
    // Reaching this point already proves ImageIO recognized a decodable image
    // source. UTType conformance databases are not guaranteed to be available
    // in every command-line/test host, so use the concrete PDF exclusion here
    // instead of rejecting valid JPEG/PNG sources when `conforms(to:)` is false.
    guard typeIdentifier != UTType.pdf.identifier else {
      throw ImagePrivacySanitizingError.unsupportedImage(typeIdentifier: typeIdentifier)
    }
    guard CGImageSourceGetCount(source) > 0 else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "图片不含可读取帧。")
    }
    return source
  }

  private func inspection(for source: CGImageSource) throws -> ImagePrivacyInspection {
    guard let imageType = CGImageSourceGetType(source) else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "缺少图片类型。")
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "无法读取图片属性。")
    }
    let width = properties[kCGImagePropertyPixelWidth] as? NSNumber
    let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    guard let width, let height, width.intValue > 0, height.intValue > 0 else {
      throw ImagePrivacySanitizingError.invalidImage(reason: "图片尺寸无效。")
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    return ImagePrivacyInspection(
      imageTypeIdentifier: imageType as String,
      pixelWidth: width.intValue,
      pixelHeight: height.intValue,
      orientation: orientation,
      frameCount: frameCount,
      sensitiveMetadata: sensitiveMetadata(in: properties)
    )
  }

  private func writeMetadataCopy(
    source: CGImageSource,
    imageType: CFString,
    properties: [CFString: Any],
    to destinationURL: URL
  ) -> Bool {
    guard
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        imageType,
        1,
        nil
      )
    else { return false }
    CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  private func writeDecodedReencode(
    source: CGImageSource,
    imageType: CFString,
    properties: [CFString: Any],
    to destinationURL: URL
  ) -> Bool {
    try? FileManager.default.removeItem(at: destinationURL)
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        imageType,
        1,
        nil
      )
    else { return false }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  private func sensitiveMetadata(in properties: [CFString: Any]) -> Set<
    ImagePrivacySensitiveMetadata
  > {
    var result: Set<ImagePrivacySensitiveMetadata> = []
    if containsMetadata(properties[kCGImagePropertyGPSDictionary]) { result.insert(.gps) }
    if containsSensitiveExifMetadata(properties[kCGImagePropertyExifDictionary]) {
      result.insert(.exif)
    }
    if containsMetadata(properties[kCGImagePropertyExifAuxDictionary]) { result.insert(.exifAux) }
    if containsMetadata(properties[kCGImagePropertyIPTCDictionary]) { result.insert(.iptc) }
    if containsMetadata(properties[xmpPropertyKey]) { result.insert(.xmp) }
    if containsMetadata(properties[kCGImageProperty8BIMDictionary]) { result.insert(.photoshop) }

    for (key, value) in properties {
      let name = key as String
      if name.localizedCaseInsensitiveContains("maker"), containsMetadata(value) {
        result.insert(.maker)
      }
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
      tiff.contains(where: {
        tiffSensitiveFieldNames.contains($0.key as String) && containsMetadata($0.value)
      })
    {
      result.insert(.tiffAuthorOrDevice)
    } else if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any],
      tiff.contains(where: {
        tiffSensitiveFieldNames.contains($0.key) && containsMetadata($0.value)
      })
    {
      result.insert(.tiffAuthorOrDevice)
    }
    return result
  }

  /// A decoded image already carries its color space. Reusing the complete
  /// source property dictionary here can feed format-specific/read-only keys
  /// back to an encoder and make the privacy fallback fail. Preserve only the
  /// display orientation plus a high-quality lossy setting; no source metadata
  /// dictionaries are reintroduced.
  private func decodedReencodeProperties(
    from properties: [CFString: Any]
  ) -> [CFString: Any] {
    var result: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 1.0
    ]
    if let orientation = properties[kCGImagePropertyOrientation] {
      result[kCGImagePropertyOrientation] = orientation
    }
    return result
  }

  /// `CGImageDestinationAddImageFromSource` inherits source metadata. ImageIO
  /// uses `kCFNull` (rather than an omitted key) as the explicit deletion
  /// instruction, so this intentionally contains only replacement overrides.
  private func metadataCopyOverrides(for properties: [CFString: Any]) -> [CFString: Any] {
    let deleteValue = kCFNull!
    var overrides: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: deleteValue,
      kCGImagePropertyExifDictionary: deleteValue,
      kCGImagePropertyExifAuxDictionary: deleteValue,
      kCGImagePropertyIPTCDictionary: deleteValue,
      xmpPropertyKey: deleteValue,
      kCGImageProperty8BIMDictionary: deleteValue,
      kCGImagePropertyTIFFDictionary: deleteValue,
    ]
    for key in properties.keys where (key as String).localizedCaseInsensitiveContains("maker") {
      overrides[key] = deleteValue
    }
    return overrides
  }

  private func cleanInspection(at url: URL) -> ImagePrivacyInspection? {
    do {
      let inspection = try inspect(at: url)
      guard inspection.sensitiveMetadata.isEmpty else { return nil }
      return inspection
    } catch {
      return nil
    }
  }

  private func containsSensitiveExifMetadata(_ value: Any?) -> Bool {
    let safeStructuralKeys: Set<String> = [
      "ColorSpace", "PixelXDimension", "PixelYDimension",
    ]
    if let dictionary = value as? [CFString: Any] {
      return dictionary.contains {
        !safeStructuralKeys.contains($0.key as String) && containsMetadata($0.value)
      }
    }
    if let dictionary = value as? [String: Any] {
      return dictionary.contains {
        !safeStructuralKeys.contains($0.key) && containsMetadata($0.value)
      }
    }
    return containsMetadata(value)
  }

  private func containsMetadata(_ value: Any?) -> Bool {
    guard let value else { return false }
    if let dictionary = value as? [CFString: Any] { return !dictionary.isEmpty }
    if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
    return true
  }

  private var tiffSensitiveFieldNames: Set<String> {
    [
      "Artist", "Copyright", "DateTime", "DateTimeDigitized", "HostComputer",
      "ImageDescription", "Make", "Model", "Software",
    ]
  }

  /// ImageIO exposes XMP as the `XMP` property key on macOS, but does not
  /// import a Swift constant for that key on every SDK.
  private var xmpPropertyKey: CFString {
    "XMP" as CFString
  }
}
