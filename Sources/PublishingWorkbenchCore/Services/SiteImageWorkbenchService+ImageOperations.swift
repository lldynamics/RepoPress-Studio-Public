import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif
extension SiteImageWorkbenchService {
  public func optimizeJPEGAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    quality: CGFloat = 0.72,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var optimizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isJPEGFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      guard originalSize > 0 else {
        skippedCount += 1
        continue
      }

      let optimizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).jpg")

      if sourceURL.standardizedFileURL == optimizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向优化副本。")
        continue
      }

      try autoreleasepool {
        try writeOptimizedJPEG(from: sourceURL, to: optimizedURL, quality: quality)
      }
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: optimizedURL)
        throw CancellationError()
      }
      let optimizedSize = fileByteSize(at: optimizedURL) ?? originalSize

      if optimizedSize < originalSize {
        updatedDraft.attachments[index].sourceFilePath = optimizedURL.path
        updatedDraft.attachments[index].byteSize = optimizedSize
        optimizedCount += 1
        savedBytes += originalSize - optimizedSize
        messages.append("\(attachment.originalFilename)：减少 \(originalSize - optimizedSize) bytes。")
      } else {
        try? fileManager.removeItem(at: optimizedURL)
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：优化后没有变小，保留原图。")
      }
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: optimizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func convertAttachmentsToWebP(
    draft: ArticleDraft,
    destinationDirectory: URL,
    quality: CGFloat = 0.78,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var convertedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isWebPConvertibleFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      guard originalSize > 0 else {
        skippedCount += 1
        continue
      }

      let webPURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).webp")

      if sourceURL.standardizedFileURL == webPURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经是 WebP 优化副本。")
        continue
      }

      try autoreleasepool {
        try writeConvertedWebP(
          from: sourceURL,
          to: webPURL,
          quality: quality,
          cancellationToken: cancellationToken
        )
      }
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: webPURL)
        throw CancellationError()
      }
      let webPSize = fileByteSize(at: webPURL) ?? originalSize
      let oldPublishPath = attachment.relativePublishPath
      let newPublishPath = pathByReplacingExtension(oldPublishPath, with: "webp")
      let oldRepositoryPath = attachment.repositoryPath
      let newRepositoryPath = pathByReplacingExtension(oldRepositoryPath, with: "webp")
      let newFilename = pathByReplacingExtension(attachment.originalFilename, with: "webp")

      updatedDraft.attachments[index].originalFilename = newFilename
      updatedDraft.attachments[index].relativePublishPath = newPublishPath
      updatedDraft.attachments[index].repositoryPath = newRepositoryPath
      updatedDraft.attachments[index].repositorySHA = nil
      updatedDraft.attachments[index].sourceFilePath = webPURL.path
      updatedDraft.attachments[index].byteSize = webPSize
      updatedDraft.bodyMarkdown = replaceMarkdownImagePath(
        in: updatedDraft.bodyMarkdown,
        oldPath: oldPublishPath,
        newPath: newPublishPath
      )
      convertedCount += 1
      savedBytes += max(0, originalSize - webPSize)

      if webPSize < originalSize {
        messages.append("\(attachment.originalFilename)：已转换为 WebP，减少 \(originalSize - webPSize) bytes。")
      } else {
        messages.append("\(attachment.originalFilename)：已转换为 WebP，体积未减少。")
      }

      if oldRepositoryPath != newRepositoryPath, oldPublishPath == newPublishPath {
        messages.append("\(attachment.originalFilename)：仓库路径已更新为 \(newRepositoryPath)。")
      }
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: convertedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func optimizeSVGAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var optimizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isSVGFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalData = try BoundedFileReader.data(
        at: sourceURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumSVGOptimizationByteCount
      )
      guard
        !originalData.isEmpty,
        let svgText = String(data: originalData, encoding: .utf8)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：不是可优化的 UTF-8 SVG，已跳过。")
        continue
      }

      let optimizedText = optimizedSVGText(svgText)
      let optimizedData = Data(optimizedText.utf8)
      guard optimizedData.count < originalData.count else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：优化后没有变小，保留原 SVG。")
        continue
      }

      let optimizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).svg")

      if sourceURL.standardizedFileURL == optimizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向优化副本。")
        continue
      }

      try? fileManager.removeItem(at: optimizedURL)
      try optimizedData.write(to: optimizedURL, options: .atomic)
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: optimizedURL)
        throw CancellationError()
      }

      updatedDraft.attachments[index].sourceFilePath = optimizedURL.path
      updatedDraft.attachments[index].byteSize = Int64(optimizedData.count)
      optimizedCount += 1
      savedBytes += Int64(originalData.count - optimizedData.count)
      messages.append("\(attachment.originalFilename)：SVG 优化减少 \(originalData.count - optimizedData.count) bytes。")
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: optimizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func resizeLargeAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    maxPixelDimension: Int = 1_600,
    quality: CGFloat = 0.82,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var resizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isResizableRasterFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      guard
        let dimensions = imageDimensions(at: sourceURL),
        max(dimensions.width, dimensions.height) > maxPixelDimension
      else {
        skippedCount += 1
        continue
      }

      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      let destinationExtension = URL(fileURLWithPath: attachment.originalFilename).pathExtension.lowercased().nilIfEmpty ?? "jpg"
      let resizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename))-resize.\(destinationExtension)")

      if sourceURL.standardizedFileURL == resizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向缩放副本。")
        continue
      }

      try autoreleasepool {
        try writeResizedImage(
          from: sourceURL,
          to: resizedURL,
          maxPixelDimension: maxPixelDimension,
          quality: quality
        )
      }
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: resizedURL)
        throw CancellationError()
      }

      let resizedSize = fileByteSize(at: resizedURL) ?? originalSize
      let resizedDimensions = imageDimensions(at: resizedURL)
      updatedDraft.attachments[index].sourceFilePath = resizedURL.path
      updatedDraft.attachments[index].byteSize = resizedSize
      resizedCount += 1
      savedBytes += max(0, originalSize - resizedSize)

      let dimensionText = resizedDimensions?.displayName ?? "\(maxPixelDimension)px 内"
      messages.append("\(attachment.originalFilename)：已缩放到 \(dimensionText)。")
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: resizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func cropAttachmentToAspectRatio(
    draft: ArticleDraft,
    attachmentID: UUID,
    destinationDirectory: URL,
    aspectWidth: CGFloat = 16,
    aspectHeight: CGFloat = 9,
    quality: CGFloat = 0.86
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var messages: [String] = []

    guard let index = updatedDraft.attachments.firstIndex(where: { $0.id == attachmentID }) else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["没有找到要裁剪的图片附件。"]
      )
    }

    let attachment = updatedDraft.attachments[index]
    guard isCroppableRasterFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：当前格式不适合直接裁剪。"]
      )
    }

    guard
      let sourceFilePath = attachment.sourceFilePath,
      fileManager.fileExists(atPath: sourceFilePath)
    else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：源文件不可用，无法裁剪。"]
      )
    }

    let sourceURL = URL(fileURLWithPath: sourceFilePath)
    let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
    let destinationExtension = URL(fileURLWithPath: attachment.originalFilename).pathExtension.lowercased().nilIfEmpty ?? "jpg"
    let croppedURL = destinationDirectory
      .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename))-crop.\(destinationExtension)")

    if sourceURL.standardizedFileURL == croppedURL.standardizedFileURL {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：已经指向裁剪副本。"]
      )
    }

    try writeCroppedImage(
      from: sourceURL,
      to: croppedURL,
      aspectWidth: aspectWidth,
      aspectHeight: aspectHeight,
      quality: quality
    )

    let croppedSize = fileByteSize(at: croppedURL) ?? originalSize
    updatedDraft.attachments[index].sourceFilePath = croppedURL.path
    updatedDraft.attachments[index].byteSize = croppedSize
    let savedBytes = max(0, originalSize - croppedSize)
    messages.append("\(attachment.originalFilename)：已裁剪为 \(Int(aspectWidth)):\(Int(aspectHeight))。")

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: 1,
      skippedCount: 0,
      savedBytes: savedBytes,
      messages: messages
    )
  }
}
