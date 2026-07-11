import AppKit
import CoreText
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers

struct AIChatWorkspaceView: View {
  let store: WorkbenchStore
  @ObservedObject private var ai: WorkbenchAIFeatureFacade
  @State private var inputText = ""
  @State private var applyMessage: String?
  @State private var isPromptLibraryPresented = false
  @State private var capabilityMode: AIPublishingCapabilityCenterMode = .featured
  @State private var selectedImageAttachmentIDs: Set<UUID> = []
  @State private var conversationTitleDraft = ""
  @State private var isContextOverviewExpanded = false
  @State private var chatTask: Task<Void, Never>?
  @State private var chatTaskID: UUID?
  @FocusState private var isComposerFocused: Bool

  init(store: WorkbenchStore) {
    self.store = store
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  var body: some View {
    if let fallbackDraft = ai.selectedChatDraft {
      let draft = Binding<ArticleDraft>(
        get: { ai.selectedChatDraft ?? fallbackDraft },
        set: { ai.updateChatDraft($0) }
      )

      VStack(spacing: 0) {
        header(draft: draft.wrappedValue)
        Divider()
        if let issue = aiConfigurationIssue(for: draft.wrappedValue) {
          aiConfigurationIssueBanner(message: issue)
          Divider()
        }
        AIChatMessageFlowView(
          state: messageFlowState(for: draft.wrappedValue),
          contextOverview: {
            ContextOverview(
              state: contextOverviewState(for: draft.wrappedValue),
              isExpanded: isContextOverviewExpanded,
              onToggleExpanded: {
                withAnimation(.snappy(duration: 0.18)) {
                  isContextOverviewExpanded.toggle()
                }
              }
            )
          },
          actions: messageFlowActions(for: draft)
        )
        Divider()
        AIChatComposerView(
          draft: draft.wrappedValue,
          inputText: $inputText,
          applyMessage: $applyMessage,
          selectedImageAttachmentIDs: $selectedImageAttachmentIDs,
          isComposerFocused: $isComposerFocused,
          state: composerState(for: draft.wrappedValue),
          presentation: composerPresentation(for: draft.wrappedValue),
          actions: composerActions(for: draft.wrappedValue)
        )
      }
      .background(Color(nsColor: .textBackgroundColor))
      .accessibilityIdentifier("ai-chat-workspace")
      .accessibilityLabel("AI 对话工作区")
      .sheet(isPresented: $isPromptLibraryPresented) {
        AIChatPromptLibrarySheet(
          draft: draft.wrappedValue,
          onApplyPrompt: { prompt in
            inputText = prompt.prompt
            applyMessage = nil
            isComposerFocused = true
          },
          onApplyWorkflowGuide: { guide in
            inputText = AIPublishingChatPromptTemplateService.workflowGuidePrompt(for: guide)
            applyMessage = nil
            isComposerFocused = true
          },
          onApplyEditorAction: { action in
            inputText = AIPublishingChatPromptTemplateService.editorActionPrompt(for: action)
            applyMessage = nil
            isComposerFocused = true
          },
          customPrompts: ai.chatCustomPrompts,
          onApplyCustomPrompt: { prompt in
            inputText = prompt.prompt
            applyMessage = nil
            isComposerFocused = true
          },
          onDeleteCustomPrompt: { promptID in
            store.ai.deleteChatCustomPrompt(promptID)
          }
        )
        .frame(minWidth: 720, minHeight: 620)
      }
      .onAppear {
        store.ai.refreshKeyAvailability()
        store.ai.prepareChat(for: draft.wrappedValue)
        syncConversationTitleDraft(for: draft.wrappedValue)
        pruneSelectedImageAttachments(for: draft.wrappedValue)
        applyPendingQuickPromptIfNeeded()
      }
      .onChange(of: draft.wrappedValue.id) { _, _ in
        stopGenerating()
        store.ai.prepareChat(for: draft.wrappedValue)
        selectedImageAttachmentIDs = []
        syncConversationTitleDraft(for: draft.wrappedValue)
        applyPendingQuickPromptIfNeeded()
      }
      .onChange(of: ai.chatConversationTitle) { _, _ in
        syncConversationTitleDraft(for: draft.wrappedValue)
      }
      .onChange(of: ai.chatMessages.count) { _, _ in
        guard ai.chatConversationTitle?.nilIfEmpty == nil else { return }
        syncConversationTitleDraft(for: draft.wrappedValue)
      }
      .onChange(of: ai.pendingQuickPrompt?.id) { _, _ in
        applyPendingQuickPromptIfNeeded()
      }
      .onDisappear {
        stopGenerating()
      }
    } else {
      EmptyStateView(
        title: "没有上下文文章",
        message: "选择或新建文章后，可以在 AI 工作区讨论当前文章。",
        systemImage: "sparkles"
      )
      .background(Color(nsColor: .textBackgroundColor))
    }
  }

  private func messageFlowState(for draft: ArticleDraft) -> AIChatMessageFlowState {
    AIChatMessageFlowState(
      draft: draft,
      messages: store.ai.chatMessages,
      isRunning: store.ai.isChatRunning,
      capabilityMode: capabilityMode,
      applyMessage: applyMessage
    )
  }

  private func messageFlowActions(for draft: Binding<ArticleDraft>) -> AIChatMessageFlowActions {
    AIChatMessageFlowActions(
      setCapabilityMode: { mode in
        capabilityMode = mode
      },
      promptSelected: { promptText in
        inputText = promptText
        applyMessage = nil
        isComposerFocused = true
      },
      openPromptLibrary: {
        isPromptLibraryPresented = true
      },
      actionAvailability: { message, currentDraft in
        actionAvailability(for: message, draft: currentDraft)
      },
      canReplaceSelection: { currentDraft in
        canReplaceSelection(in: currentDraft)
      },
      messageActions: AIChatMessageActions(
        copy: { message in
          copy(AIPublishingChatMessageCompositionService.displayContent(for: message))
        },
        quote: quote,
        delete: { message in
          store.ai.deleteChatMessage(message.id, draft: draft.wrappedValue)
        },
        branch: { message in
          store.ai.branchChatConversation(after: message.id, draft: draft.wrappedValue)
        },
        regenerate: { message in
          regenerate(message, draft: draft.wrappedValue)
        },
        apply: AIChatMessageApplyActions(
          appendToBody: { message in
            apply(message, to: draft, mode: .appendToBody)
          },
          replaceSelection: { message in
            applyToCurrentSelection(message, to: draft)
          },
          replaceBody: { message in
            apply(message, to: draft, mode: .replaceBody)
          }
        )
      )
    )
  }

  private func contextOverviewState(for draft: ArticleDraft) -> AIChatContextOverviewState {
    let profile = store.ai.chatProfile(for: draft)
    let focusedParagraph = store.ai.focusedChatParagraph(for: draft)
    let relatedSuggestionCount = store.ai.relatedChatArticleSuggestions(for: draft, limit: 5).count
    let contextDetails = AIPublishingChatConversationPresentation.contextDetails(
      profile: profile,
      draft: draft,
      visibleDrafts: store.ai.chatVisibleDrafts,
      contextMode: store.ai.chatContextMode,
      selectedParagraph: focusedParagraph,
      relatedSuggestionCount: relatedSuggestionCount
    )
    let usageSummary = AIChatUsageSummaryService.summary(
      messages: store.ai.chatMessages,
      config: profile.aiProviderConfig
    )

    return AIChatContextOverviewState(
      draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
      markdownPath: profile.markdownPath(for: draft),
      contextModeDisplayName: store.ai.chatContextMode.displayName,
      contextModeSystemImage: store.ai.chatContextMode.systemImage,
      modelText: AIPublishingChatConversationPresentation.modelSummary(
        grade: store.ai.chatModelGrade,
        config: profile.aiProviderConfig,
        selectedModel: store.ai.chatSelectedModel
      ),
      retrievalBasis: contextDetails.retrievalBasis,
      tokenDisplayText: usageSummary.tokenDisplayText,
      costDisplayText: usageSummary.costDisplayText,
      imageInputText: profile.aiProviderConfig.supportsImageInput ? "图片输入可用" : "当前模型不支持图片输入",
      focusedParagraphTitle: focusedParagraph?.title,
      shouldShowPublicCandidates: store.ai.chatContextMode == .site,
      publicCandidateCount: contextDetails.publicCandidateCount,
      relatedSuggestionCount: contextDetails.relatedSuggestionCount,
      attachmentCount: draft.attachments.count
    )
  }

  private func composerState(for draft: ArticleDraft) -> AIChatComposerState {
    AIChatComposerState(
      isChatRunning: store.ai.isChatRunning,
      chatMessage: store.ai.chatMessage,
      chatContextModeDetail: store.ai.chatContextMode.detail,
      focusedParagraphID: store.ai.chatFocusedParagraphID,
      focusedParagraph: store.ai.focusedChatParagraph(for: draft)
    )
  }

  private func composerPresentation(for draft: ArticleDraft) -> AIChatComposerPresentation {
    AIChatComposerPresentation(
      sendReadiness: chatSendReadiness(for: draft),
      modelPresentation: AIChatModelSelectionPresentationService.presentation(
        grade: store.ai.chatModelGrade,
        selectedModel: store.ai.chatSelectedModel,
        config: store.ai.chatProfile(for: draft).aiProviderConfig
      ),
      modelGradeBinding: modelGradeBinding,
      customModelBinding: customModelBinding,
      chatContextModeBinding: chatContextModeBinding,
      chatModelGrades: chatModelGrades,
      chatModelHelpText: chatModelHelpText(draft: draft),
      chatContextModeDisplayName: store.ai.chatContextMode.displayName
    )
  }

  private func composerActions(for draft: ArticleDraft) -> AIChatComposerActions {
    AIChatComposerActions(
      openPromptLibrary: {
        isPromptLibraryPresented = true
      },
      setCustomModel: { model in
        store.ai.setChatCustomModel(model)
      },
      resetModelToProfileDefault: {
        store.ai.resetChatModelToProfileDefault()
      },
      setFocusedParagraph: { paragraphID in
        store.ai.setChatFocusedParagraph(paragraphID, draft: draft)
      },
      stopGenerating: stopGenerating,
      send: {
        send(draft: draft)
      },
      appendArticleContext: {
        appendArticleContext(draft)
      },
      appendParagraphContext: { paragraph in
        appendParagraphContext(paragraph, draft: draft)
      },
      appendPublishingContext: {
        appendPublishingContext(draft)
      },
      saveCustomPrompt: saveCustomPrompt,
      importImages: {
        importImageAttachments(for: draft)
      },
      toggleImageAttachment: toggleImageAttachment,
      attachmentLabel: attachmentLabel
    )
  }

  private func header(draft: ArticleDraft) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          TextField("对话标题", text: $conversationTitleDraft)
            .textFieldStyle(.plain)
            .font(.headline)
            .lineLimit(1)
            .accessibilityLabel("AI 对话标题")
            .accessibilityValue(conversationTitleDraft.nilIfEmpty ?? "自动标题")
            .onSubmit {
              commitConversationTitle(draft: draft)
            }
            .disabled(store.ai.isChatRunning)
            .help("为当前 AI 对话命名，历史会话会保留这个标题。")

          Button {
            commitConversationTitle(draft: draft)
          } label: {
            Image(systemName: "checkmark")
          }
          .buttonStyle(.borderless)
          .disabled(store.ai.isChatRunning || !hasEditedConversationTitle(for: draft))
          .help("保存对话标题")
          .accessibilityLabel("保存 AI 对话标题")

          Button {
            store.ai.setChatConversationTitle(nil, draft: draft)
            syncConversationTitleDraft(for: draft)
          } label: {
            Image(systemName: "wand.and.stars")
          }
          .buttonStyle(.borderless)
          .disabled(store.ai.isChatRunning || store.ai.chatConversationTitle?.nilIfEmpty == nil)
          .help("恢复自动标题")
          .accessibilityLabel("恢复 AI 对话自动标题")
        }
        Text(contextSummary(for: draft))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      headerActions(draft: draft)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func contextArticleMenu(currentDraft: ArticleDraft) -> some View {
    Menu {
      ForEach(store.ai.chatVisibleDrafts) { draft in
        Button {
          store.ai.openChatWorkspace(for: draft.id)
          applyMessage = nil
          selectedImageAttachmentIDs = []
        } label: {
          Label(
            draft.title.nilIfEmpty ?? "未命名文章",
            systemImage: draft.id == currentDraft.id ? "checkmark.circle.fill" : "doc.text"
          )
        }
      }
    } label: {
      Label("上下文文章", systemImage: "doc.text.magnifyingglass")
    }
    .disabled(store.ai.isChatRunning || store.ai.chatVisibleDrafts.count <= 1)
  }

  private func headerActions(draft: ArticleDraft) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        contextArticleMenu(currentDraft: draft)
        headerModelMenu(draft: draft)
        promptLibraryButton
        headerMoreMenu(draft: draft)
      }

      HStack(spacing: 5) {
        contextArticleMenu(currentDraft: draft)
          .labelStyle(.iconOnly)
        headerModelMenu(draft: draft)
          .labelStyle(.iconOnly)
        promptLibraryButton
          .labelStyle(.iconOnly)
        headerMoreMenu(draft: draft)
          .labelStyle(.iconOnly)
      }
    }
  }

  private func headerModelMenu(draft: ArticleDraft) -> some View {
    Menu {
      ForEach(chatModelGrades) { grade in
        Button {
          store.ai.setChatModelGrade(grade)
        } label: {
          if grade == store.ai.chatModelGrade {
            Label(grade.title, systemImage: "checkmark")
          } else {
            Text(grade.title)
          }
        }
      }
    } label: {
      Label("模型", systemImage: "cpu")
    }
    .disabled(store.ai.isChatRunning)
    .help(chatModelHelpText(draft: draft))
    .accessibilityLabel("AI 模型")
    .accessibilityValue(store.ai.chatModelGrade.title)
  }

  private var promptLibraryButton: some View {
    Button {
      isPromptLibraryPresented = true
    } label: {
      Label("指令库", systemImage: "books.vertical")
    }
    .disabled(store.ai.isChatRunning)
  }

  private func headerMoreMenu(draft: ArticleDraft) -> some View {
    Menu {
      Button {
        store.ai.startNewChatConversation(draft: draft)
        inputText = ""
        selectedImageAttachmentIDs = []
        applyMessage = nil
        isComposerFocused = true
      } label: {
        Label("新对话", systemImage: "plus.message")
      }
      .disabled(store.ai.isChatRunning)

      archivedConversationMenu(draft)

      Divider()

      Menu {
        Button {
          copyTranscript(draft: draft)
        } label: {
          Label("复制 Markdown", systemImage: "doc.on.doc")
        }
        Button {
          exportTranscript(.markdown, draft: draft)
        } label: {
          Label("导出 Markdown...", systemImage: "square.and.arrow.down")
        }
        Button {
          exportTranscript(.pdf, draft: draft)
        } label: {
          Label("导出 PDF...", systemImage: "doc.richtext")
        }
      } label: {
        Label("导出", systemImage: "square.and.arrow.down")
      }
      .disabled(store.ai.chatMessages.isEmpty || store.ai.isChatRunning)

      Button {
        regenerate(draft: draft)
      } label: {
        Label("重新生成", systemImage: "arrow.clockwise")
      }
      .disabled(!canRegenerate || store.ai.isChatRunning)

      Divider()

      Button(role: .destructive) {
        store.ai.clearChat()
        applyMessage = nil
      } label: {
        Label("清空对话", systemImage: "trash")
      }
      .disabled(store.ai.chatMessages.isEmpty || store.ai.isChatRunning)
    } label: {
      Label("更多", systemImage: "ellipsis.circle")
    }
    .help("新对话、历史、导出、重新生成和清空")
    .accessibilityLabel("更多 AI 对话操作")
  }

  private func aiConfigurationIssueBanner(message: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        openAISettings()
      } label: {
        Label("打开 AI 设置", systemImage: "gearshape")
      }
      .controlSize(.small)
      .disabled(store.ai.isChatRunning)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.orange.opacity(WorkbenchOpacity.noticeBackground))
  }

  private func openAISettings() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
  }

  private func applyPendingQuickPromptIfNeeded() {
    guard let prompt = store.ai.consumePendingQuickPrompt() else {
      return
    }
    inputText = prompt.prompt
    selectedImageAttachmentIDs = []
    applyMessage = nil
    isComposerFocused = true
  }

  private func archivedConversationMenu(_ draft: ArticleDraft) -> some View {
    Menu {
      if store.ai.archivedConversations.isEmpty {
        Text("暂无历史对话")
      } else {
        ForEach(store.ai.archivedConversations) { conversation in
          let presentation = AIPublishingChatConversationPresentation.archivedConversationPresentation(
            for: conversation,
            config: store.ai.chatProfile(for: draft).aiProviderConfig
          )
          Menu {
            Button {
              store.ai.restoreArchivedChatConversation(conversation.id, draft: draft)
              applyMessage = nil
            } label: {
              Label("恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
              store.ai.deleteArchivedChatConversation(conversation.id, draft: draft)
              applyMessage = nil
            } label: {
              Label("删除", systemImage: "trash")
            }
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                Text(presentation.subtitle)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "clock.arrow.circlepath")
            }
          }
        }
      }
    } label: {
      Label("历史", systemImage: "clock.arrow.circlepath")
    }
    .disabled(store.ai.isChatRunning || store.ai.archivedConversations.isEmpty)
  }

  private func aiConfigurationIssue(for draft: ArticleDraft) -> String? {
    let profile = store.ai.chatProfile(for: draft)
    return AIPublishingChatConversationPresentation.configurationIssue(
      config: profile.aiProviderConfig,
      aiTokenAvailability: store.ai.tokenAvailability,
      grade: store.ai.chatModelGrade,
      selectedModel: store.ai.chatSelectedModel
    )
  }

  private var canRegenerate: Bool {
    store.ai.chatMessages.contains(where: { $0.role == .user })
  }

  private func canRegenerate(_ message: AIPublishingChatMessage) -> Bool {
    actionAvailability(for: message, draft: store.ai.selectedChatDraft).canRegenerate
  }

  private func actionAvailability(
    for message: AIPublishingChatMessage,
    draft: ArticleDraft?
  ) -> AIPublishingChatMessageActionAvailability {
    AIPublishingChatMessageActionAvailabilityService.availability(
      for: message,
      isSending: store.ai.isChatRunning,
      configurationIssue: draft.map(aiConfigurationIssue(for:)) ?? "未选择文章。",
      hasSelectedDraft: draft != nil
    )
  }

  private func canReplaceSelection(in draft: ArticleDraft) -> Bool {
    store.ai.activeChatEditorSelectionRange(for: draft) != nil
  }

  private func conversationTitle(for draft: ArticleDraft) -> String {
    AIPublishingChatConversationPresentation.displayTitle(
      conversationTitle: store.ai.chatConversationTitle,
      messages: store.ai.chatMessages,
      draft: draft
    )
  }

  private func syncConversationTitleDraft(for draft: ArticleDraft) {
    conversationTitleDraft = conversationTitle(for: draft)
  }

  private func hasEditedConversationTitle(for draft: ArticleDraft) -> Bool {
    let normalizedDraft = conversationTitleDraft.trimmedForPublishing.nilIfEmpty
    let normalizedCurrent = store.ai.chatConversationTitle?.trimmedForPublishing.nilIfEmpty
    if normalizedDraft == nil && normalizedCurrent == nil {
      return false
    }
    if normalizedCurrent != nil {
      return normalizedDraft != normalizedCurrent
    }
    return normalizedDraft != conversationTitle(for: draft).trimmedForPublishing.nilIfEmpty
  }

  private func commitConversationTitle(draft: ArticleDraft) {
    guard hasEditedConversationTitle(for: draft) else {
      syncConversationTitleDraft(for: draft)
      return
    }
    store.ai.setChatConversationTitle(conversationTitleDraft, draft: draft)
    syncConversationTitleDraft(for: draft)
  }

  private func contextSummary(for draft: ArticleDraft) -> String {
    let profile = store.ai.chatProfile(for: draft)
    let focusedParagraph = store.ai.focusedChatParagraph(for: draft)
    return AIPublishingChatConversationPresentation.contextSummary(
      profile: profile,
      draft: draft,
      contextMode: store.ai.chatContextMode,
      selectedParagraphTitle: focusedParagraph?.title
    )
  }

  private func regenerate(draft: ArticleDraft) {
    applyMessage = nil
    Task {
      await store.ai.regenerateLastChatReply(draft: draft)
    }
  }

  private func regenerate(_ message: AIPublishingChatMessage, draft: ArticleDraft) {
    guard canRegenerate(message) else {
      return
    }
    applyMessage = nil
    chatTask?.cancel()
    let taskID = UUID()
    chatTaskID = taskID
    chatTask = Task { @MainActor in
      await store.ai.regenerateChatReply(messageID: message.id, draft: draft)
      if chatTaskID == taskID {
        chatTask = nil
        chatTaskID = nil
      }
    }
  }

  private func quote(_ message: AIPublishingChatMessage) {
    let prompt = AIPublishingChatPromptTemplateService.quotedMessagePrompt(for: message)
    guard !prompt.isEmpty else {
      return
    }
    appendPromptText(prompt)
  }

  private func apply(
    _ message: AIPublishingChatMessage,
    to draft: Binding<ArticleDraft>,
    mode: AIPublishingChatDraftApplicationMode,
    selectionRange: NSRange? = nil
  ) {
    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: draft.wrappedValue,
      mode: mode,
      selectionRange: selectionRange
    ) else {
      applyMessage = mode == .replaceSelection ? "请先在编辑器选择要替换的正文。" : "AI 回复为空，未应用。"
      return
    }

    draft.wrappedValue = result.draft
    store.ai.saveChatDraftChanges()
    applyMessage = result.action.statusMessage
  }

  private func applyToCurrentSelection(
    _ message: AIPublishingChatMessage,
    to draft: Binding<ArticleDraft>
  ) {
    guard let selectionRange = store.ai.activeChatEditorSelectionRange(for: draft.wrappedValue) else {
      applyMessage = "请先在编辑器选择要替换的正文。"
      return
    }
    apply(
      message,
      to: draft,
      mode: .replaceSelection,
      selectionRange: selectionRange
    )
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
      if store.ai.isChatRunning {
        proxy.scrollTo("ai-running", anchor: .bottom)
      } else if let lastMessage = store.ai.chatMessages.last {
        proxy.scrollTo(lastMessage.id, anchor: .bottom)
      }
    }
  }

  private func copy(_ text: String) {
    ClipboardWriter.copy(text, successMessage: "已复制到剪贴板。") { store.setPublishActionMessage($0) }
  }

private func chatSendReadiness(for draft: ArticleDraft) -> AIPublishingChatSendReadiness {
  let profile = store.ai.chatProfile(for: draft)
  return AIPublishingChatConversationPresentation.sendReadiness(
    inputText: inputText,
    selectedImageCount: selectedImageAttachmentIDs.count,
    isSending: store.ai.isChatRunning,
    config: profile.aiProviderConfig,
    aiTokenAvailability: store.ai.tokenAvailability,
    grade: store.ai.chatModelGrade,
    selectedModel: store.ai.chatSelectedModel
  )
}

private var chatModelGrades: [AIChatModelGrade] {
  [.fast, .standard, .highQuality, .custom]
}

private var modelGradeBinding: Binding<AIChatModelGrade> {
  Binding(
    get: { store.ai.chatModelGrade },
    set: { store.ai.setChatModelGrade($0) }
  )
}

private var customModelBinding: Binding<String> {
  Binding(
    get: { store.ai.chatSelectedModel },
    set: { store.ai.setChatCustomModel($0) }
  )
}

private var chatContextModeBinding: Binding<AIPublishingChatContextMode> {
  Binding(
    get: { store.ai.chatContextMode },
    set: { store.ai.setChatContextMode($0) }
  )
}

private func chatModelHelpText(draft: ArticleDraft) -> String {
  let config = store.ai.chatProfile(for: draft).aiProviderConfig
  return AIPublishingChatConversationPresentation.modelSummary(
    grade: store.ai.chatModelGrade,
    config: config,
    selectedModel: store.ai.chatSelectedModel
  )
}

private func send(draft: ArticleDraft) {
  let sendReadiness = chatSendReadiness(for: draft)
  guard sendReadiness.canSend else {
    store.ai.setChatMessage(
      sendReadiness.imageAttachmentIssue
        ?? sendReadiness.configurationIssue
        ?? "请先输入要发送给 AI 的内容。"
    )
    return
  }
  let message = sendReadiness.trimmedInput
  let imageAttachments = store.ai.chatImageAttachments(
    for: draft,
    attachmentIDs: selectedImageAttachmentIDs
  )
  guard message.nilIfEmpty != nil || !imageAttachments.isEmpty else {
    return
  }
  inputText = ""
  selectedImageAttachmentIDs = []
  applyMessage = nil
  chatTask?.cancel()
  let taskID = UUID()
  chatTaskID = taskID
  chatTask = Task { @MainActor in
    await store.ai.sendChatMessage(message, draft: draft, imageAttachments: imageAttachments)
    if chatTaskID == taskID {
      chatTask = nil
      chatTaskID = nil
    }
  }
}

private func stopGenerating() {
  guard chatTask != nil || store.ai.isChatRunning else {
    return
  }
  store.ai.cancelChatReply()
  chatTask?.cancel()
  chatTask = nil
  chatTaskID = nil
}

private func importImageAttachments(for draft: ArticleDraft) {
  let panel = NSOpenPanel()
  panel.allowsMultipleSelection = true
  panel.canChooseDirectories = false
  panel.canChooseFiles = true
  panel.allowedContentTypes = allowedImageContentTypes
  panel.prompt = "添加"
  panel.message = "选择要加入当前文章并发送给 AI 的图片。"

  guard panel.runModal() == .OK else {
    return
  }

  let imageURLs = panel.urls.filter(ImageFileSupport.isSupportedImageURL)
  guard !imageURLs.isEmpty else {
    applyMessage = "没有可添加的图片文件。"
    return
  }

  var updatedDraft = draft
  var selectableImportedIDs: [UUID] = []
  for url in imageURLs {
    let attachment = store.ai.makeImageAttachment(from: url, draft: updatedDraft)
    updatedDraft.attachments.append(attachment)
    if AIPublishingChatImageAttachmentPresentation.isWithinAttachmentSizeLimit(attachment.byteSize) {
      selectableImportedIDs.append(attachment.id)
    }
  }

  store.ai.updateChatDraft(updatedDraft)
  store.ai.refreshChatImageWorkbenchReport()
  let importPresentation = AIPublishingChatImageAttachmentPresentation.importPresentation(
    importedCount: imageURLs.count,
    selectableImportedCount: selectableImportedIDs.count,
    availableSelectionSlots: AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount - selectedImageAttachmentIDs.count
  )
  selectedImageAttachmentIDs.formUnion(selectableImportedIDs.prefix(importPresentation.selectedCount))
  applyMessage = importPresentation.message
}

private var allowedImageContentTypes: [UTType] {
  ImageFileSupport.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
}

private func toggleImageAttachment(_ id: UUID) {
  if selectedImageAttachmentIDs.contains(id) {
    selectedImageAttachmentIDs.remove(id)
    applyMessage = nil
  } else if selectedImageAttachmentIDs.count < AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount {
    selectedImageAttachmentIDs.insert(id)
    applyMessage = nil
  } else {
    applyMessage = AIPublishingChatImageAttachmentPresentation.maximumSelectionMessage()
  }
}

private func pruneSelectedImageAttachments(for draft: ArticleDraft) {
  let availableIDs = Set(draft.attachments.map(\.id))
  selectedImageAttachmentIDs = selectedImageAttachmentIDs.intersection(availableIDs)
}

private func attachmentLabel(_ attachment: DraftAttachment) -> String {
  attachment.originalFilename.nilIfEmpty
    ?? attachment.relativePublishPath.nilIfEmpty
    ?? attachment.repositoryPath.nilIfEmpty
    ?? "图片附件"
}

private func appendPromptText(_ promptText: String) {
  if inputText.trimmedForPublishing.isEmpty {
    inputText = promptText
  } else {
    inputText += "\n\n\(promptText)"
  }
  applyMessage = nil
  isComposerFocused = true
}

private func appendArticleContext(_ draft: ArticleDraft) {
  let prompt = AIPublishingChatPromptTemplateService.articleContextPrompt(
    for: draft,
    profile: store.ai.chatProfile(for: draft)
  )
  appendPromptText(prompt)
}

private func appendParagraphContext(
  _ paragraph: AIPublishingChatDraftParagraph,
  draft: ArticleDraft
) {
  let prompt = AIPublishingChatPromptTemplateService.paragraphContextPrompt(
    for: paragraph,
    draft: draft,
    profile: store.ai.chatProfile(for: draft)
  )
  appendPromptText(prompt)
}

private func appendPublishingContext(_ draft: ArticleDraft) {
  let prompt = AIPublishingChatPromptTemplateService.publishingContextPrompt(
    for: draft,
    profile: store.ai.chatProfile(for: draft),
    issues: store.ai.chatPreflightIssues(for: draft),
    package: store.ai.chatPublishingPackage(for: draft),
    imageReport: store.ai.chatImageWorkbenchReport(for: draft)
  )
  appendPromptText(prompt)
}

private func saveCustomPrompt() {
  let prompt = inputText.trimmedForPublishing
  guard !prompt.isEmpty else {
    return
  }
  let title = prompt.components(separatedBy: .newlines).first?.trimmedForPublishing ?? "自定义提示"
  store.ai.saveChatCustomPrompt(title: title, prompt: prompt)
  applyMessage = "已保存到自定义提示。"
}

  private func copyTranscript(draft: ArticleDraft) {
    guard let transcript = transcriptMarkdown(draft: draft) else {
      applyMessage = "当前对话为空，未复制。"
      return
    }
    copy(transcript)
    applyMessage = "已复制 AI 对话记录。"
  }

  private func transcriptMarkdown(draft: ArticleDraft) -> String? {
    let profile = store.ai.chatProfile(for: draft)
    let transcript = AIPublishingChatTranscriptService.markdownTranscript(
      messages: store.ai.chatMessages,
      draft: draft,
      contextMode: store.ai.chatContextMode,
      conversationTitle: conversationTitle(for: draft),
      contextSummary: AIPublishingChatConversationPresentation.contextSummary(
        profile: profile,
        draft: draft,
        contextMode: store.ai.chatContextMode
      ),
      modelSummary: AIPublishingChatConversationPresentation.modelSummary(
        grade: store.ai.chatModelGrade,
        config: profile.aiProviderConfig,
        selectedModel: store.ai.chatSelectedModel
      )
    )
    return transcript.isEmpty ? nil : transcript
  }

  private func exportTranscript(_ format: AIChatTranscriptExportFormat, draft: ArticleDraft) {
    guard let transcript = transcriptMarkdown(draft: draft) else {
      applyMessage = "当前对话为空，未导出。"
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [format.contentType]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(sanitizedFilename(conversationTitle(for: draft))).\(format.fileExtension)"
    panel.prompt = "导出"
    panel.message = "将当前 AI 对话保存为 \(format.displayName)。"
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      switch format {
      case .markdown:
        try transcript.write(to: url, atomically: true, encoding: .utf8)
      case .pdf:
        try pdfData(for: transcript).write(to: url, options: [.atomic])
      }
      applyMessage = "已导出 AI 对话记录：\(url.lastPathComponent)"
    } catch {
      applyMessage = "导出失败：\(error.localizedDescription)"
    }
  }

  private func sanitizedFilename(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let cleaned = value
      .components(separatedBy: invalid)
      .joined(separator: "-")
      .trimmedForPublishing
    return cleaned.nilIfEmpty ?? "AI-Chat-Transcript"
  }

  private func pdfData(for transcript: String) throws -> Data {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let contentRect = pageRect.insetBy(dx: 54, dy: 54)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = pageRect
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }

    let attributed = NSAttributedString(
      string: transcript,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    var range = CFRange(location: 0, length: 0)
    let path = CGMutablePath()
    path.addRect(contentRect)

    while range.location < attributed.length {
      context.beginPDFPage(nil)
      context.textMatrix = .identity
      context.translateBy(x: 0, y: pageRect.height)
      context.scaleBy(x: 1, y: -1)
      let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
      CTFrameDraw(frame, context)
      let visibleRange = CTFrameGetVisibleStringRange(frame)
      range.location += max(visibleRange.length, 1)
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
}

private enum AIChatTranscriptExportFormat {
  case markdown
  case pdf

  var displayName: String {
    switch self {
    case .markdown:
      return "Markdown"
    case .pdf:
      return "PDF"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown:
      return "md"
    case .pdf:
      return "pdf"
    }
  }

  var contentType: UTType {
    switch self {
    case .markdown:
      return UTType(filenameExtension: "md") ?? .plainText
    case .pdf:
      return .pdf
    }
  }
}
