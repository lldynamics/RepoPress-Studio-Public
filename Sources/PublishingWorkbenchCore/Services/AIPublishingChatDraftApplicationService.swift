import Foundation

public enum AIPublishingChatDraftApplicationMode: String, CaseIterable, Identifiable, Sendable {
  case replaceSelection
  case replaceBody
  case appendToBody

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .replaceSelection:
      return "替换选中文本"
    case .replaceBody:
      return "替换整篇正文"
    case .appendToBody:
      return "追加到文章末尾"
    }
  }

  public var systemImage: String {
    switch self {
    case .replaceSelection:
      return "text.badge.checkmark"
    case .replaceBody:
      return "doc.text.fill"
    case .appendToBody:
      return "text.append"
    }
  }
}

public enum AIPublishingChatDraftApplicationAction: Equatable, Sendable {
  case replacedSelection
  case replacedBody
  case appendedToBody

  public var statusMessage: String {
    switch self {
    case .replacedSelection:
      return "已用 AI 回复替换选中文本。"
    case .replacedBody:
      return "已用 AI 回复替换整篇正文。"
    case .appendedToBody:
      return "已追加 AI 回复到文章末尾。"
    }
  }
}

public struct AIPublishingChatDraftApplicationResult: Sendable {
  public var draft: ArticleDraft
  public var action: AIPublishingChatDraftApplicationAction
  public var appliedTextCharacterCount: Int

  public init(
    draft: ArticleDraft,
    action: AIPublishingChatDraftApplicationAction,
    appliedTextCharacterCount: Int
  ) {
    self.draft = draft
    self.action = action
    self.appliedTextCharacterCount = appliedTextCharacterCount
  }
}

public enum AIPublishingChatDraftApplicationService {
  public static func applyAssistantContent(
    _ content: String,
    to draft: ArticleDraft,
    mode: AIPublishingChatDraftApplicationMode = .appendToBody,
    selectionRange: NSRange? = nil
  ) -> AIPublishingChatDraftApplicationResult? {
    let replacement = content.trimmedForPublishing
    guard !replacement.isEmpty else {
      return nil
    }

    var updatedDraft = draft
    let action: AIPublishingChatDraftApplicationAction
    switch mode {
    case .replaceSelection:
      guard
        let selectionRange,
        selectionRange.length > 0,
        let range = Range(selectionRange, in: updatedDraft.bodyMarkdown)
      else {
        return nil
      }
      updatedDraft.bodyMarkdown.replaceSubrange(range, with: replacement)
      action = .replacedSelection
    case .replaceBody:
      updatedDraft.bodyMarkdown = replacement
      action = .replacedBody
    case .appendToBody:
      updatedDraft.bodyMarkdown = appending(replacement, to: updatedDraft.bodyMarkdown)
      action = .appendedToBody
    }
    // Chat application changes the document body only. Keep the editor's
    // metadata lock and the sidebar's ordering timestamp stable.
    updatedDraft.markBodyUpdated()

    return AIPublishingChatDraftApplicationResult(
      draft: updatedDraft,
      action: action,
      appliedTextCharacterCount: replacement.count
    )
  }

  private static func appending(_ text: String, to markdown: String) -> String {
    let trimmedText = text.trimmedForPublishing
    let trimmedMarkdown = markdown.trimmedForPublishing
    guard !trimmedMarkdown.isEmpty else {
      return trimmedText
    }
    return trimmedMarkdown + "\n\n" + trimmedText
  }
}
