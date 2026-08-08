import Foundation

/// The single image budget used by composer preflight and conversation
/// retention. Requests are rejected before persistence when this limit would
/// be exceeded, so retention never silently removes the submitted images.
public enum AIChatImageAttachmentBudget {
  public static let maximumConversationBytes = AIConversation.maximumImageBytes

  public static func byteCount(_ attachment: AIChatImageAttachment) -> Int64 {
    max(attachment.byteCount, Int64(attachment.data.count))
  }

  public static func byteCount(_ attachments: [AIChatImageAttachment]) -> Int64 {
    attachments.reduce(Int64(0)) { $0 + byteCount($1) }
  }

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
