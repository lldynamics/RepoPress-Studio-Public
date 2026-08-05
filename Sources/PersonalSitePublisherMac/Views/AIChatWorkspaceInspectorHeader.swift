import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {

  var missingAIKeyBanner: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "key.horizontal")
        .foregroundStyle(WorkbenchTheme.warning)

      Text("未配置 API Key")
        .font(.caption.weight(.semibold))

      Text("仅存钥匙串")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(String(localized: "ai-assistant.configure")) {
        openAISettings()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("未配置 API Key")
    .accessibilityHint("密钥仅保存在系统钥匙串中。")
  }

  var isAIKeyMissing: Bool {
    guard let draft = ai.selectedChatDraft else { return false }
    return ai.chatProviderConfig(for: draft).requiresAPIKey
      && !ai.tokenAvailability.hasToken
  }

  var inspectorHeader: some View {
    VStack(spacing: 8) {
      conversationNavigationRow
      configurationRow
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }


  var conversationNavigationRow: some View {
    let conversationCount =
      ai.selectedChatDraft != nil
      ? ai.chatConversations(for: ai.selectedChatDraft!.id, includingArchived: false).count : 0

    return HStack(spacing: 8) {
      Button {
        isConversationPopoverPresented.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)

          Text(conversationNavigationTitle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if conversationCount > 1 {
            Text("\(conversationCount)")
              .font(.workbenchMetadata.weight(.bold).monospacedDigit())
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.primary.opacity(0.08), in: Capsule())
              .foregroundStyle(.secondary)
          }

          Image(systemName: "chevron.down")
            .font(.workbenchMetadata.weight(.bold))
            .foregroundStyle(
              isHeaderTitleHovered ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          Color.primary.opacity(isHeaderTitleHovered ? 0.08 : 0.04),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovered in
        withAnimation(WorkbenchMotion.standard) {
          isHeaderTitleHovered = isHovered
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(ai.selectedChatDraft == nil)
      .help(
        String(
          format: String(localized: "点击切换对话历史（当前草稿共 %lld 条对话）"),
          Int64(conversationCount)
        )
      )
      .accessibilityLabel(String(localized: "当前对话"))
      .accessibilityValue(conversationNavigationTitle)
      .accessibilityIdentifier("ai-assistant-conversation-picker")
      .popover(isPresented: $isConversationPopoverPresented, arrowEdge: .top) {
        conversationPickerContent
      }

      AIChatConnectionStatusCapsule(
        ai: ai,
        draft: ai.selectedChatDraft
      ) {
        isModelQuickSwitchPresented = true
      }

      Button {
        ai.startNewChatConversation(draft: ai.selectedChatDraft)
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isSending || ai.selectedChatDraft == nil)
      .help(String(localized: "新对话"))
      .accessibilityLabel(String(localized: "新建 AI 对话"))
      .accessibilityHint(String(localized: "开始一段新的 AI 对话"))
      .accessibilityIdentifier("ai-assistant-new-conversation")

      Button {
        ai.closeAssistantPanel()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.plain)
      .help(String(localized: "关闭 AI 助手"))
      .accessibilityLabel(String(localized: "关闭 AI 助手"))
      .accessibilityIdentifier("ai-assistant-close")
    }
  }

  @ViewBuilder
  var conversationPickerContent: some View {
    if let draft = ai.selectedChatDraft {
      AIChatConversationPicker(
        draft: draft,
        conversations: ai.chatConversations(
          for: draft.id,
          includingArchived: true
        ),
        activeConversationID: ai.activeChatConversationID(for: draft.id),
        isBusy: isSending,
        selectConversation: { conversationID in
          if ai.selectChatConversation(conversationID) {
            isConversationPopoverPresented = false
          }
        },
        createConversation: {
          if ai.startNewChatConversation(draft: draft) != nil {
            isConversationPopoverPresented = false
          }
        },
        renameConversation: { conversationID, title in
          _ = ai.renameChatConversation(conversationID, title: title)
        },
        archiveConversation: { conversationID in
          _ = ai.archiveChatConversation(conversationID)
        },
        restoreConversation: { conversationID in
          _ = ai.restoreChatConversation(conversationID)
        },
        deleteConversation: { conversationID in
          _ = ai.deleteChatConversation(conversationID)
        }
      )
    }
  }

  var configurationRow: some View {
    DisclosureGroup(isExpanded: $isAdvancedSettingsExpanded) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          contextSelectionMenu
          modelQuickSwitchButton
          Spacer(minLength: 0)
          assistantOptionsMenu
        }

        HStack(spacing: 6) {
          contextReferenceMenu
          Text(String(localized: "选择本次发送给 AI 的额外上下文"))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }

        Divider()

        quickActionChips
      }
      .padding(.top, 4)
    } label: {
      Label(String(localized: "高级设置"), systemImage: "slider.horizontal.3")
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  var contextSelectionMenu: some View {
    Menu {
      Picker("上下文", selection: contextModeBinding) {
        ForEach(AIPublishingChatContextMode.allCases) { mode in
          Text(mode.localizedDisplayNameKey).tag(mode)
        }
      }
    } label: {
      HStack(spacing: 5) {
        Label(
          AIChatInspectorHeaderPresentation.contextTitle(for: ai.chatContextMode),
          systemImage: ai.chatContextMode.systemImage
        )
        .lineLimit(1)

        Image(systemName: "chevron.down")
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 6)
      .frame(minHeight: 24)
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .help(ai.chatContextMode.detail)
    .accessibilityLabel(String(localized: "上下文"))
    .accessibilityValue(ai.chatContextMode.localizedDisplayName)
  }

  var modelQuickSwitchButton: some View {
    Button {
      isModelQuickSwitchPresented = true
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "cpu")
          .foregroundStyle(WorkbenchTheme.primary)

        VStack(alignment: .leading, spacing: 1) {
          Text(providerMenuTitle)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(activeModelTitle)
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Image(systemName: "chevron.down")
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 6)
      .frame(minHeight: 24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(modelSelection == nil)
    .help(modelMenuSummary)
    .accessibilityLabel(String(localized: "AI 模型"))
    .accessibilityValue(modelMenuSummary)
    .accessibilityIdentifier("ai-assistant-model-quick-switch")
  }

  var assistantOptionsMenu: some View {
    Menu {
      if supportsSelectableReasoningLevel {
        Picker(String(localized: "思考级别"), selection: reasoningLevelBinding) {
          ForEach(AIChatReasoningLevel.allCases) { level in
            Text(localizedReasoningLevelTitle(level)).tag(level)
          }
        }

        Divider()
      }

      Picker("资料库", selection: knowledgePolicyBinding) {
        ForEach(KnowledgeRetrievalPolicy.allCases) { policy in
          Text(localizedKnowledgePolicyTitle(policy)).tag(policy)
        }
      }

      Divider()

      Menu(String(localized: "自定义指令")) {
        if ai.chatCustomPrompts.isEmpty {
          Text("尚未保存自定义指令")
        } else {
          ForEach(ai.chatCustomPrompts) { prompt in
            Menu(prompt.title) {
              Button {
                inputText = prompt.prompt
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
          inputText = "请帮我将当前文章全文翻译为英文，并创建关联新草稿；不要覆盖原稿。"
          focusComposerIfAvailable()
        }
        Button("创建简体中文翻译草稿") {
          inputText = "请帮我将当前文章全文翻译为简体中文，并创建关联新草稿；不要覆盖原稿。"
          focusComposerIfAvailable()
        }
      }

      Divider()

      Button {
        openAISettings()
      } label: {
        Label("打开 AI 设置", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "gearshape")
        .frame(width: 28, height: 24)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .help("AI 助手设置")
    .accessibilityLabel("AI 助手设置")
  }

  var quickActionChips: some View {
    HStack(spacing: 6) {
      ForEach(AIPublishingChatQuickAction.allCases) { action in
        Button {
          inputText = action.localizedPrompt
          isComposerFocused = true
        } label: {
          Label {
            Text(action.localizedCompactDisplayNameKey)
          } icon: {
            Image(systemName: action.systemImage)
          }
          .font(.workbenchMetadata.weight(.medium))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .center)
          .background(Color.primary.opacity(0.06), in: Capsule())
          .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(action.localizedDisplayName)
      }
    }
    .padding(.horizontal, 2)
    .padding(.bottom, 4)
  }

  var reasoningLevelBinding: Binding<AIChatReasoningLevel> {
    Binding(
      get: { ai.chatReasoningLevel },
      set: { ai.setChatReasoningLevel($0) }
    )
  }

  var modelSelection: AIChatModelSelectionPresentation? {
    guard let draft = ai.selectedChatDraft else { return nil }
    return AIChatModelSelectionPresentationService.presentation(
      grade: ai.chatModelGrade,
      selectedModel: ai.chatSelectedModel,
      config: ai.chatProviderConfig(for: draft)
    )
  }

  var conversationNavigationTitle: String {
    AIChatInspectorHeaderPresentation.conversationTitle(state.draft?.conversationTitle)
  }

  var currentAIProviderConfig: AIProviderConfig {
    guard let draft = ai.selectedChatDraft else { return AIProviderConfig() }
    return ai.chatProviderConfig(for: draft)
  }

  var providerMenuTitle: String {
    guard ai.selectedChatDraft != nil else { return String(localized: "选择模型") }
    return AIChatInspectorHeaderPresentation.providerTitle(for: currentAIProviderConfig)
  }

  var activeModelTitle: String {
    modelSelection?.activeModel.nilIfEmpty ?? String(localized: "未选择")
  }

  var modelMenuSummary: String {
    guard ai.selectedChatDraft != nil else { return String(localized: "未选择") }
    return AIChatInspectorHeaderPresentation.modelSummary(
      for: currentAIProviderConfig,
      activeModel: modelSelection?.activeModel
    )
  }

  var supportsSelectableReasoningLevel: Bool {
    AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
      config: currentAIProviderConfig,
      hasDraft: ai.selectedChatDraft != nil
    )
  }

  func localizedReasoningLevelTitle(_ level: AIChatReasoningLevel) -> String {
    switch level {
    case .quick:
      return String(localized: "快速")
    case .standard:
      return String(localized: "标准")
    case .deep:
      return String(localized: "深度")
    }
  }

  func localizedKnowledgePolicyTitle(_ policy: KnowledgeRetrievalPolicy) -> String {
    switch policy {
    case .off:
      return String(localized: "关闭资料库")
    case .automatic:
      return String(localized: "自动检索")
    case .pinnedOnly:
      return String(localized: "仅固定资料")
    }
  }

  func openAISettings() {
    requestedSettingsTabID = SettingsTab.ai.id
    openSettings()
  }

  var contextModeBinding: Binding<AIPublishingChatContextMode> {
    Binding(
      get: { ai.chatContextMode },
      set: { ai.setChatContextMode($0) }
    )
  }

  var knowledgePolicyBinding: Binding<KnowledgeRetrievalPolicy> {
    Binding(
      get: { ai.chatKnowledgePolicy },
      set: { ai.setChatKnowledgePolicy($0) }
    )
  }
}
