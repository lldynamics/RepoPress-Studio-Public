import Foundation

public enum AIPublishingChatConversationPresentation {
  public static func title(
    fromUserText text: String,
    fallbackTitle: String,
    maxLength: Int = 34
  ) -> String {
    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty else {
      return fallbackTitle
    }
    return clipped(trimmed, maxLength: maxLength)
  }

  public static func displayTitle(
    conversationTitle: String? = nil,
    messages: [AIPublishingChatMessage],
    draft: ArticleDraft,
    emptyTitle: String = "AI 对话",
    maxLength: Int = 34
  ) -> String {
    if let conversationTitle = conversationTitle?.trimmedForPublishing.nilIfEmpty {
      return clipped(conversationTitle, maxLength: maxLength)
    }

    if let firstUserMessage = messages
      .first(where: { $0.role == .user })
      .map(AIPublishingChatMessageCompositionService.displayContent(for:))?
      .nilIfEmpty {
      return title(
        fromUserText: firstUserMessage,
        fallbackTitle: emptyTitle,
        maxLength: maxLength
      )
    }

    return draft.title.nilIfEmpty ?? emptyTitle
  }

  private static func clipped(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else {
      return text
    }
    return "\(text.prefix(maxLength))..."
  }
}

public enum AIPublishingChatImageAttachmentPresentation {
  public static let maxSelectedImageCount = 4
  public static let maxAttachmentBytes = 8 * 1_024 * 1_024
  public static let supportedMIMETypes: Set<String> = [
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/webp",
  ]

  public static func isWithinAttachmentSizeLimit(_ byteSize: Int64) -> Bool {
    byteSize <= Int64(maxAttachmentBytes)
  }

  public static func isSupportedAttachment(mimeType: String, byteSize: Int64) -> Bool {
    supportedMIMETypes.contains(mimeType.lowercased())
      && byteSize > 0
      && isWithinAttachmentSizeLimit(byteSize)
  }

  public static func attachmentSizeLimitText(
    maxAttachmentBytes: Int = Self.maxAttachmentBytes
  ) -> String {
    String(format: "%.1f MB", Double(maxAttachmentBytes) / 1_000_000)
  }
}
