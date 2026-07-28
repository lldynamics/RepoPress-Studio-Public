import Foundation

@MainActor
final class AIChatTransientSessionCache {
  private var sessionsByDraftID: [UUID: AIPublishingChatSessionState] = [:]
  private var accessOrder: [UUID: UInt64] = [:]
  private var accessSequence: UInt64 = 0
  private let maximumSessionCount: Int
  private let maximumImageBytes: Int64

  init(
    maximumSessionCount: Int = 12,
    maximumImageBytes: Int64 = 48_000_000
  ) {
    self.maximumSessionCount = max(1, maximumSessionCount)
    self.maximumImageBytes = max(0, maximumImageBytes)
  }

  var count: Int {
    sessionsByDraftID.count
  }

  func takeSession(for draftID: UUID) -> AIPublishingChatSessionState {
    accessOrder.removeValue(forKey: draftID)
    return sessionsByDraftID.removeValue(forKey: draftID)
      ?? AIPublishingChatSessionState()
  }

  func session(for draftID: UUID) -> AIPublishingChatSessionState? {
    guard let state = sessionsByDraftID[draftID] else { return nil }
    markAccessed(draftID)
    return state
  }

  func store(_ state: AIPublishingChatSessionState, for draftID: UUID) {
    if state.shouldCache {
      sessionsByDraftID[draftID] = state
      markAccessed(draftID)
      prune()
    } else {
      removeSession(for: draftID)
    }
  }

  func removeSession(for draftID: UUID) {
    sessionsByDraftID.removeValue(forKey: draftID)
    accessOrder.removeValue(forKey: draftID)
  }

  private func markAccessed(_ draftID: UUID) {
    accessSequence &+= 1
    accessOrder[draftID] = accessSequence
  }

  private func prune() {
    while sessionsByDraftID.count > maximumSessionCount,
          let oldestDraftID = oldestSessionID() {
      removeSession(for: oldestDraftID)
    }

    var totalImageBytes = sessionsByDraftID.values.reduce(Int64(0)) {
      $0 + $1.imageAttachmentByteCount
    }
    while totalImageBytes > maximumImageBytes,
          let oldestDraftID = oldestSessionID(containingImages: true),
          let state = sessionsByDraftID[oldestDraftID] {
      let trimmed = state.prepared(maxTotalImageBytes: -1)
      let removedBytes = state.imageAttachmentByteCount - trimmed.imageAttachmentByteCount
      guard removedBytes > 0 else { break }
      sessionsByDraftID[oldestDraftID] = trimmed
      totalImageBytes -= removedBytes
    }
  }

  private func oldestSessionID(containingImages: Bool = false) -> UUID? {
    sessionsByDraftID.keys
      .filter {
        !containingImages || (sessionsByDraftID[$0]?.imageAttachmentByteCount ?? 0) > 0
      }
      .min {
        (accessOrder[$0] ?? 0) < (accessOrder[$1] ?? 0)
      }
  }
}

@MainActor
final class AIChatOperationCoordinator {
  private var activeOperationID: UUID?
  private var cancellationRequested = false

  var isCancellationRequested: Bool {
    cancellationRequested
  }

  func setCancellationRequested(_ value: Bool) {
    cancellationRequested = value
  }

  func requestCancellation(whileRunning isRunning: Bool) -> Bool {
    guard isRunning, activeOperationID != nil else { return false }
    cancellationRequested = true
    return true
  }

  func begin() -> UUID? {
    guard activeOperationID == nil else { return nil }
    let operationID = UUID()
    activeOperationID = operationID
    cancellationRequested = false
    return operationID
  }

  func finish(_ operationID: UUID) -> Bool {
    guard activeOperationID == operationID else { return false }
    activeOperationID = nil
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
