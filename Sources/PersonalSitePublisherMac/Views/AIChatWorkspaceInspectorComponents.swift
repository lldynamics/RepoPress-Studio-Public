import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorView: View {
  @ObservedObject private var ai: WorkbenchAIFeatureFacade
  @State private var inputText = ""
  @State private var isSubmitting = false
  @State private var sendTask: Task<Void, Never>?

  init(store: WorkbenchStore) {
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  var body: some View {
    VStack(spacing: 0) {
      inspectorHeader

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          AIChatContextInspectorContent(state: state, actions: actions)
            .padding(16)
        }
        .onAppear {
          scrollToLatestMessage(using: proxy, animated: false)
        }
        .onChange(of: latestMessageID) { _, _ in
          scrollToLatestMessage(using: proxy)
        }
        .onChange(of: latestMessageContent) { _, _ in
          scrollToLatestMessage(using: proxy)
        }
      }

      Divider()

      messageComposer
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 助手")
    .accessibilityIdentifier("ai-assistant-inspector")
    .task(id: imageReportRefreshID) {
      guard let draft = ai.selectedChatDraft else { return }
      await ai.refreshChatImageWorkbenchReportInBackground(for: draft)
    }
    .onAppear(perform: applyPendingQuickPrompt)
    .onChange(of: ai.pendingQuickPrompt?.id) { _, _ in
      applyPendingQuickPrompt()
    }
    .onDisappear(perform: stopSending)
  }

  private var inspectorHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .foregroundStyle(WorkbenchTheme.primary)

      VStack(alignment: .leading, spacing: 2) {
        Text("AI 助手")
          .font(.headline)
        if let modelSummary = state.draft?.modelSummary {
          Text(modelSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      assistantOptionsMenu

      Button {
        ai.hideAssistant()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("关闭 AI 助手")
      .accessibilityLabel("关闭 AI 助手")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var assistantOptionsMenu: some View {
    Menu {
      Picker("模型档位", selection: modelGradeBinding) {
        ForEach(AIChatModelGrade.allCases) { grade in
          Text(grade.title).tag(grade)
        }
      }

      Picker("上下文", selection: contextModeBinding) {
        ForEach(AIPublishingChatContextMode.allCases) { mode in
          Text(mode.localizedDisplayNameKey).tag(mode)
        }
      }

      Divider()

      Button {
        ai.startNewChatConversation(draft: ai.selectedChatDraft)
      } label: {
        Label("新对话", systemImage: "square.and.pencil")
      }
      .disabled(isSending)

      if !ai.archivedConversations.isEmpty {
        Menu("历史对话") {
          ForEach(ai.archivedConversations.prefix(8)) { conversation in
            Button(conversation.title) {
              ai.restoreArchivedChatConversation(
                conversation.id,
                draft: ai.selectedChatDraft
              )
            }
          }
        }
        .disabled(isSending)
      }
    } label: {
      Image(systemName: "slider.horizontal.3")
    }
    .menuIndicator(.hidden)
    .help("模型、上下文与对话历史")
    .accessibilityLabel("AI 助手选项")
  }

  private var messageComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let status = ai.chatMessage?.nilIfEmpty {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .accessibilityLabel("AI 状态")
      }

      HStack(alignment: .bottom, spacing: 8) {
        TextField("询问当前文章…", text: $inputText, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...6)
          .disabled(ai.selectedChatDraft == nil || isSending)
          .accessibilityLabel("AI 消息")

        Button(action: handleSendButton) {
          Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
            .foregroundStyle(isSending ? WorkbenchTheme.risk : WorkbenchTheme.primary)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!isSending && (trimmedInput.isEmpty || ai.selectedChatDraft == nil))
        .help(isSending ? "停止生成" : "发送（⌘Return）")
        .accessibilityLabel(isSending ? "停止 AI 回复" : "发送 AI 消息")
      }
    }
    .padding(12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-assistant-composer")
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
        messages: ai.chatDraftID == draft.id ? Array(ai.chatMessages.suffix(8)) : [],
        totalMessageCount: ai.chatDraftID == draft.id ? ai.chatMessages.count : 0,
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
    startSending(message, draft: draft, clearsComposerOnAccept: false)
  }

  private var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submitMessage() {
    guard let draft = ai.selectedChatDraft else { return }
    let message = trimmedInput
    guard !message.isEmpty, !isSending else { return }
    startSending(message, draft: draft, clearsComposerOnAccept: true)
  }

  private var isSending: Bool {
    isSubmitting || ai.isChatRunning
  }

  private var modelGradeBinding: Binding<AIChatModelGrade> {
    Binding(
      get: { ai.chatModelGrade },
      set: { ai.setChatModelGrade($0) }
    )
  }

  private var contextModeBinding: Binding<AIPublishingChatContextMode> {
    Binding(
      get: { ai.chatContextMode },
      set: { ai.setChatContextMode($0) }
    )
  }

  private var latestMessageID: AIPublishingChatMessage.ID? {
    state.draft?.messages.last?.id
  }

  private var latestMessageContent: String {
    state.draft?.messages.last?.content ?? ""
  }

  private func handleSendButton() {
    if isSending {
      stopSending()
    } else {
      submitMessage()
    }
  }

  private func startSending(
    _ message: String,
    draft: ArticleDraft,
    clearsComposerOnAccept: Bool
  ) {
    guard !isSending else { return }
    let existingMessageIDs = Set(ai.chatMessages.map(\.id))
    isSubmitting = true
    sendTask = Task {
      let reply = await ai.sendChatMessage(message, draft: draft)
      let didAcceptUserMessage = ai.chatMessages.contains {
        !existingMessageIDs.contains($0.id) && $0.role == .user
      }
      if clearsComposerOnAccept,
         (reply != nil || didAcceptUserMessage),
         trimmedInput == message {
        inputText = ""
      }
      isSubmitting = false
      sendTask = nil
    }
  }

  private func stopSending() {
    sendTask?.cancel()
    sendTask = nil
    if ai.isChatRunning {
      ai.cancelChatReply()
    }
    isSubmitting = false
  }

  private func applyPendingQuickPrompt() {
    guard let prompt = ai.consumePendingQuickPrompt() else { return }
    if trimmedInput.isEmpty {
      inputText = prompt.prompt
    } else if trimmedInput != prompt.prompt {
      inputText += "\n\n\(prompt.prompt)"
    }
  }

  private func scrollToLatestMessage(
    using proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard let latestMessageID else { return }
    DispatchQueue.main.async {
      if animated {
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(latestMessageID, anchor: .bottom)
      }
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
  @State private var isContextExpanded = false
  @State private var isToolsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let draftContext = state.draft {
        AIChatConversationInspectorSection(context: draftContext, actions: actions)
        AIChatRelatedSuggestionsInspectorSection(context: draftContext, actions: actions)

        DisclosureGroup("文章上下文", isExpanded: $isContextExpanded) {
          AIChatContextOverviewInspectorSection(context: draftContext)
            .padding(.top, 10)
        }

        DisclosureGroup("更多 AI 工具", isExpanded: $isToolsExpanded) {
          VStack(alignment: .leading, spacing: 16) {
            AIChatWorkflowGuidesInspectorSection(context: draftContext, actions: actions)
            AIChatQuickPromptsInspectorSection(context: draftContext, actions: actions)
          }
          .padding(.top, 10)
        }
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
