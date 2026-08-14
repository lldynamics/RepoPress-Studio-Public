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

      Text("凭据独立保存")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(String(localized: "ai-assistant.configure")) {
        openAICredentialsSettings()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("未配置 API Key")
    .accessibilityHint("密钥按设置独立保存在受限本地配置、系统钥匙串或本次会话。")
  }

  var isAIKeyMissing: Bool {
    if ai.chatContextMode == .general {
      guard let connection = selectedGeneralConnectionProfile else { return true }
      return connection.config.requiresAPIKey
        && generalKeyAvailabilityByConnectionID[connection.id]?.hasToken != true
    }
    guard let draft = ai.selectedChatDraft else { return false }
    return ai.chatProviderConfig(for: draft).requiresAPIKey
      && !ai.tokenAvailability.hasToken
  }

  var inspectorHeader: some View {
    VStack(spacing: 8) {
      contextModePicker
      conversationNavigationRow
      configurationRow
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 助手")
    .accessibilityIdentifier("ai-assistant-inspector")
  }


  var conversationNavigationRow: some View {
    let conversationCount: Int
    if ai.chatContextMode == .general {
      conversationCount = ai.generalChatConversationsIncludingArchived.filter { !$0.isArchived }.count
    } else if let draft = ai.selectedChatDraft {
      conversationCount = ai.chatConversations(for: draft.id, includingArchived: false).count
    } else {
      conversationCount = 0
    }

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
      .disabled(ai.chatContextMode != .general && ai.selectedChatDraft == nil)
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

      if ai.chatContextMode == .general {
        generalConnectionAndModelMenu
      } else {
        AIChatConnectionStatusCapsule(
          ai: ai,
          chatState: chatState,
          draft: ai.selectedChatDraft
        ) {
          isModelQuickSwitchPresented = true
        }
      }

      Button {
        startNewInspectorConversation(draft: ai.selectedChatDraft)
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(
        isChatBusy
          || (ai.chatContextMode != .general && ai.selectedChatDraft == nil)
      )
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
      .disabled(isChatBusy)
      .help(String(localized: "关闭 AI 助手"))
      .accessibilityLabel(String(localized: "关闭 AI 助手"))
      .accessibilityIdentifier("ai-assistant-close")
    }
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
    } else if let draft = ai.selectedChatDraft {
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

  var contextModePicker: some View {
    Picker(String(localized: "上下文"), selection: contextModeBinding) {
      ForEach(AIPublishingChatContextMode.allCases) { mode in
        Text(AIChatInspectorHeaderPresentation.contextTitle(for: mode)).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 184, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(isChatBusy)
    .help(ai.chatContextMode.detail)
    .accessibilityLabel(String(localized: "上下文"))
    .accessibilityValue(AIChatInspectorHeaderPresentation.contextTitle(for: ai.chatContextMode))
    .accessibilityIdentifier("ai-assistant-context-mode")
  }

  @ViewBuilder
  var generalConnectionAndModelMenu: some View {
    let conversation = displayedGeneralConversation
    Menu {
      Section(String(localized: "连接配置档案")) {
        if ai.chatConnectionProfiles.isEmpty {
          Text(String(localized: "还没有可复用的连接档案。"))
        } else {
          ForEach(ai.chatConnectionProfiles) { profile in
            Button {
              guard let conversation else { return }
              _ = ai.setGeneralChatConnectionProfile(
                profile.id,
                conversationID: conversation.id
              )
            } label: {
              Label(
                profile.name,
                systemImage: conversation?.connectionProfileID == profile.id
                  ? "checkmark.circle.fill"
                  : "circle"
              )
            }
          }
        }
      }

      Section(String(localized: "模型档位")) {
        ForEach(AIChatModelGrade.allCases) { grade in
          Button {
            guard let conversation else { return }
            _ = ai.setGeneralChatModelGrade(
              grade,
              conversationID: conversation.id
            )
          } label: {
            Label(
              grade.title,
              systemImage: conversation?.modelGrade == grade
                ? "checkmark.circle.fill"
                : "circle"
            )
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "cpu")
          .foregroundStyle(WorkbenchTheme.primary)
        VStack(alignment: .leading, spacing: 1) {
          Text(selectedGeneralConnectionProfile?.name ?? String(localized: "连接档案已失效"))
            .font(.caption.weight(.semibold))
          Text(conversation?.modelGrade.title ?? String(localized: "未选择"))
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 138, alignment: .leading)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .disabled(isChatBusy || conversation == nil)
    .help(generalConnectionAndModelSummary)
    .accessibilityLabel(String(localized: "AI 连接与模型"))
    .accessibilityValue(generalConnectionAndModelSummary)
    .accessibilityIdentifier("ai-assistant-general-model-menu")
  }

  var configurationRow: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button {
        withAnimation(WorkbenchMotion.standard) {
          isAdvancedSettingsExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Label(String(localized: "上下文与来源"), systemImage: "scope")
            .font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          Image(
            systemName: isAdvancedSettingsExpanded
              ? "chevron.down"
              : "chevron.right"
          )
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isAdvancedSettingsExpanded ? "已展开" : "已折叠")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(Array(inspectorContextSourceItems.enumerated()), id: \.offset) { _, item in
            contextSourceChip(title: item.title, systemImage: item.systemImage)
          }
        }
      }

      if isAdvancedSettingsExpanded {
        Divider()

        HStack(spacing: 6) {
          Text(String(localized: "选择本次发送给 AI 的额外上下文"))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          assistantOptionsMenu
        }

        quickActionChips
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(
      Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  var inspectorContextSourceItems: [(title: String, systemImage: String)] {
    var items: [(title: String, systemImage: String)] = []

    if ai.chatContextMode == .site {
      items.append((
        AIChatInspectorHeaderPresentation.contextTitle(for: .site),
        "doc.text"
      ))
      if let title = ai.selectedChatDraft?.title.trimmedForPublishing.nilIfEmpty {
        items.append((title, "doc"))
      }
      items.append((String(localized: "站点上下文"), "globe"))
    } else if selectedContextReferences.isEmpty {
      items.append((
        String(localized: "不自动附加当前文章上下文"),
        "text.bubble"
      ))
    }

    items.append(contentsOf: selectedContextReferences.map { reference in
      (contextReferenceLabel(reference), "at")
    })

    let knowledgeTitle = localizedKnowledgePolicyTitle(knowledgePolicyBinding.wrappedValue)
    items.append(("\(String(localized: "资料库")) · \(knowledgeTitle)", "books.vertical"))
    return items
  }

  func contextSourceChip(
    title: String,
    systemImage: String
  ) -> some View {
    Label {
      Text(verbatim: title)
        .lineLimit(1)
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.workbenchMetadata.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(WorkbenchBackgroundStyle.control, in: Capsule())
    .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
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
          setInputText(action.localizedPrompt)
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

  var conversationNavigationTitle: String {
    AIChatInspectorHeaderPresentation.conversationTitle(state.draft?.conversationTitle)
  }

  var displayedGeneralConversation: AIConversation? {
    ai.generalChatConversation(withID: inspectorSurfaceConversationID)
      ?? ai.activeGeneralChatConversation
  }

  var selectedGeneralConnectionProfile: AIConnectionProfile? {
    guard let connectionProfileID = displayedGeneralConversation?.connectionProfileID else {
      return nil
    }
    return ai.chatConnectionProfiles.first { $0.id == connectionProfileID }
  }

  func refreshDisplayedGeneralKeyAvailability() {
    guard ai.chatContextMode == .general,
      let connection = selectedGeneralConnectionProfile
    else { return }
    generalKeyAvailabilityByConnectionID[connection.id] = ai.keyAvailability(
      forConnectionProfileID: connection.id
    )
  }

  var generalKeyAvailabilityRefreshKey: AIChatGeneralKeyAvailabilityRefreshKey {
    AIChatGeneralKeyAvailabilityRefreshKey(
      connectionProfileID: displayedGeneralConversation?.connectionProfileID,
      providerConfig: selectedGeneralConnectionProfile?.config,
      activeTokenAvailability: ai.tokenAvailability
    )
  }

  var generalConnectionAndModelSummary: String {
    let profile = selectedGeneralConnectionProfile?.name
      ?? String(localized: "连接档案已失效")
    let model = displayedGeneralConversation?.modelGrade.title
      ?? String(localized: "未选择")
    return "\(profile) · \(model)"
  }

  var currentAIProviderConfig: AIProviderConfig {
    if ai.chatContextMode == .general {
      return selectedGeneralConnectionProfile?.config ?? AIProviderConfig()
    }
    guard let draft = ai.selectedChatDraft else { return AIProviderConfig() }
    return ai.chatProviderConfig(for: draft)
  }

  var supportsSelectableReasoningLevel: Bool {
    if ai.chatContextMode == .general {
      guard let config = selectedGeneralConnectionProfile?.config,
        displayedGeneralConversation != nil
      else { return false }
      return AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: config,
        hasDraft: true
      )
    }
    return AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
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
    requestedSettingsTabID = SettingsDestination.ai(.connection).id
    openSettings()
  }

  func openAICredentialsSettings() {
    requestedSettingsTabID = SettingsDestination.ai(.credentials).id
    openSettings()
  }

  var contextModeBinding: Binding<AIPublishingChatContextMode> {
    Binding(
      get: { ai.chatContextMode },
      set: { mode in
        guard mode != ai.chatContextMode, !isChatBusy else { return }
        ai.setChatContextMode(mode)
        synchronizeInspectorConversationForContextMode(mode)
      }
    )
  }

  var knowledgePolicyBinding: Binding<KnowledgeRetrievalPolicy> {
    Binding(
      get: {
        ai.chatContextMode == .general
          ? (displayedGeneralConversation?.knowledgePolicy ?? .automatic)
          : ai.chatKnowledgePolicy
      },
      set: {
        if ai.chatContextMode == .general {
          _ = ai.setGeneralChatKnowledgePolicy(
            $0,
            conversationID: displayedGeneralConversation?.id
          )
        } else {
          ai.setChatKnowledgePolicy($0)
        }
      }
    )
  }
}
