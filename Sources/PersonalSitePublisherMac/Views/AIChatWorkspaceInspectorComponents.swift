import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorView: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    ScrollView {
      AIChatContextInspectorContent(state: state, actions: actions)
        .padding(16)
    }
    .background(.bar)
  }

  private var state: AIChatContextInspectorState {
    guard let draft = store.ai.selectedChatDraft else {
      return AIChatContextInspectorState(draft: nil)
    }

    let profile = store.ai.chatProfile(for: draft)
    let issues = store.ai.chatPreflightIssues(for: draft)
    let imageReport = store.ai.chatImageWorkbenchReport(for: draft)
    let package = store.ai.chatPublishingPackage(for: draft)
    let focusedParagraph = store.ai.focusedChatParagraph(for: draft)
    let relationSuggestions = store.ai.relatedChatArticleSuggestions(for: draft, limit: 5)
    let contextDetails = AIPublishingChatConversationPresentation.contextDetails(
      profile: profile,
      draft: draft,
      visibleDrafts: store.ai.chatVisibleDrafts,
      contextMode: store.ai.chatContextMode,
      selectedParagraph: focusedParagraph,
      relatedSuggestionCount: relationSuggestions.count
    )

    return AIChatContextInspectorState(
      draft: AIChatInspectorDraftContext(
        draft: draft,
        conversationTitle: AIPublishingChatConversationPresentation.displayTitle(
          conversationTitle: store.ai.chatConversationTitle,
          messages: store.ai.chatMessages,
          draft: draft
        ),
        contextSummary: AIPublishingChatConversationPresentation.contextSummary(
          profile: profile,
          draft: draft,
          contextMode: store.ai.chatContextMode
        ),
        contextSystemImage: store.ai.chatContextMode.systemImage,
        retrievalBasis: contextDetails.retrievalBasis,
        publicCandidateCount: contextDetails.publicCandidateCount,
        relatedSuggestionCount: contextDetails.relatedSuggestionCount,
        modelSummary: AIPublishingChatConversationPresentation.modelSummary(
          grade: store.ai.chatModelGrade,
          config: profile.aiProviderConfig,
          selectedModel: store.ai.chatSelectedModel
        ),
        markdownPath: profile.markdownPath(for: draft),
        publishFileCount: package.files.count,
        preflightIssueCount: issues.count,
        imageCount: imageReport.items.count,
        selectedParagraphTitle: contextDetails.selectedParagraphTitle,
        selectedParagraphPreview: contextDetails.selectedParagraphPreview,
        chatMessage: store.ai.chatMessage,
        relatedSuggestions: relationSuggestions.prefix(4).map { suggestion in
          AIChatRelatedSuggestionPresentation(
            id: suggestion.id,
            targetTitle: suggestion.targetTitle,
            reason: suggestion.reason,
            targetPath: suggestion.targetPath,
            targetDraftID: suggestion.targetDraftID,
            prompt: AIPublishingChatPromptTemplateService.relatedArticleSuggestionPrompt(
              for: suggestion,
              draft: draft,
              profile: profile
            )
          )
        },
        isChatRunning: store.ai.isChatRunning,
        latestReply: store.ai.chatDraftID == draft.id
          ? store.ai.chatMessages.last(where: { $0.role == .assistant })
          : nil
      )
    )
  }

  private var actions: AIChatContextInspectorActions {
    AIChatContextInspectorActions(
      sendMessage: { message, draft in
        sendMessage(message, draft: draft)
      },
      selectDraft: { draftID in
        store.ai.selectChatDraft(draftID)
      },
      appendReply: { message, draft in
        append(message, to: draft)
      }
    )
  }

  private func sendMessage(_ message: String, draft: ArticleDraft) {
    Task {
      await store.ai.sendChatMessage(message, draft: draft)
    }
  }

  private func append(_ message: AIPublishingChatMessage, to draft: ArticleDraft) {
    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: draft,
      mode: .appendToBody
    ) else {
      store.ai.setChatMessage("AI 回复为空，未应用。")
      return
    }

    store.ai.updateChatDraft(result.draft)
    store.ai.saveChatDraftChanges()
    store.ai.setChatMessage(result.action.statusMessage)
  }
}

struct AIChatContextInspectorContent: View {
  let state: AIChatContextInspectorState
  let actions: AIChatContextInspectorActions

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let draftContext = state.draft {
        AIChatContextOverviewInspectorSection(context: draftContext)
        AIChatRelatedSuggestionsInspectorSection(context: draftContext, actions: actions)
        AIChatWorkflowGuidesInspectorSection(context: draftContext, actions: actions)
        AIChatQuickPromptsInspectorSection(context: draftContext, actions: actions)
        AIChatLatestReplyInspectorSection(context: draftContext, actions: actions)
      } else {
        EmptyStateView(
          title: "没有上下文",
          message: "选择文章后，这里显示 AI 对话上下文。",
          systemImage: "sparkles"
        )
        .frame(height: 260)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AIChatInspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AIChatInspectorStatRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption)
  }
}
