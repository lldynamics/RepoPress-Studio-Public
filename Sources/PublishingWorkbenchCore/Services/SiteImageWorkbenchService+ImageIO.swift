import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif
extension SiteImageWorkbenchService {
  func fileByteSize(at url: URL) -> Int64? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else {
      return nil
    }
    return size.int64Value
  }

  func visibleIssueCount(_ report: ImageWorkbenchReport, severity: PreflightSeverity? = nil) -> Int {
    report.issues.filter { issue in
      issue.kind != .noImages && (severity == nil || issue.severity == severity)
    }.count
  }

  func coverPublishStatus(
    draft: ArticleDraft,
    profile: SiteProfile,
    items: [ImageWorkbenchItem]
  ) -> ImageCoverPublishStatus {
    let frontMatterFieldPath = profile.includeCoverInFrontMatter ? profile.siteKind.coverFrontMatterDisplayPath : nil

    guard profile.includeCoverInFrontMatter else {
      return ImageCoverPublishStatus(state: .disabled, frontMatterFieldPath: nil)
    }

    guard let coverID = draft.coverAttachmentID else {
      return ImageCoverPublishStatus(
        state: draft.isPrivate ? .privateSuppressed : .missingCover,
        frontMatterFieldPath: frontMatterFieldPath
      )
    }

    guard let attachment = draft.attachments.first(where: { $0.id == coverID }) else {
      return ImageCoverPublishStatus(
        state: draft.isPrivate ? .privateSuppressed : .missingAttachment,
        frontMatterFieldPath: frontMatterFieldPath,
        attachmentID: coverID
      )
    }

    let item = items.first(where: { $0.attachmentID == coverID })
    let fileExists = item?.fileExists ?? false
    let baseStatus = ImageCoverPublishStatus(
      state: .ready,
      frontMatterFieldPath: frontMatterFieldPath,
      attachmentID: coverID,
      originalFilename: attachment.originalFilename,
      relativePublishPath: attachment.relativePublishPath,
      repositoryPath: attachment.repositoryPath,
      sourceFilePath: attachment.sourceFilePath,
      fileExists: fileExists
    )

    if draft.isPrivate {
      var status = baseStatus
      status.state = .privateSuppressed
      return status
    }

    if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
      var status = baseStatus
      status.state = .missingPublishPath
      return status
    }

    if !fileExists {
      var status = baseStatus
      status.state = .missingSource
      return status
    }

    return baseStatus
  }

  func imageDimensions(at url: URL) -> ImageDimensions? {
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      ),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }

    return ImageDimensions(width: width.intValue, height: height.intValue)
  }

  func validatedImageSource(at url: URL) throws -> ValidatedImageSource {
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      ),
      CGImageSourceGetCount(source) > 0,
      let dimensions = imageDimensions(from: source)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(url.lastPathComponent)
    }

    let width = dimensions.width
    let height = dimensions.height
    let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
    guard
      width > 0,
      height > 0,
      width <= Self.maximumSafeInputPixelDimension,
      height <= Self.maximumSafeInputPixelDimension,
      !overflow,
      pixelCount <= Self.maximumSafeInputPixelCount
    else {
      throw ImageWorkbenchError.unsafeImageDimensions(
        filename: url.lastPathComponent,
        width: width,
        height: height
      )
    }

    return ValidatedImageSource(source: source, dimensions: dimensions)
  }

  func imageDimensions(from source: CGImageSource) -> ImageDimensions? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }
    return ImageDimensions(width: width.intValue, height: height.intValue)
  }

  func thumbnail(
    from source: CGImageSource,
    maximumPixelSize: Int,
    filename: String
  ) throws -> CGImage {
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(filename)
    }
    return image
  }

  func writeOptimizedJPEG(from sourceURL: URL, to destinationURL: URL, quality: CGFloat) throws {
    try? fileManager.removeItem(at: destinationURL)

    let validatedSource = try validatedImageSource(at: sourceURL)
    guard
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, validatedSource.source, 0, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  func writeConvertedWebP(
    from sourceURL: URL,
    to destinationURL: URL,
    quality: CGFloat,
    cancellationToken: ImageProcessingCancellationToken?
  ) throws {
    try? fileManager.removeItem(at: destinationURL)
    try cancellationToken?.throwIfCancelled()

    if !prefersCWebP, Self.supportsImageIOWebPEncoding {
      do {
        try writeConvertedWebPWithImageIO(from: sourceURL, to: destinationURL, quality: quality)
        return
      } catch {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    if let cwebPURL = cwebPExecutableOverride ?? Self.cwebPExecutableURL {
      try writeConvertedWebPWithCWebP(
        from: sourceURL,
        to: destinationURL,
        quality: quality,
        executableURL: cwebPURL,
        cancellationToken: cancellationToken
      )
      return
    }

    throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
  }

  func writeConvertedWebPWithImageIO(from sourceURL: URL, to destinationURL: URL, quality: CGFloat) throws {
    let validatedSource = try validatedImageSource(at: sourceURL)
    guard
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.webP.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, validatedSource.source, 0, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  func writeConvertedWebPWithCWebP(
    from sourceURL: URL,
    to destinationURL: URL,
    quality: CGFloat,
    executableURL: URL,
    cancellationToken: ImageProcessingCancellationToken?
  ) throws {
    let intermediateURL = destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent("\(UUID().uuidString)-webp-source.png")
    defer {
      try? fileManager.removeItem(at: intermediateURL)
    }
    var completedSuccessfully = false
    defer {
      if !completedSuccessfully {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    try writePNGIntermediate(from: sourceURL, to: intermediateURL)
    try cancellationToken?.throwIfCancelled()

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "-quiet",
      "-q",
      "\(max(1, min(100, Int((quality * 100).rounded()))))",
      intermediateURL.path,
      "-o",
      destinationURL.path,
    ]

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try process.run()

    let deadline = Date().addingTimeInterval(cwebPTimeout)
    while completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      if cancellationToken?.isCancelled == true {
        terminate(process, waitingOn: completion)
        throw CancellationError()
      }
      if Date() >= deadline {
        terminate(process, waitingOn: completion)
        throw ImageWorkbenchError.externalToolTimedOut("cwebp")
      }
    }

    guard process.terminationStatus == 0,
          fileManager.fileExists(atPath: destinationURL.path)
    else {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
    completedSuccessfully = true
  }

  func terminate(_ process: Process, waitingOn completion: DispatchSemaphore) {
    guard process.isRunning else { return }
    process.terminate()
    if completion.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
      #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      #endif
      _ = completion.wait(timeout: .now() + .seconds(1))
    }
  }

  func writePNGIntermediate(from sourceURL: URL, to destinationURL: URL) throws {
    try? fileManager.removeItem(at: destinationURL)

    let validatedSource = try validatedImageSource(at: sourceURL)
    let image = try thumbnail(
      from: validatedSource.source,
      maximumPixelSize: max(validatedSource.dimensions.width, validatedSource.dimensions.height),
      filename: sourceURL.lastPathComponent
    )
    guard
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    CGImageDestinationAddImage(destination, image, nil)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  func writeResizedImage(
    from sourceURL: URL,
    to destinationURL: URL,
    maxPixelDimension: Int,
    quality: CGFloat
  ) throws {
    try? fileManager.removeItem(at: destinationURL)

    let validatedSource = try validatedImageSource(at: sourceURL)
    let image = try thumbnail(
      from: validatedSource.source,
      maximumPixelSize: min(
        max(1, maxPixelDimension),
        max(validatedSource.dimensions.width, validatedSource.dimensions.height)
      ),
      filename: sourceURL.lastPathComponent
    )
    guard
      let destinationType = CGImageSourceGetType(validatedSource.source)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    guard
      let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  func writeCroppedImage(
    from sourceURL: URL,
    to destinationURL: URL,
    aspectWidth: CGFloat,
    aspectHeight: CGFloat,
    quality: CGFloat
  ) throws {
    guard aspectWidth > 0, aspectHeight > 0 else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }
    try? fileManager.removeItem(at: destinationURL)

    let validatedSource = try validatedImageSource(at: sourceURL)
    let image = try thumbnail(
      from: validatedSource.source,
      maximumPixelSize: min(
        Self.maximumCropWorkingPixelDimension,
        max(validatedSource.dimensions.width, validatedSource.dimensions.height)
      ),
      filename: sourceURL.lastPathComponent
    )
    guard
      let destinationType = CGImageSourceGetType(validatedSource.source)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let sourceWidth = CGFloat(image.width)
    let sourceHeight = CGFloat(image.height)
    let targetAspect = aspectWidth / aspectHeight
    let sourceAspect = sourceWidth / sourceHeight
    let cropRect: CGRect

    if sourceAspect > targetAspect {
      let cropWidth = (sourceHeight * targetAspect).rounded(.down)
      cropRect = CGRect(
        x: ((sourceWidth - cropWidth) / 2).rounded(.down),
        y: 0,
        width: cropWidth,
        height: sourceHeight
      )
    } else {
      let cropHeight = (sourceWidth / targetAspect).rounded(.down)
      cropRect = CGRect(
        x: 0,
        y: ((sourceHeight - cropHeight) / 2).rounded(.down),
        width: sourceWidth,
        height: cropHeight
      )
    }

    guard
      let croppedImage = image.cropping(to: cropRect),
      let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImage(destination, croppedImage, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }
}
