import Foundation

/// The single image budget used by composer preflight and conversation
/// retention. Requests are rejected before persistence when this limit would
/// be exceeded, so retention never silently removes the submitted images.
extension AIChatImageAttachmentBudget {
  public static func byteCount(_ messages: [AIPublishingChatMessage]) -> Int64 {
    messages.reduce(Int64(0)) { total, message in
      total + byteCount(message.imageAttachments)
    }
  }

  public static func canAppend(
    _ attachments: [AIChatImageAttachment],
    to messages: [AIPublishingChatMessage]
  ) -> Bool {
    byteCount(messages) + byteCount(attachments) <= maximumConversationBytes
  }
}
