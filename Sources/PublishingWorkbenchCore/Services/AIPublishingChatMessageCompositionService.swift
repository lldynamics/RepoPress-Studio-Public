import Foundation

public enum AIPublishingChatMessageCompositionService {
  public static func displayContent(for message: AIPublishingChatMessage) -> String {
    displayContent(text: message.content, imageAttachments: message.imageAttachments)
  }

  public static func displayContent(
    text: String,
    imageAttachments: [AIChatImageAttachment]
  ) -> String {
    guard !imageAttachments.isEmpty else {
      return text
    }

    let names = imageAttachments.map(\.filename).joined(separator: ", ")
    let attachmentLine = CoreL10n.format("已附加图片：%@", names)
    let trimmedText = text.trimmedForPublishing
    return trimmedText.isEmpty ? attachmentLine : "\(trimmedText)\n\n\(attachmentLine)"
  }
}
