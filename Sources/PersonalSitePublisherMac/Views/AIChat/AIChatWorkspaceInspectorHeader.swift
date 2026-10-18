import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {

  var currentAIModel: String? {
    let config = currentAIProviderConfig
    if ai.chatContextMode == .general {
      return
        displayedGeneralConversation?.selectedModel.nilIfEmpty
        ?? AIChatModelSelectionPresentationService.presentation(
          grade: displayedGeneralConversation?.modelGrade ?? chatState.chatModelGrade,
          selectedModel: "",
          config: config
        ).activeModel
    } else if inspectorDraft != nil {
      return
        AIChatModelSelectionPresentationService.presentation(
          grade: chatState.chatModelGrade,
          selectedModel: chatState.chatSelectedModel,
          config: config
        ).activeModel
    }
    return nil
  }

  var connectionReadiness: AIChatConnectionReadiness {
    let config = currentAIProviderConfig
    let hasToken: Bool
    if ai.chatContextMode == .general, let connection = selectedGeneralConnectionProfile {
      hasToken = ai.keyAvailability(forConnectionProfileID: connection.id).hasToken
    } else {
      hasToken = ai.tokenAvailability.hasToken
    }
    return AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: currentAIModel,
      hasToken: hasToken,
      hasDraft: ai.chatContextMode == .general || inspectorDraft != nil
    )
  }

  var isAIKeyMissing: Bool {
    if ai.chatContextMode == .general {
      guard let connection = selectedGeneralConnectionProfile else { return true }
      return connection.config.requiresAPIKey
        && generalKeyAvailabilityByConnectionID[connection.id]?.hasToken != true
    }
    guard let draft = inspectorDraft else { return false }
    return ai.chatProviderConfig(for: draft).requiresAPIKey
      && !ai.tokenAvailability.hasToken
  }

  var inspectorHeader: some View {
    conversationNavigationRow
      .padding(.horizontal, WorkbenchSpacing.card)
      .padding(.vertical, WorkbenchSpacing.control)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("AI 助手")
      .accessibilityIdentifier("ai-assistant-inspector")
  }

  var conversationNavigationRow: some View {
    let conversationCount: Int
    if ai.chatContextMode == .general {
      conversationCount =
        ai.generalChatConversationsIncludingArchived.filter { !$0.isArchived }.count
    } else if let draft = inspectorDraft {
      conversationCount = ai.chatConversations(for: draft.id, includingArchived: false).count
    } else {
      conversationCount = 0
    }

    return HStack(spacing: 6) {
      Button {
        isConversationPopoverPresented.toggle()
      } label: {
        HStack(spacing: 6) {
          Text(conversationNavigationTitle)
            .font(.workbenchMetadata.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.workbenchMetadata.weight(.bold))
            .foregroundStyle(
              isHeaderTitleHovered ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, WorkbenchSpacing.control)
        .padding(.vertical, WorkbenchSpacing.tight)
        .background(
          Color.primary.opacity(isHeaderTitleHovered ? 0.08 : 0.04),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovered in
        isHeaderTitleHovered = isHovered
      }
      .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)
      .disabled(ai.chatContextMode != .general && inspectorDraft == nil)
      .help(
        String(
          format: String(localized: "点击切换对话历史（当前草稿共 %lld 条对话）"),
          Int64(conversationCount)
        )
      )
      .accessibilityLabel(String(localized: "当前对话"))
      .accessibilityValue("\(conversationNavigationTitle)，\(conversationCount) 条对话")
      .accessibilityIdentifier("ai-assistant-conversation-picker")
      .popover(isPresented: $isConversationPopoverPresented, arrowEdge: .top) {
        conversationPickerContent
      }

      Text(verbatim: "·")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

      AIChatConnectionStatusCapsule(
        statusSummary: connectionControlTitle,
        statusDetail: connectionControlDetail,
        isReady: isCodexConnectionReadyForSending && codexConnectionPresentation == nil,
        isEnabled: ai.chatContextMode == .general || inspectorDraft != nil
      ) {
        if shouldShowConnectionBlocker {
          isConnectionPopoverPresented.toggle()
        } else {
          isModelQuickSwitchPresented = true
        }
      }
      .frame(minWidth: 88, maxWidth: 148)
      .popover(isPresented: $isConnectionPopoverPresented, arrowEdge: .top) {
        VStack(spacing: 8) {
          Text(connectionModelSummary)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WorkbenchSpacing.card)
            .padding(.top, WorkbenchSpacing.card)
          connectionBlockerBanner
          Divider()
          Button(String(localized: "AI 快捷切换")) {
            isConnectionPopoverPresented = false
            isModelQuickSwitchPresented = true
          }
          .padding(.bottom, WorkbenchSpacing.control)
        }
        .frame(width: 320)
      }

      assistantOptionsMenu
    }
  }

  var connectionControlTitle: String {
    if let presentation = codexConnectionPresentation {
      return presentation.title
    }
    guard connectionReadiness.isReady else { return connectionReadiness.title }
    return AIChatInspectorHeaderPresentation.compactModelTitle(
      for: currentAIProviderConfig,
      activeModel: currentAIModel
    )
  }

  var connectionControlDetail: String {
    let detail = codexConnectionPresentation?.detail ?? connectionReadiness.detail
    return connectionModelSummary + "\n" + detail
  }

  var connectionModelSummary: String {
    AIChatInspectorHeaderPresentation.modelSummary(
      for: currentAIProviderConfig,
      activeModel: currentAIModel
    )
  }

  @ViewBuilder
  var conversationPickerContent: some View {
    if ai.chatContextMode == .general {
      AIChatConversationPicker(
        draft: nil,
        conversations: ai.generalChatConversationsIncludingArchived,
        activeConversationID: ai.activeGeneralChatConversationID,
        isBusy: isChatBusy,
        selectConversation: { conversationID in
          if ai.selectGeneralChatConversation(conversationID) {
            setInspectorSurfaceConversationID(conversationID)
            isConversationPopoverPresented = false
          }
        },
        createConversation: {
          if let conversation = ai.startNewGeneralChatConversation(
            connectionProfileID: ai.activeGeneralChatConnectionProfile.id
          ) {
            setInspectorSurfaceConversationID(conversation.id)
            isConversationPopoverPresented = false
          }
        },
        renameConversation: { conversationID, title in
          _ = ai.renameChatConversation(conversationID, title: title)
        },
        archiveConversation: { conversationID in
          if ai.archiveChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation(
              discarding: conversationID
            )
          }
        },
        restoreConversation: { conversationID in
          if ai.restoreChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation()
          }
        },
        deleteConversation: { conversationID in
          if ai.deleteChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation(
              discarding: conversationID
            )
          }
        }
      )
    } else if let draft = inspectorDraft {
      AIChatConversationPicker(
        draft: draft,
        conversations: ai.chatConversations(
          for: draft.id,
          includingArchived: true
        ),
        activeConversationID: ai.activeChatConversationID(for: draft.id),
        isBusy: isChatBusy,
        selectConversation: { conversationID in
          if ai.selectChatConversation(conversationID) {
            setInspectorSurfaceConversationID(conversationID)
            isConversationPopoverPresented = false
          }
        },
        createConversation: {
          if startNewInspectorConversation(draft: draft) != nil {
            isConversationPopoverPresented = false
          }
        },
        renameConversation: { conversationID, title in
          _ = ai.renameChatConversation(conversationID, title: title)
        },
        archiveConversation: { conversationID in
          if ai.archiveChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation(
              discarding: conversationID
            )
          }
        },
        restoreConversation: { conversationID in
          if ai.restoreChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation()
          }
        },
        deleteConversation: { conversationID in
          if ai.deleteChatConversation(conversationID) {
            synchronizeInspectorSurfaceWithActiveConversation(
              discarding: conversationID
            )
          }
        }
      )
    }
  }

  var contextReferenceMenu: some View {
    Menu {
      contextModePicker

      Picker("资料库", selection: knowledgePolicyBinding) {
        ForEach(KnowledgeRetrievalPolicy.allCases) { policy in
          Text(localizedKnowledgePolicyTitle(policy)).tag(policy)
        }
      }
      .disabled(isChatBusy)

      Divider()

      ForEach(primaryChatContextReferences) { reference in
        contextReferenceButton(reference)
      }

      if !articleChatContextReferences.isEmpty {
        Menu("其他文章") {
          ForEach(articleChatContextReferences) { reference in
            contextReferenceButton(reference)
          }
        }
      }

      if !knowledgeChatContextReferences.isEmpty {
        Menu("资料库（仅允许发送给远程 AI）") {
          ForEach(knowledgeChatContextReferences) { reference in
            contextReferenceButton(reference)
          }
        }
      }

      if !selectedContextReferences.isEmpty {
        Divider()
        Button("清空 @ 上下文") {
          setSelectedContextReferences([])
        }
      }
    } label: {
      Label(
        selectedContextReferences.isEmpty
          ? AIChatInspectorHeaderPresentation.contextTitle(for: ai.chatContextMode)
          : AIChatInspectorHeaderPresentation.contextTitle(for: ai.chatContextMode)
            + " · @ \(selectedContextReferences.count)",
        systemImage: "at"
      )
    }
    .menuStyle(.borderlessButton)
    .lineLimit(1)
    .disabled(isChatBusy)
    .help(
      AIChatInspectorDensityPresentation.compactContextSummary(
        mode: ai.chatContextMode,
        draftTitle: inspectorDraft?.title,
        explicitReferenceCount: selectedContextReferences.count,
        knowledgeTitle: localizedKnowledgePolicyTitle(knowledgePolicyBinding.wrappedValue),
        agentTitle: ""
      )
    )
    .accessibilityLabel(String(localized: "引用上下文"))
    .accessibilityValue(
      AIChatInspectorHeaderPresentation.contextSummary(
        mode: ai.chatContextMode,
        draftTitle: inspectorDraft?.title,
        selectedReferences: selectedContextReferences
      ).detail
    )
    .accessibilityIdentifier("ai-assistant-context-menu")
  }

  var contextModePicker: some View {
    Picker(String(localized: "上下文"), selection: contextModeBinding) {
      ForEach(AIPublishingChatContextMode.allCases) { mode in
        Text(AIChatInspectorHeaderPresentation.contextTitle(for: mode)).tag(mode)
      }
    }
    .pickerStyle(.inline)
    .disabled(isChatBusy)
    .help(ai.chatContextMode.detail)
    .accessibilityLabel(String(localized: "上下文"))
    .accessibilityValue(AIChatInspectorHeaderPresentation.contextTitle(for: ai.chatContextMode))
    .accessibilityIdentifier("ai-assistant-context-mode")
  }

  var assistantOptionsMenu: some View {
    Menu {
      Button {
        startNewInspectorConversation(draft: inspectorDraft)
      } label: {
        Label(String(localized: "新对话"), systemImage: "square.and.pencil")
      }
      .disabled(isChatBusy || (ai.chatContextMode != .general && inspectorDraft == nil))
      .accessibilityLabel(String(localized: "新建 AI 对话"))
      .accessibilityHint(String(localized: "开始一段新的 AI 对话"))
      .accessibilityIdentifier("ai-assistant-new-conversation")

      quickActionsMenu

      Divider()

      if supportsSelectableReasoningLevel {
        Picker(String(localized: "思考级别"), selection: reasoningLevelBinding) {
          ForEach(AIChatReasoningLevel.allCases) { level in
            Text(localizedReasoningLevelTitle(level)).tag(level)
          }
        }

        Divider()
      }

      Menu(String(localized: "自定义指令")) {
        if ai.chatCustomPrompts.isEmpty {
          Text("尚未保存自定义指令")
        } else {
          ForEach(ai.chatCustomPrompts) { prompt in
            Menu(prompt.title) {
              Button {
                setInputText(prompt.prompt)
                focusComposerIfAvailable()
              } label: {
                Label(String(localized: "使用"), systemImage: "text.cursor")
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
          Label(String(localized: "保存当前输入"), systemImage: "plus")
        }
        .disabled(trimmedInput.isEmpty)
      }

      Divider()

      Menu("翻译为关联新草稿") {
        Button("创建英文翻译草稿") {
          setInputText("请帮我将当前文章全文翻译为英文，并创建关联新草稿；不要覆盖原稿。")
          focusComposerIfAvailable()
        }
        Button("创建简体中文翻译草稿") {
          setInputText("请帮我将当前文章全文翻译为简体中文，并创建关联新草稿；不要覆盖原稿。")
          focusComposerIfAvailable()
        }
      }

      Divider()

      Button {
        openAISettings()
      } label: {
        Label("打开 AI 设置", systemImage: "gearshape")
      }

      Divider()

      Button {
        workspaceWindowSession?.closeAssistantInspector()
        ai.hideAssistant()
      } label: {
        Label(String(localized: "关闭 AI 助手"), systemImage: "xmark")
      }
      .accessibilityLabel(String(localized: "关闭 AI 助手"))
      .accessibilityIdentifier("ai-assistant-close")
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .fixedSize()
    .help("AI 助手")
    .accessibilityLabel("AI 助手")
    .accessibilityIdentifier("ai-assistant-options")
  }

  var quickActionsMenu: some View {
    Menu {
      ForEach(AIPublishingChatQuickAction.allCases) { action in
        Button {
          setInputText(action.localizedPrompt)
          focusComposerIfAvailable()
        } label: {
          Label {
            Text(action.localizedDisplayName)
          } icon: {
            Image(systemName: action.systemImage)
          }
        }
        .help(action.localizedDisplayName)
      }
    } label: {
      Label(String(localized: "快捷提示"), systemImage: "text.badge.plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .help(String(localized: "快捷提示"))
    .accessibilityLabel(String(localized: "快捷提示"))
    .accessibilityHint("选择后会填入输入框，可修改后再发送。")
    .accessibilityIdentifier("ai-assistant-quick-actions")
  }

  var reasoningLevelBinding: Binding<AIChatReasoningLevel> {
    Binding(
      get: {
        ai.chatContextMode == .general
          ? (displayedGeneralConversation?.reasoningLevel ?? .deep)
          : ai.chatReasoningLevel
      },
      set: {
        if ai.chatContextMode == .general {
          _ = ai.setGeneralChatReasoningLevel(
            $0,
            conversationID: displayedGeneralConversation?.id
          )
        } else {
          ai.setChatReasoningLevel($0)
        }
      }
    )
  }
}
