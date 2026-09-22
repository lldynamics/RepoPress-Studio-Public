import Foundation
import PublishingDomainContracts

@MainActor
final class AIChatOperationCoordinator {
  private var activeOperationID: UUID?
  private var activeOwnerToken: UUID?
  private var activeTarget: WorkbenchTaskTarget?
  private var cancellationRequested = false
  /// Kept only for the active operation; stale task rows cannot reach a later
  /// request because registration and cancellation both require its ID.
  private var activeCancellation: (() -> Void)?

  var currentOperationID: UUID? { activeOperationID }
  var currentTarget: WorkbenchTaskTarget? { activeTarget }

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
    activeCancellation?()
    return true
  }

  func requestCancellation(
    whileRunning isRunning: Bool,
    expectedOperationID: UUID,
    expectedOwnerToken: UUID? = nil
  ) -> Bool {
    guard isRunning, activeOperationID == expectedOperationID else { return false }
    if let expectedOwnerToken, activeOwnerToken != expectedOwnerToken { return false }
    cancellationRequested = true
    activeCancellation?()
    return true
  }

  func begin(
    ownerToken: UUID? = nil,
    target: WorkbenchTaskTarget? = nil
  ) -> UUID? {
    guard activeOperationID == nil else { return nil }
    let operationID = UUID()
    activeOperationID = operationID
    activeOwnerToken = ownerToken
    activeTarget = target
    cancellationRequested = false
    activeCancellation = nil
    return operationID
  }

  func registerCancellation(for operationID: UUID, cancellation: @escaping () -> Void) {
    guard activeOperationID == operationID else { return }
    activeCancellation = cancellation
    if cancellationRequested { cancellation() }
  }

  func finish(_ operationID: UUID) -> Bool {
    guard activeOperationID == operationID else { return false }
    activeOperationID = nil
    activeOwnerToken = nil
    activeTarget = nil
    cancellationRequested = false
    activeCancellation = nil
    return true
  }

  func check(_ operationID: UUID) throws {
    try Task.checkCancellation()
    guard activeOperationID == operationID, !cancellationRequested else {
      throw CancellationError()
    }
  }
}

public struct AIChatImageAttachmentLoadResult: Sendable {
  public let images: [AIChatImageAttachment]
  public let failures: [AIChatImageAttachmentLoadFailure]

  public var skippedCount: Int { failures.count }
  public var hasFailures: Bool { !failures.isEmpty }

  /// A mixed result is deliberately blocked before a request is created. UI
  /// call sites must show this error and leave the composer unchanged.
  public var submissionFailureMessage: String? {
    hasFailures ? failures.map(\.message).joined(separator: "\n") : nil
  }

  public init(
    images: [AIChatImageAttachment],
    failures: [AIChatImageAttachmentLoadFailure]
  ) {
    self.images = images
    self.failures = failures
  }
}

public struct AIChatImageAttachmentLoadFailure: Identifiable, Equatable, Sendable {
  public enum Reason: Equatable, Sendable {
    case missingSourceFile
    case unreadableFile
    case unsupportedFormat
    case emptyFile
    case exceedsSizeLimit
    case removedFromArticle
    case notImage
    case exceedsSelectionLimit

    public var description: String {
      switch self {
      case .missingSourceFile:
        return CoreL10n.text("找不到原始文件")
      case .unreadableFile:
        return CoreL10n.text("无法读取文件")
      case .unsupportedFormat:
        return CoreL10n.text("格式不支持（仅支持 PNG、JPEG、GIF 或 WebP）")
      case .emptyFile:
        return CoreL10n.text("文件为空")
      case .exceedsSizeLimit:
        return CoreL10n.format(
          "超过 %@ 限制",
          AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()
        )
      case .removedFromArticle:
        return CoreL10n.text("已从当前文章中移除")
      case .notImage:
        return CoreL10n.text("不是图片文件")
      case .exceedsSelectionLimit:
        return CoreL10n.format(
          "一次最多发送 %d 张图片",
          AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount
        )
      }
    }
  }

  public let attachmentID: UUID
  public let filename: String
  public let reason: Reason

  public var id: UUID { attachmentID }
  public var message: String {
    CoreL10n.format("图片“%@”%@。", filename, reason.description)
  }

  public init(attachmentID: UUID, filename: String, reason: Reason) {
    self.attachmentID = attachmentID
    self.filename = filename
    self.reason = reason
  }
}

enum AIChatImageAttachmentLoader {
  /// Loads every requested attachment and records each failure. Callers that
  /// submit a chat request must treat any failure as a local, recoverable
  /// preflight error so a mixed selection cannot become a partial request.
  static func loadResult(
    _ attachments: [DraftAttachment]
  ) -> AIChatImageAttachmentLoadResult {
    var images: [AIChatImageAttachment] = []
    var failures: [AIChatImageAttachmentLoadFailure] = []
    images.reserveCapacity(attachments.count)
    for attachment in attachments {
      guard let path = attachment.sourceFilePath?.nilIfEmpty else {
        failures.append(failure(for: attachment, reason: .missingSourceFile))
        continue
      }
      let url = URL(fileURLWithPath: path)
      let mimeType = mimeType(for: url)
      guard AIPublishingChatImageAttachmentPresentation.supportedMIMETypes.contains(mimeType) else {
        failures.append(failure(for: attachment, reason: .unsupportedFormat))
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true,
        let fileSize = values.fileSize
      else {
        failures.append(failure(for: attachment, reason: .unreadableFile))
        continue
      }
      guard fileSize > 0 else {
        failures.append(failure(for: attachment, reason: .emptyFile))
        continue
      }
      guard AIPublishingChatImageAttachmentPresentation.isWithinAttachmentSizeLimit(Int64(fileSize))
      else {
        failures.append(failure(for: attachment, reason: .exceedsSizeLimit))
        continue
      }
      let data: Data
      do {
        data = try BoundedFileReader.data(
          at: url,
          maximumByteCount: AIPublishingChatImageAttachmentPresentation.maxAttachmentBytes
        )
      } catch let error as BoundedFileReadError {
        let reason: AIChatImageAttachmentLoadFailure.Reason
        if case .exceedsByteLimit = error {
          reason = .exceedsSizeLimit
        } else {
          reason = .unreadableFile
        }
        failures.append(failure(for: attachment, reason: reason))
        continue
      } catch {
        failures.append(failure(for: attachment, reason: .unreadableFile))
        continue
      }
      guard data.count > 0 else {
        failures.append(failure(for: attachment, reason: .emptyFile))
        continue
      }
      guard
        AIPublishingChatImageAttachmentPresentation.isWithinAttachmentSizeLimit(Int64(data.count))
      else {
        failures.append(failure(for: attachment, reason: .exceedsSizeLimit))
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
    return AIChatImageAttachmentLoadResult(images: images, failures: failures)
  }

  /// Retained for image-text suggestion callers that intentionally skip
  /// unusable optional vision inputs.
  static func load(
    _ attachments: [DraftAttachment]
  ) -> (images: [AIChatImageAttachment], skippedCount: Int) {
    let result = loadResult(attachments)
    return (result.images, result.skippedCount)
  }

  private static func failure(
    for attachment: DraftAttachment,
    reason: AIChatImageAttachmentLoadFailure.Reason
  ) -> AIChatImageAttachmentLoadFailure {
    AIChatImageAttachmentLoadFailure(
      attachmentID: attachment.id,
      filename: attachment.originalFilename,
      reason: reason
    )
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
