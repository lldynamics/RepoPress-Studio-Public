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
    let attachmentLine = "已附加图片：\(names)"
    let trimmedText = text.trimmedForPublishing
    return trimmedText.isEmpty ? attachmentLine : "\(trimmedText)\n\n\(attachmentLine)"
  }
}

public enum AIPublishingChatTranscriptService {
  public static func markdownTranscript(
    messages: [AIPublishingChatMessage],
    draft: ArticleDraft,
    contextMode: AIPublishingChatContextMode,
    conversationTitle: String? = nil,
    contextSummary: String? = nil,
    modelSummary: String? = nil,
    exportedAt: Date = Date()
  ) -> String {
    let trimmedMessages = messages.filter {
      !$0.content.trimmedForPublishing.isEmpty || !$0.imageAttachments.isEmpty
    }
    guard !trimmedMessages.isEmpty else {
      return ""
    }

    let resolvedConversationTitle = conversationTitle?.nilIfEmpty
      ?? AIPublishingChatConversationPresentation.displayTitle(
        messages: trimmedMessages,
        draft: draft
      )
    let resolvedContextSummary = contextSummary?.nilIfEmpty ?? contextMode.displayName
    let resolvedModelSummary = modelSummary?.nilIfEmpty

    var metadataLines = [
      "- 对话：\(resolvedConversationTitle)",
      "- 文章：\(draft.title.nilIfEmpty ?? "未命名文章")",
      "- Slug：\(draft.slug.nilIfEmpty ?? "未设置")",
      "- 上下文模式：\(contextMode.displayName)",
      "- 上下文摘要：\(resolvedContextSummary)",
    ]
    if let resolvedModelSummary {
      metadataLines.append("- 模型：\(resolvedModelSummary)")
    }
    metadataLines.append("- 导出时间：\(timestamp(exportedAt))")
    metadataLines.append("- 消息数：\(trimmedMessages.count)")

    var sections: [String] = [
      """
      # AI 对话记录

      \(metadataLines.joined(separator: "\n"))
      """,
    ]

    sections.append(contentsOf: trimmedMessages.map(messageSection))
    return sections.joined(separator: "\n\n")
  }

  private static func messageSection(_ message: AIPublishingChatMessage) -> String {
    var lines: [String] = [
      "## \(message.role.displayName) · \(timestamp(message.createdAt))",
    ]

    if message.role == .assistant {
      var metadata: [String] = []
      if let model = message.model?.nilIfEmpty {
        metadata.append("模型：\(model)")
      }
      if let tokenText = message.tokenUsage?.displayText.nilIfEmpty {
        metadata.append("Token：\(tokenText)")
      }
      if !metadata.isEmpty {
        lines.append(metadata.joined(separator: " · "))
      }
    }

    let content = message.content.trimmedForPublishing
    if !content.isEmpty {
      lines.append(content)
    }

    if !message.imageAttachments.isEmpty {
      lines.append("图片附件：")
      lines.append(
        contentsOf: message.imageAttachments.map {
          "- \($0.filename)（\($0.mimeType)，\($0.data.count) bytes）"
        }
      )
    }

    return lines.joined(separator: "\n\n")
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}
