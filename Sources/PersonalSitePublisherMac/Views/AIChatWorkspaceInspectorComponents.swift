import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorView: View {
  @Environment(\.openSettings) private var openSettings
  @AppStorage("settingsRequestedTabID") private var requestedSettingsTabID = ""
  @ObservedObject private var ai: WorkbenchAIFeatureFacade
  @State private var inputText = ""
  @State private var isSubmitting = false
  @State private var sendTask: Task<Void, Never>?
  @State private var draftDiffPreview: AIChatDraftDiffPreview?
  @State private var visibleMessageLimit = 8
  @State private var isFollowingLatestMessage = true
  @State private var messageAnchorToPreserve: AIPublishingChatMessage.ID?
  @State private var isPartialRetryConfirmationPresented = false
  @FocusState private var isComposerFocused: Bool

  init(store: WorkbenchStore) {
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  var body: some View {
    VStack(spacing: 0) {
      inspectorHeader

      Divider()

      if isAIKeyMissing {
        missingAIKeyBanner
        Divider()
      }

      GeometryReader { viewport in
        ScrollViewReader { proxy in
          ScrollView {
            AIChatContextInspectorContent(state: state, actions: actions)
              .padding(16)

            Color.clear
              .frame(height: 1)
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: AIChatScrollBottomPreferenceKey.self,
                    value: geometry.frame(in: .named("ai-chat-scroll")).maxY
                  )
                }
              }
          }
          .coordinateSpace(name: "ai-chat-scroll")
          .onPreferenceChange(AIChatScrollBottomPreferenceKey.self) { bottomPosition in
            guard bottomPosition > 0 else { return }
            isFollowingLatestMessage = bottomPosition <= viewport.size.height + 56
          }
          .overlay(alignment: .bottomTrailing) {
            if !isFollowingLatestMessage, latestMessageID != nil {
              Button {
                isFollowingLatestMessage = true
                scrollToLatestMessage(using: proxy)
              } label: {
                Label("跳到最新", systemImage: "arrow.down.circle.fill")
              }
              .controlSize(.small)
              .padding(10)
            }
          }
          .onAppear {
            scrollToLatestMessage(using: proxy, animated: false)
          }
          .onChange(of: latestMessageID) { _, _ in
            guard isFollowingLatestMessage else { return }
            scrollToLatestMessage(using: proxy)
          }
          .onChange(of: latestMessageContent) { _, _ in
            guard isFollowingLatestMessage else { return }
            scrollToLatestMessage(using: proxy)
          }
          .onChange(of: visibleMessageLimit) { _, _ in
            guard let anchor = messageAnchorToPreserve else { return }
            DispatchQueue.main.async {
              proxy.scrollTo(anchor, anchor: .top)
              messageAnchorToPreserve = nil
            }
          }
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
    .onAppear {
      applyPendingQuickPrompt()
      focusComposerIfAvailable()
    }
    .onChange(of: ai.pendingQuickPrompt?.id) { _, _ in
      applyPendingQuickPrompt()
    }
    .onChange(of: isAIKeyMissing) { _, isMissing in
      if !isMissing {
        focusComposerIfAvailable()
      }
    }
    .onChange(of: ai.chatDraftID) { _, _ in
      visibleMessageLimit = 8
      isFollowingLatestMessage = true
    }
    .onChange(of: ai.chatMessages.count) { _, count in
      if count == 0 {
        visibleMessageLimit = 8
        isFollowingLatestMessage = true
      }
    }
    .sheet(item: $draftDiffPreview) { preview in
      AIChatDraftDiffPreviewSheet(preview: preview) {
        applyDraftDiffPreview(preview)
      }
    }
    .confirmationDialog(
      String(localized: "重新生成可能重复计费"),
      isPresented: $isPartialRetryConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(String(localized: "仍要重新生成"), role: .destructive) {
        retryLastFailedReply(confirmingPossibleDuplicateCharge: true)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("AI 已返回部分内容，软件没有自动重放请求。继续会移除这段未完成回复并重新生成，可能产生重复内容和费用。")
    }
  }

  private var missingAIKeyBanner: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "key.horizontal")
        .foregroundStyle(WorkbenchTheme.warning)

      VStack(alignment: .leading, spacing: 2) {
        Text("需要配置 AI API Key")
          .font(.callout.weight(.medium))
        Text("密钥仅保存在系统钥匙串中。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Button("打开 AI 设置") {
        requestedSettingsTabID = SettingsTab.ai.id
        openSettings()
      }
      .controlSize(.regular)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("需要配置 AI API Key")
  }

  private var isAIKeyMissing: Bool {
    guard let draft = ai.selectedChatDraft else { return false }
    return ai.chatProfile(for: draft).aiProviderConfig.requiresAPIKey
      && !ai.tokenAvailability.hasToken
  }

  private var inspectorHeader: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(WorkbenchTheme.primary)

        Text("AI 助手")
          .font(.headline)

        Spacer(minLength: 8)

        assistantOptionsMenu

        Button {
          ai.closeAssistantPanel()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("关闭 AI 助手")
        .accessibilityLabel("关闭 AI 助手")
      }

      HStack(spacing: 7) {
        modelSelectionMenu
        reasoningLevelMenu
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var modelSelectionMenu: some View {
    Menu {
      Picker("模型档位", selection: modelGradeBinding) {
        ForEach(AIChatModelGrade.allCases) { grade in
          Text(grade.title).tag(grade)
        }
      }

      if let modelSelection {
        Divider()

        ForEach(modelSelection.modelCandidates, id: \.self) { model in
          Button {
            selectModel(model)
          } label: {
            Label(
              model,
              systemImage: model == modelSelection.activeModel ? "checkmark" : "cpu"
            )
          }
        }

        Divider()

        Button {
          ai.resetChatModelToProfileDefault()
        } label: {
          Label("恢复站点默认模型", systemImage: "arrow.counterclockwise")
        }
      }
    } label: {
      Label(modelMenuTitle, systemImage: "cpu")
        .workbenchTruncatedIdentity(modelMenuTitle)
    }
    .controlSize(.small)
    .help(state.draft?.modelSummary ?? "更换 AI 模型")
    .accessibilityLabel("AI 模型")
    .accessibilityValue(state.draft?.modelSummary ?? "未选择")
  }

  private var reasoningLevelMenu: some View {
    Menu {
      Picker("思考级别", selection: reasoningLevelBinding) {
        ForEach(AIChatReasoningLevel.allCases) { level in
          Text(localizedReasoningLevelTitle(level)).tag(level)
        }
      }
    } label: {
      Label(
        "思考 \(localizedReasoningLevelTitle(ai.chatReasoningLevel))",
        systemImage: "brain.head.profile"
      )
    }
    .controlSize(.small)
    .disabled(ai.selectedChatDraft == nil || !supportsSelectableReasoningLevel)
    .help(
      supportsSelectableReasoningLevel
        ? "切换当前对话的思考级别"
        : "当前 AI 服务暂不支持单独切换思考级别"
    )
    .accessibilityLabel("AI 思考级别")
    .accessibilityValue(localizedReasoningLevelTitle(ai.chatReasoningLevel))
  }

  private var assistantOptionsMenu: some View {
    Menu {
      Picker("上下文", selection: contextModeBinding) {
        ForEach(AIPublishingChatContextMode.allCases) { mode in
          Text(mode.localizedDisplayNameKey).tag(mode)
        }
      }

      Picker("资料库", selection: knowledgePolicyBinding) {
        ForEach(KnowledgeRetrievalPolicy.allCases) { policy in
          Text(localizedKnowledgePolicyTitle(policy)).tag(policy)
        }
      }

      Divider()

      Button {
        ai.startNewChatConversation(draft: ai.selectedChatDraft)
      } label: {
        Label("新对话", systemImage: "square.and.pencil")
      }
      .disabled(isSending)

      Divider()

      Menu("自定义指令") {
        if ai.chatCustomPrompts.isEmpty {
          Text("尚未保存自定义指令")
        } else {
          ForEach(ai.chatCustomPrompts) { prompt in
            Menu(prompt.title) {
              Button {
                inputText = prompt.prompt
                focusComposerIfAvailable()
              } label: {
                Label("使用", systemImage: "text.cursor")
              }

              Button(role: .destructive) {
                ai.deleteChatCustomPrompt(prompt.id)
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        }

        Divider()

        Button {
          saveCurrentInputAsCustomPrompt()
        } label: {
          Label("保存当前输入", systemImage: "plus")
        }
        .disabled(trimmedInput.isEmpty)
      }
    } label: {
      Image(systemName: "slider.horizontal.3")
    }
    .menuIndicator(.hidden)
    .help("上下文、资料库与自定义提示")
    .accessibilityLabel("AI 助手选项")
  }

  private var messageComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let status = ai.chatMessage?.nilIfEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(status)
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .accessibilityLabel("AI 状态")

          Spacer(minLength: 0)

          if let retryState = activeManualRetryState {
            if retryState.requiresDuplicateChargeConfirmation {
              Button(String(localized: "重新生成")) {
                isPartialRetryConfirmationPresented = true
              }
              .controlSize(.regular)
              .disabled(isSending)
              .help(String(localized: "部分回复已保留；确认后才会重新发起请求"))
            } else {
              Button(String(localized: "手动重试")) {
                retryLastFailedReply(confirmingPossibleDuplicateCharge: false)
              }
              .controlSize(.regular)
              .disabled(isSending)
              .help(String(localized: "由你确认后重新发起上一次请求"))
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        TextField("询问当前文章…", text: $inputText, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.body)
          .lineLimit(3...8)
          .disabled(isComposerInputUnavailable)
          .focused($isComposerFocused)
          .accessibilityLabel("AI 消息")
          .accessibilityHint("按 Command 和 Return 发送；按 Return 换行")
          .accessibilityIdentifier("ai-assistant-input")

        HStack(spacing: 8) {
          Text("↩ 换行 · ⌘↩ 发送")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)

          Spacer(minLength: 8)

          Button(action: handleSendButton) {
            Label(
              isSending ? "停止" : "发送",
              systemImage: isSending ? "stop.fill" : "arrow.up"
            )
            .frame(minWidth: 58)
          }
          .controlSize(.regular)
          .workbenchProminentActionStyle(
            tint: isSending ? WorkbenchTheme.risk : WorkbenchTheme.primaryActionFill
          )
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(!isSending && !canSubmitMessage)
          .help(isSending ? "停止生成" : "发送（⌘Return）")
          .accessibilityLabel(isSending ? "停止 AI 回复" : "发送 AI 消息")
          .accessibilityIdentifier("ai-assistant-send-button")
        }
      }
      .padding(10)
      .background(
        Color(nsColor: .textBackgroundColor).opacity(0.72),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(
            isComposerFocused
              ? WorkbenchTheme.primary
              : Color(nsColor: .separatorColor).opacity(0.65),
            lineWidth: isComposerFocused ? 1.5 : 1
          )
          .allowsHitTesting(false)
      }
      .animation(.easeOut(duration: 0.12), value: isComposerFocused)
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
        messages: ai.chatDraftID == draft.id ? Array(ai.chatMessages.suffix(visibleMessageLimit)) : [],
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
        isAutomationRunning: ai.isAutomationRunning,
        automationRunRecords: ai.automationRunRecords,
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
      },
      loadEarlierMessages: {
        loadEarlierMessages()
      },
      openCitation: { citation in
        _ = ai.openKnowledgeCitation(citation)
      },
      executeAutomationPlan: { messageID in
        Task {
          _ = await ai.executeAutomationPlan(messageID: messageID)
        }
      },
      executeAutomationStep: { messageID, stepID in
        Task {
          _ = await ai.executeAutomationPlan(
            messageID: messageID,
            onlyStepID: stepID,
            confirmedStepIDs: Set([stepID])
          )
        }
      },
      previewAutomationStep: { messageID, stepID in
        ai.automationDraftPreview(messageID: messageID, stepID: stepID)
      },
      cancelAutomationPlan: { messageID in
        ai.cancelAutomationPlan(messageID: messageID)
      },
      rollbackAutomationRun: { recordID in
        _ = ai.rollbackAutomationRun(recordID)
      }
    )
  }

  private func sendMessage(_ message: String, draft: ArticleDraft) {
    startSending(message, draft: draft, clearsComposerOnAccept: false)
  }

  private var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isComposerInputUnavailable: Bool {
    ai.selectedChatDraft == nil || isSending
  }

  private var canSubmitMessage: Bool {
    !trimmedInput.isEmpty && !isComposerInputUnavailable && !isAIKeyMissing
  }

  private func submitMessage() {
    guard let draft = ai.selectedChatDraft else { return }
    let message = trimmedInput
    guard !message.isEmpty, !isSending else { return }
    startSending(message, draft: draft, clearsComposerOnAccept: true)
  }

  private func saveCurrentInputAsCustomPrompt() {
    let prompt = trimmedInput
    guard !prompt.isEmpty else { return }
    let title = prompt
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .prefix(28) ?? Substring("自定义指令")
    _ = ai.saveChatCustomPrompt(title: String(title), prompt: prompt)
  }

  private var isSending: Bool {
    isSubmitting || ai.isChatRunning
  }

  private var activeManualRetryState: AIChatManualRetryState? {
    guard let draftID = ai.selectedChatDraft?.id,
          let retryState = ai.chatManualRetryState,
          retryState.draftID == draftID else {
      return nil
    }
    return retryState
  }

  private var modelGradeBinding: Binding<AIChatModelGrade> {
    Binding(
      get: { ai.chatModelGrade },
      set: { ai.setChatModelGrade($0) }
    )
  }

  private var reasoningLevelBinding: Binding<AIChatReasoningLevel> {
    Binding(
      get: { ai.chatReasoningLevel },
      set: { ai.setChatReasoningLevel($0) }
    )
  }

  private var modelSelection: AIChatModelSelectionPresentation? {
    guard let draft = ai.selectedChatDraft else { return nil }
    return AIChatModelSelectionPresentationService.presentation(
      grade: ai.chatModelGrade,
      selectedModel: ai.chatSelectedModel,
      config: ai.chatProfile(for: draft).aiProviderConfig
    )
  }

  private var modelMenuTitle: String {
    guard let activeModel = modelSelection?.activeModel.nilIfEmpty else {
      return "选择模型"
    }
    let maximumLength = 22
    guard activeModel.count > maximumLength else { return activeModel }
    return "\(activeModel.prefix(maximumLength))…"
  }

  private var supportsSelectableReasoningLevel: Bool {
    guard let draft = ai.selectedChatDraft else { return false }
    return ai.chatProfile(for: draft).aiProviderConfig.usesDeepSeekAPI
  }

  private func localizedReasoningLevelTitle(_ level: AIChatReasoningLevel) -> String {
    switch level {
    case .quick:
      return String(localized: "快速")
    case .standard:
      return String(localized: "标准")
    case .deep:
      return String(localized: "深度")
    }
  }

  private func localizedKnowledgePolicyTitle(_ policy: KnowledgeRetrievalPolicy) -> String {
    switch policy {
    case .off:
      return String(localized: "关闭资料库")
    case .automatic:
      return String(localized: "自动检索")
    case .pinnedOnly:
      return String(localized: "仅固定资料")
    }
  }

  private func selectModel(_ model: String) {
    guard let draft = ai.selectedChatDraft else { return }
    let config = ai.chatProfile(for: draft).aiProviderConfig
    for grade in [AIChatModelGrade.standard, .highQuality, .fast] {
      let gradeModel = AIChatModelCatalog.model(
        for: grade,
        config: config,
        currentModel: ai.chatSelectedModel
      )
      if gradeModel == model {
        ai.setChatModelGrade(grade)
        return
      }
    }
    ai.setChatCustomModel(model)
  }

  private var contextModeBinding: Binding<AIPublishingChatContextMode> {
    Binding(
      get: { ai.chatContextMode },
      set: { ai.setChatContextMode($0) }
    )
  }

  private var knowledgePolicyBinding: Binding<KnowledgeRetrievalPolicy> {
    Binding(
      get: { ai.chatKnowledgePolicy },
      set: { ai.setChatKnowledgePolicy($0) }
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
    isFollowingLatestMessage = true
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

  private func retryLastFailedReply(confirmingPossibleDuplicateCharge: Bool) {
    guard let draft = ai.selectedChatDraft, !isSending else { return }
    isFollowingLatestMessage = true
    isSubmitting = true
    sendTask = Task {
      _ = await ai.retryLastFailedChatReply(
        confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
        draft: draft
      )
      isSubmitting = false
      sendTask = nil
    }
  }

  private func loadEarlierMessages() {
    guard let context = state.draft,
          context.totalMessageCount > context.messages.count else { return }
    messageAnchorToPreserve = context.messages.first?.id
    visibleMessageLimit = min(context.totalMessageCount, visibleMessageLimit + 8)
  }

  private func applyPendingQuickPrompt() {
    guard let prompt = ai.consumePendingQuickPrompt() else { return }
    if trimmedInput.isEmpty {
      inputText = prompt.prompt
    } else if trimmedInput != prompt.prompt {
      inputText += "\n\n\(prompt.prompt)"
    }
    focusComposerIfAvailable()
  }

  private func focusComposerIfAvailable() {
    guard ai.selectedChatDraft != nil, !isSending else { return }
    DispatchQueue.main.async {
      isComposerFocused = true
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
    let content = KnowledgeCitationMarkdownService.appendingCitations(
      to: message.content,
      citations: message.knowledgeCitations
    )
    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      content,
      to: draft,
      mode: .appendToBody
    ) else {
      ai.setChatMessage("AI 回复为空，未应用。")
      return
    }

    draftDiffPreview = AIChatDraftDiffPreview(
      originalDraft: draft,
      updatedDraft: result.draft,
      citations: message.knowledgeCitations
    )
    ai.setChatMessage("AI 修改预览已打开，接受后才会写入文章。")
  }

  private func applyDraftDiffPreview(_ preview: AIChatDraftDiffPreview) {
    guard let current = ai.selectedChatDraft,
          current.id == preview.originalDraft.id,
          current.bodyMarkdown == preview.originalDraft.bodyMarkdown else {
      ai.setChatMessage("文章已变化，这份 AI 修改预览未应用；请重新预览。")
      return
    }
    ai.updateChatDraft(preview.updatedDraft)
    ai.saveChatDraftChanges()
    ai.recordKnowledgeBacklinks(
      preview.citations,
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: preview.updatedDraft.id.uuidString,
        title: preview.updatedDraft.title,
        location: "正文"
      )
    )
    ai.setChatMessage(
      preview.citationCount > 0
        ? "已追加 AI 回复并插入资料库脚注。"
        : "已接受 AI 修改并追加到文章末尾。"
    )
  }
}

private struct AIChatScrollBottomPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let draftContext = state.draft {
        AIChatConversationInspectorSection(context: draftContext, actions: actions)
        AIChatRecommendedActionsInspectorSection(context: draftContext, actions: actions)
        AIChatRelatedSuggestionsInspectorSection(context: draftContext, actions: actions)

        DisclosureGroup("文章上下文", isExpanded: $isContextExpanded) {
          AIChatContextOverviewInspectorSection(context: draftContext)
            .padding(.top, 10)
        }

      } else {
        EmptyStateView(
          title: "没有上下文",
          message: "选择文章后，这里显示 AI 对话上下文。",
          systemImage: "sparkles",
          density: .compactPane
        )
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
      Text(LocalizedStringKey(title))
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
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .workbenchTruncatedIdentity(value)
    }
    .font(.caption)
  }
}
