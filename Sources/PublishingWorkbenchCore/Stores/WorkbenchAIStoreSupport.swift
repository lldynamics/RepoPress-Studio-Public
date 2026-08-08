import Foundation

@MainActor
final class AIChatOperationCoordinator {
  private var activeOperationID: UUID?
  private var activeOwnerToken: UUID?
  private var cancellationRequested = false

  var isCancellationRequested: Bool {
    cancellationRequested
  }

  func setCancellationRequested(_ value: Bool) {
    cancellationRequested = value
  }

  func requestCancellation(
    whileRunning isRunning: Bool,
    expectedOwnerToken: UUID? = nil
  ) -> Bool {
    guard isRunning, activeOperationID != nil else { return false }
    if let expectedOwnerToken, activeOwnerToken != expectedOwnerToken {
      return false
    }
    cancellationRequested = true
    return true
  }

  func begin(ownerToken: UUID? = nil) -> UUID? {
    guard activeOperationID == nil else { return nil }
    let operationID = UUID()
    activeOperationID = operationID
    activeOwnerToken = ownerToken
    cancellationRequested = false
    return operationID
  }

  func finish(_ operationID: UUID) -> Bool {
    guard activeOperationID == operationID else { return false }
    activeOperationID = nil
    activeOwnerToken = nil
    cancellationRequested = false
    return true
  }

  func check(_ operationID: UUID) throws {
    try Task.checkCancellation()
    guard activeOperationID == operationID, !cancellationRequested else {
      throw CancellationError()
    }
  }
}

enum AIChatImageAttachmentLoader {
  static func load(
    _ attachments: [DraftAttachment]
  ) -> (images: [AIChatImageAttachment], skippedCount: Int) {
    var images: [AIChatImageAttachment] = []
    images.reserveCapacity(attachments.count)
    for attachment in attachments {
      guard let path = attachment.sourceFilePath?.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: path)
      let mimeType = mimeType(for: url)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
              mimeType: mimeType,
              byteSize: Int64(fileSize)
            ),
            let data = try? BoundedFileReader.data(
              at: url,
              maximumByteCount: max(fileSize, 1)
            ),
            AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
              mimeType: mimeType,
              byteSize: Int64(data.count)
            ) else {
        continue
      }
      images.append(
        AIChatImageAttachment(
          filename: attachment.originalFilename,
          mimeType: mimeType,
          data: data
        )
      )
    }
    return (images, attachments.count - images.count)
  }

  private static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    case "avif": return "image/avif"
    case "heic": return "image/heic"
    case "tif", "tiff": return "image/tiff"
    default: return "application/octet-stream"
    }
  }
}
