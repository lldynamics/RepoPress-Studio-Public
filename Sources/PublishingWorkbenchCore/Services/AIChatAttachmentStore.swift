import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores chat images outside WorkbenchSnapshot. Blob names are SHA-256 based,
/// so repeated images are stored once even when used in multiple conversations.
struct AIChatAttachmentStore {
  static let maxSessionImageBytes: Int64 = 24_000_000

  let directoryURL: URL
  private let fileManager: FileManager

  init(directoryURL: URL, fileManager: FileManager = .default) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
  }

  func persistedSessions(
    _ sessions: [UUID: AIPublishingChatSessionState],
    shouldReclaimUnreferencedFiles: Bool = true
  ) throws -> [UUID: AIPublishingChatSessionState] {
    var persisted: [UUID: AIPublishingChatSessionState] = [:]
    for (draftID, state) in sessions {
      var prepared = state.prepared(maxTotalImageBytes: Self.maxSessionImageBytes)
      prepared.messages = try prepared.messages.map(persistedMessage)
      prepared.archivedConversations = try prepared.archivedConversations.map { conversation in
        var persistedConversation = conversation
        persistedConversation.messages = try conversation.messages.map(persistedMessage)
        return persistedConversation
      }
      persisted[draftID] = prepared
    }
    // A background autosave may have been superseded while it was encoding.
    // It can safely add deduplicated blobs, but must never delete files that a
    // newer snapshot has just started referencing. Cleanup therefore runs only
    // for ordered foreground saves.
    if shouldReclaimUnreferencedFiles {
      try reclaimUnreferencedFiles(from: persisted)
    }
    return persisted
  }

  func hydratedSessions(
    _ sessions: [UUID: AIPublishingChatSessionState]
  ) -> [UUID: AIPublishingChatSessionState] {
    sessions.mapValues { state in
      var hydrated = state
      hydrated.messages = state.messages.map(hydratedMessage)
      hydrated.archivedConversations = state.archivedConversations.map { conversation in
        var hydratedConversation = conversation
        hydratedConversation.messages = conversation.messages.map(hydratedMessage)
        return hydratedConversation
      }
      return hydrated
    }
  }

  private func persistedMessage(_ message: AIPublishingChatMessage) throws -> AIPublishingChatMessage {
    var persisted = message
    persisted.imageAttachments = try message.imageAttachments.map(persistedAttachment)
    return persisted
  }

  private func persistedAttachment(_ attachment: AIChatImageAttachment) throws -> AIChatImageAttachment {
    guard !attachment.data.isEmpty else {
      return attachment
    }
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let digest = SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined()
    let blobReference = "\(digest).blob"
    let blobURL = directoryURL.appendingPathComponent(blobReference)
    if !fileManager.fileExists(atPath: blobURL.path) {
      try attachment.data.write(to: blobURL, options: .atomic)
    }

    var persisted = attachment
    persisted.storageReference = blobReference
    persisted.byteCount = Int64(attachment.data.count)
    if let thumbnail = thumbnailData(for: attachment.data) {
      let thumbnailReference = "\(digest).thumbnail.jpg"
      let thumbnailURL = directoryURL.appendingPathComponent(thumbnailReference)
      if !fileManager.fileExists(atPath: thumbnailURL.path) {
        try thumbnail.write(to: thumbnailURL, options: .atomic)
      }
      persisted.thumbnailReference = thumbnailReference
    }
    return persisted
  }

  private func hydratedMessage(_ message: AIPublishingChatMessage) -> AIPublishingChatMessage {
    var hydrated = message
    hydrated.imageAttachments = message.imageAttachments.map { attachment in
      guard attachment.data.isEmpty,
            let reference = attachment.storageReference?.nilIfEmpty,
            isSafeReference(reference),
            let data = try? Data(contentsOf: directoryURL.appendingPathComponent(reference))
      else {
        return attachment
      }
      var hydratedAttachment = attachment
      hydratedAttachment.data = data
      hydratedAttachment.byteCount = Int64(data.count)
      return hydratedAttachment
    }
    return hydrated
  }

  private func reclaimUnreferencedFiles(from sessions: [UUID: AIPublishingChatSessionState]) throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    let references = Set(
      sessions.values.flatMap { state in
        state.messages.flatMap(attachmentReferences)
          + state.archivedConversations.flatMap { $0.messages.flatMap(attachmentReferences) }
      }
    )
    for fileURL in try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) where isSafeReference(fileURL.lastPathComponent) && !references.contains(fileURL.lastPathComponent) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  private func attachmentReferences(_ message: AIPublishingChatMessage) -> [String] {
    message.imageAttachments.flatMap { attachment in
      [attachment.storageReference, attachment.thumbnailReference].compactMap { $0?.nilIfEmpty }
    }
  }

  private func isSafeReference(_ reference: String) -> Bool {
    reference.range(of: #"^[a-f0-9]{64}(?:\.blob|\.thumbnail\.jpg)$"#, options: .regularExpression) != nil
  }

  private func thumbnailData(for data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 240
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
