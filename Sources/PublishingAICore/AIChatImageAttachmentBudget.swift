import Foundation

/// The shared byte budget for AI chat image attachments.
///
/// Raw attachment accounting belongs to `PublishingAICore`; Workbench adds
/// message-model overloads without redefining the limit.
public enum AIChatImageAttachmentBudget {
  public static let maximumConversationBytes: Int64 = 8_000_000

  public static func byteCount(_ attachment: AIChatImageAttachment) -> Int64 {
    max(attachment.byteCount, Int64(attachment.data.count))
  }

  public static func byteCount(_ attachments: [AIChatImageAttachment]) -> Int64 {
    attachments.reduce(Int64(0)) { $0 + byteCount($1) }
  }
}
