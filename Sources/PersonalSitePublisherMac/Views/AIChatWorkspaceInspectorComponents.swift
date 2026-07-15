import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorView: View {
  @ObservedObject private var ai: WorkbenchAIFeatureFacade

  init(store: WorkbenchStore) {
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  var body: some View {
    ScrollView {
      AIChatContextInspectorContent(state: state, actions: actions)
        .padding(16)
    }
    .background(.bar)
    .task(id: imageReportRefreshID) {
      guard let draft = ai.selectedChatDraft else { return }
      await ai.refreshChatImageWorkbenchReportInBackground(for: draft)
    }
  }

  private var state: AIChatContextInspectorState {
    guard let draft = ai.selectedChatDraft else {
      return AIChatContextInspectorState(draft: nil)
    }

    let profile = ai.chatProfile(for: draft)
    let issues = ai.chatPreflightIssues(for: draft)
    let imageReport = ai.cachedChatImageWorkbenchReport(for: draft)
    let package = ai.chatPublishingPackage(for: draft)
    let focusedParagraph = ai.focusedChatParagraph(for: draft)
    let relationSuggestions = ai.relatedChatArticleSuggestions(for: draft, limit: 5)
    let contextDetails = AIPublishingChatConversationPresentation.contextDetails(
      profile: profile,
      draft: draft,
      visibleDrafts: ai.chatVisibleDrafts,
      contextMode: ai.chatContextMode,
      selectedParagraph: focusedParagraph,
      relatedSuggestionCount: relationSuggestions.count
    )

    return AIChatContextInspectorState(
      draft: AIChatInspectorDraftContext(
        draft: draft,
        conversationTitle: AIPublishingChatConversationPresentation.displayTitle(
          conversationTitle: ai.chatConversationTitle,
          messages: ai.chatMessages,
          draft: draft
        ),
        contextSummary: AIPublishingChatConversationPresentation.contextSummary(
          profile: profile,
          draft: draft,
          contextMode: ai.chatContextMode
        ),
        contextSystemImage: ai.chatContextMode.systemImage,
        retrievalBasis: contextDetails.retrievalBasis,
        publicCandidateCount: contextDetails.publicCandidateCount,
        relatedSuggestionCount: contextDetails.relatedSuggestionCount,
        modelSummary: AIPublishingChatConversationPresentation.modelSummary(
          grade: ai.chatModelGrade,
          config: profile.aiProviderConfig,
          selectedModel: ai.chatSelectedModel
        ),
        markdownPath: profile.markdownPath(for: draft),
        publishFileCount: package.files.count,
        preflightIssueCount: issues.count,
        imageCount: imageReport?.items.count,
        selectedParagraphTitle: contextDetails.selectedParagraphTitle,
        selectedParagraphPreview: contextDetails.selectedParagraphPreview,
        chatMessage: ai.chatMessage,
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
        isChatRunning: ai.isChatRunning,
        latestReply: ai.chatDraftID == draft.id
          ? ai.chatMessages.last(where: { $0.role == .assistant })
          : nil
      )
    )
  }

  private var imageReportRefreshID: AIChatImageReportRefreshID? {
    guard let draft = ai.selectedChatDraft else { return nil }
    return AIChatImageReportRefreshID(draft: draft, profile: ai.chatProfile(for: draft))
  }

  private var actions: AIChatContextInspectorActions {
    AIChatContextInspectorActions(
      sendMessage: { message, draft in
        sendMessage(message, draft: draft)
      },
      selectDraft: { draftID in
        ai.selectChatDraft(draftID)
      },
      appendReply: { message, draft in
        append(message, to: draft)
      }
    )
  }

  private func sendMessage(_ message: String, draft: ArticleDraft) {
    Task {
      await ai.sendChatMessage(message, draft: draft)
    }
  }

  private func append(_ message: AIPublishingChatMessage, to draft: ArticleDraft) {
    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: draft,
      mode: .appendToBody
    ) else {
      ai.setChatMessage("AI 回复为空，未应用。")
      return
    }

    ai.updateChatDraft(result.draft)
    ai.saveChatDraftChanges()
    ai.setChatMessage(result.action.statusMessage)
  }
}

private struct AIChatImageReportRefreshID: Hashable {
  let draft: ArticleDraft
  let profile: SiteProfile
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
