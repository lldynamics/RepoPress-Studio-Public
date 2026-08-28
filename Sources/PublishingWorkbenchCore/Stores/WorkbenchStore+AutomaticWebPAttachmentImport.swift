import Foundation
import OSLog

private let automaticWebPAttachmentImportLogger = Logger(
  subsystem: "com.jinfang.PersonalSitePublisherMac",
  category: "AutomaticWebPAttachmentImport"
)

extension WorkbenchStore {
  /// The result of importing an image dropped into the editor.
  ///
  /// `savedPercentage` is rounded to the nearest whole percent and is always
  /// bounded to 0...100, making it suitable for a lightweight UI toast.
  public struct AutomaticWebPAttachmentImportResult: Sendable {
    public let attachment: DraftAttachment
    public let wasConvertedToWebP: Bool
    public let originalByteSize: Int64
    public let finalByteSize: Int64
    public let savedBytes: Int64
    public let savedPercentage: Double

    public init(
      attachment: DraftAttachment,
      wasConvertedToWebP: Bool,
      originalByteSize: Int64,
      finalByteSize: Int64
    ) {
      self.attachment = attachment
      self.wasConvertedToWebP = wasConvertedToWebP
      self.originalByteSize = max(0, originalByteSize)
      self.finalByteSize = max(0, finalByteSize)
      self.savedBytes = max(0, self.originalByteSize - self.finalByteSize)
      guard self.originalByteSize > 0 else {
        self.savedPercentage = 0
        return
      }
      self.savedPercentage = min(
        100,
        max(0, (Double(self.savedBytes) / Double(self.originalByteSize) * 100).rounded())
      )
    }
  }

  /// Imports one dropped image into managed storage and opportunistically
  /// converts raster formats to WebP in that attachment's own directory.
  ///
  /// Unsupported image formats and existing WebP files remain intact. A
  /// failed conversion never leaves a managed original or partial WebP behind.
  public func makeAutomaticWebPAttachment(
    from url: URL,
    draft: ArticleDraft,
    fileStore: ManagedAttachmentFileStore? = nil,
    imageService: SiteImageWorkbenchService? = nil
  ) async throws -> AutomaticWebPAttachmentImportResult {
    let resolvedFileStore = fileStore ?? managedAttachmentFileStore
    let resolvedImageService = imageService ?? SiteImageWorkbenchService()
    let imported = try await makeAttachment(
      from: url,
      draft: draft,
      fileStore: resolvedFileStore
    )
    let originalURL = URL(fileURLWithPath: imported.sourceFilePath ?? "")
    let originalByteSize = Self.fileByteSize(at: originalURL) ?? imported.byteSize
    let extensionName = URL(fileURLWithPath: imported.originalFilename)
      .pathExtension.lowercased()

    // The conversion service intentionally excludes WebP and non-raster
    // formats. Keep the managed import as-is for those inputs.
    guard extensionName != "webp",
      ["jpg", "jpeg", "png", "heic", "tif", "tiff", "avif"].contains(extensionName),
      let sourcePath = imported.sourceFilePath
    else {
      return AutomaticWebPAttachmentImportResult(
        attachment: imported,
        wasConvertedToWebP: false,
        originalByteSize: originalByteSize,
        finalByteSize: originalByteSize
      )
    }

    let sourceURL = URL(fileURLWithPath: sourcePath)
    let destinationDirectory = sourceURL.deletingLastPathComponent()
    let expectedWebPURL = destinationDirectory.appendingPathComponent(
      "\(imported.id.uuidString)-\(SlugService.slug(from: imported.originalFilename)).webp"
    )
    var conversionResult: ImageOptimizationResult?
    do {
      try Task.checkCancellation()
      var conversionDraft = ArticleDraft(
        id: draft.id,
        siteProfileID: draft.siteProfileID,
        title: draft.title,
        date: draft.date,
        slug: draft.slug,
        bodyMarkdown: draft.bodyMarkdown
      )
      conversionDraft.attachments = [imported]
      conversionResult = try await Task.detached(priority: .userInitiated) {
        try resolvedImageService.convertAttachmentsToWebP(
          draft: conversionDraft,
          destinationDirectory: destinationDirectory
        )
      }.value
      try Task.checkCancellation()
      guard let converted = conversionResult,
        let finalAttachment = converted.draft.attachments.first,
        converted.optimizedCount == 1,
        let finalPath = finalAttachment.sourceFilePath
      else {
        return AutomaticWebPAttachmentImportResult(
          attachment: imported,
          wasConvertedToWebP: false,
          originalByteSize: originalByteSize,
          finalByteSize: originalByteSize
        )
      }

      let finalURL = URL(fileURLWithPath: finalPath)
      let finalByteSize = Self.fileByteSize(at: finalURL) ?? finalAttachment.byteSize
      // The imported original is superseded only after the WebP is complete.
      try resolvedFileStore.discardStoredFile(at: sourceURL)
      return AutomaticWebPAttachmentImportResult(
        attachment: finalAttachment,
        wasConvertedToWebP: true,
        originalByteSize: originalByteSize,
        finalByteSize: finalByteSize
      )
    } catch {
      // Conversion may have created a partial output before throwing. Both
      // paths are inside this attachment's managed directory and are safe to
      // discard through the store's root-boundary check.
      Self.discardManagedPartialAttachment(
        at: sourceURL,
        fileStore: resolvedFileStore
      )
      Self.discardManagedPartialAttachment(
        at: expectedWebPURL,
        fileStore: resolvedFileStore
      )
      if let conversionResult,
        let partialPath = conversionResult.draft.attachments.first?.sourceFilePath
      {
        Self.discardManagedPartialAttachment(
          at: URL(fileURLWithPath: partialPath),
          fileStore: resolvedFileStore
        )
      }
      throw error
    }
  }

  /// Retains the conversion failure as the user-visible error while recording
  /// a failed cleanup. `ManagedAttachmentFileStore` rejects every URL outside
  /// its exact root before attempting removal.
  private static func discardManagedPartialAttachment(
    at url: URL,
    fileStore: ManagedAttachmentFileStore
  ) {
    do {
      try fileStore.discardStoredFile(at: url)
    } catch {
      automaticWebPAttachmentImportLogger.warning(
        "WebP conversion cleanup failed for managed attachment \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
      )
    }
  }

  private static func fileByteSize(at url: URL) -> Int64? {
    guard !url.path.isEmpty,
      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    else { return nil }
    return Int64(size)
  }
}
