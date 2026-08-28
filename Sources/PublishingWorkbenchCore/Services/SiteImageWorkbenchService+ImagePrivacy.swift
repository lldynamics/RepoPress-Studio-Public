import Foundation

extension SiteImageWorkbenchService {
  public func sanitizeImagePrivacyAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var sanitizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let inspection: ImagePrivacyInspection
      do {
        inspection = try imagePrivacySanitizer.inspect(at: sourceURL)
      } catch ImagePrivacySanitizingError.unsupportedImage(_) {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：格式不支持隐私元数据清理，已跳过。")
        continue
      } catch {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：无法验证隐私元数据，已跳过。")
        continue
      }

      guard inspection.requiresSanitization else {
        skippedCount += 1
        continue
      }

      let extensionName = sourceURL.pathExtension.nilIfEmpty ?? "img"
      let destinationURL = destinationDirectory.appendingPathComponent(
        "\(attachment.id.uuidString)-privacy-clean.\(extensionName)"
      )
      do {
        let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
        let result = try imagePrivacySanitizer.sanitize(at: sourceURL, to: destinationURL)
        try cancellationToken?.throwIfCancelled()
        guard !result.outputInspection.requiresSanitization else {
          try? fileManager.removeItem(at: destinationURL)
          skippedCount += 1
          messages.append("\(attachment.originalFilename)：清理结果仍含敏感元数据，未应用。")
          continue
        }

        let sanitizedSize = fileByteSize(at: destinationURL) ?? originalSize
        updatedDraft.attachments[index].sourceFilePath = destinationURL.path
        updatedDraft.attachments[index].byteSize = sanitizedSize
        sanitizedCount += 1
        savedBytes += max(0, originalSize - sanitizedSize)
        messages.append("\(attachment.originalFilename)：已清除嵌入的隐私元数据。")
      } catch is CancellationError {
        try? fileManager.removeItem(at: destinationURL)
        throw CancellationError()
      } catch {
        try? fileManager.removeItem(at: destinationURL)
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：隐私信息清理失败，未应用。")
      }
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: sanitizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }
}
