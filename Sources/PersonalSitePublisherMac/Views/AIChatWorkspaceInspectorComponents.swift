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
  @State private var isConversationPopoverPresented = false
  @State private var isModelPopoverPresented = false
  @State private var isModelQuickSwitchPresented = false
  @State private var customModelInput = ""
  @State private var selectedImageAttachmentIDs: Set<UUID> = []
  @State private var selectedContextReferences: [AIContextReference] = []
  @State private var isAdvancedSettingsExpanded = false
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
                Label(
                  String(localized: "跳到最新"),
                  systemImage: "arrow.down.circle.fill"
                )
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
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 助手")
    .accessibilityIdentifier("ai-assistant-inspector")
    .onAppear {
      synchronizeChatDraftWithSelection()
      applyPendingQuickPrompt()
      focusComposerIfAvailable()
    }
    .onChange(of: ai.selectedChatDraft?.id) { _, _ in
      selectedImageAttachmentIDs = []
      selectedContextReferences = []
      synchronizeChatDraftWithSelection()
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
    .onChange(of: ai.activeChatConversationID) { _, _ in
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
    .sheet(isPresented: $isModelQuickSwitchPresented) {
      AIChatModelQuickSwitchSheet(
        ai: ai,
        draft: ai.selectedChatDraft
      )
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

  private var isAIKeyMissing: Bool {
    guard let draft = ai.selectedChatDraft else { return false }
    return ai.chatProviderConfig(for: draft).requiresAPIKey
      && !ai.tokenAvailability.hasToken
  }

  private var inspectorHeader: some View {
    VStack(spacing: 8) {
      conversationNavigationRow
      configurationRow
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @State private var isHeaderTitleHovered = false

  private var conversationNavigationRow: some View {
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
        synchronizeCustomModelInput()
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
    }
  }

  @ViewBuilder
  private var conversationPickerContent: some View {
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

  private var configurationRow: some View {
    DisclosureGroup(isExpanded: $isAdvancedSettingsExpanded) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          contextSelectionMenu
          modelSelectionPopoverButton
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

  private var contextSelectionMenu: some View {
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

  private var modelSelectionPopoverButton: some View {
    Button {
      synchronizeCustomModelInput()
      isModelPopoverPresented.toggle()
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
    .accessibilityIdentifier("ai-assistant-model-popover")
    .popover(isPresented: $isModelPopoverPresented, arrowEdge: .top) {
      modelSelectionPopoverContent
    }
  }

  private var modelSelectionPopoverContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("AI 模型", systemImage: "cpu")
          .font(.headline)
        Spacer()
        Button {
          isModelPopoverPresented = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help(String(localized: "关闭模型选择"))
        .accessibilityLabel(String(localized: "关闭模型选择"))
      }

      VStack(alignment: .leading, spacing: 5) {
        modelPopoverInfoRow(
          title: String(localized: "服务商"),
          value: providerMenuTitle
        )
        modelPopoverInfoRow(
          title: String(localized: "当前模型"),
          value: activeModelTitle
        )
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("常用档位")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        ForEach(modelGradeCandidates) { candidate in
          Button {
            ai.setChatModelGrade(candidate.grade)
            synchronizeCustomModelInput()
          } label: {
            HStack(spacing: 8) {
              Image(
                systemName: ai.chatModelGrade == candidate.grade
                  ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(
                ai.chatModelGrade == candidate.grade ? WorkbenchTheme.primary : Color.secondary
              )
              VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                  .font(.callout.weight(.medium))
                Text(candidate.model)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            String(
              format: String(localized: "%@ 模型"),
              candidate.title
            )
          )
          .accessibilityValue(candidate.model)
          .accessibilityAddTraits(
            ai.chatModelGrade == candidate.grade ? .isSelected : []
          )
        }

        Button {
          activateCustomModelEditing()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: ai.chatModelGrade == .custom ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(
                ai.chatModelGrade == .custom ? WorkbenchTheme.primary : Color.secondary
              )
            Text("自定义模型")
              .font(.callout.weight(.medium))
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
          ai.chatModelGrade == .custom ? .isSelected : []
        )
      }

      if AIChatInspectorHeaderPresentation.showsCustomModelInput(selection: modelSelection) {
        HStack(spacing: 8) {
          TextField("自定义模型", text: $customModelInput)
            .textFieldStyle(.roundedBorder)
            .onSubmit(applyCustomModelInput)
            .accessibilityLabel("自定义模型")

          Button(String(localized: "应用"), action: applyCustomModelInput)
            .disabled(trimmedCustomModelInput.isEmpty)
        }
        .accessibilityElement(children: .contain)
      }

      Divider()

      HStack(spacing: 8) {
        Button {
          ai.resetChatModelToProfileDefault()
          synchronizeCustomModelInput()
        } label: {
          Label(
            String(localized: "恢复站点默认模型"),
            systemImage: "arrow.counterclockwise"
          )
        }

        Spacer(minLength: 4)

        Button {
          isModelPopoverPresented = false
          openAISettings()
        } label: {
          Label("打开 AI 设置", systemImage: "gearshape")
        }
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 340)
  }

  private func modelPopoverInfoRow(
    title: String,
    value: String
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.caption.monospaced())
        .workbenchTruncatedIdentity(value)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }

  private var assistantOptionsMenu: some View {
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

      if isSending {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.workbenchMetadata)
            .foregroundStyle(Color.accentColor)
            .workbenchAIThinkingSymbolEffect(isActive: isSending)
          Text("AI 思考中...")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      }

      VStack(alignment: .leading, spacing: 10) {
        if !selectedContextReferences.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 6) {
                ForEach(selectedContextReferences) { reference in
                  HStack(spacing: 4) {
                    Image(systemName: "at")
                    Text(contextReferenceLabel(reference))
                      .lineLimit(1)
                    Button {
                      removeContextReference(reference)
                    } label: {
                      Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                      "移除上下文 \(contextReferenceLabel(reference))"
                    )
                  }
                  .font(.caption)
                  .padding(.horizontal, 7)
                  .padding(.vertical, 4)
                  .background(Color.primary.opacity(0.07), in: Capsule())
                }
              }
            }
            Text(
              AIChatContextReferencePresentation.summary(
                for: selectedContextReferences
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("本次 AI 上下文")
        }

        if !selectedChatImageAttachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(selectedChatImageAttachments) { attachment in
                HStack(spacing: 4) {
                  Image(systemName: "photo")
                  Text(attachment.originalFilename)
                    .lineLimit(1)
                  Button {
                    selectedImageAttachmentIDs.remove(attachment.id)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("移除图片 \(attachment.originalFilename)")
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: Capsule())
              }
            }
          }
          .accessibilityLabel("待发送图片")
        }

        TextField(
          String(localized: "询问当前文章…"),
          text: $inputText,
          axis: .vertical
        )
        .accessibilityLabel("AI 消息")
        .accessibilityIdentifier("ai-assistant-input")
        .textFieldStyle(.plain)
        .font(.body)
        .lineLimit(3...8)
        .disabled(isComposerInputUnavailable)
        .focused($isComposerFocused)

        HStack(spacing: 8) {
          Menu {
            if availableChatImageAttachments.isEmpty {
              Text(String(localized: "当前文章没有可发送的图片"))
            } else {
              ForEach(availableChatImageAttachments) { attachment in
                Button {
                  toggleChatImageAttachment(attachment.id)
                } label: {
                  Label(
                    attachment.originalFilename,
                    systemImage: selectedImageAttachmentIDs.contains(attachment.id)
                      ? "checkmark.circle.fill"
                      : "circle"
                  )
                }
              }
              Divider()
              Button(String(localized: "清空图片选择")) {
                selectedImageAttachmentIDs = []
              }
              .disabled(selectedImageAttachmentIDs.isEmpty)
            }
          } label: {
            Label(
              selectedImageAttachmentIDs.isEmpty
                ? String(localized: "添加图片")
                : String(localized: "图片 \(selectedImageAttachmentIDs.count)"),
              systemImage: "paperclip"
            )
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(
            ai.selectedChatDraft == nil
              || !currentAIProviderConfig.supportsImageInput
              || isSending
          )
          .help(
            currentAIProviderConfig.supportsImageInput
              ? String(localized: "选择当前文章图片并发送给视觉模型")
              : String(localized: "当前 AI 服务不支持图片输入")
          )

          Spacer(minLength: 8)

          Button(action: handleSendButton) {
            Label(
              isSending ? String(localized: "停止") : String(localized: "发送"),
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
          .help(
            isSending
              ? String(localized: "停止生成")
              : String(localized: "发送")
          )
          .accessibilityLabel(
            isSending
              ? String(localized: "停止 AI 回复")
              : String(localized: "发送 AI 消息")
          )
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
      .animation(WorkbenchMotion.quick, value: isComposerFocused)
    }
    .padding(12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-assistant-composer")
  }

  private var quickActionChips: some View {
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

  private var state: AIChatContextInspectorState {
    guard let draft = ai.selectedChatDraft else {
      return AIChatContextInspectorState(draft: nil)
    }

    let profile = ai.chatProfile(for: draft)
    let relationSuggestions = ai.relatedChatArticleSuggestions(for: draft, limit: 5)

    return AIChatContextInspectorState(
      draft: AIChatInspectorDraftContext(
        draft: draft,
        conversationTitle: AIPublishingChatConversationPresentation.displayTitle(
          conversationTitle: ai.chatConversationTitle,
          messages: ai.chatMessages,
          draft: draft,
          emptyTitle: String(localized: "AI 对话")
        ),
        messages: ai.chatDraftID == draft.id
          ? Array(ai.chatMessages.suffix(visibleMessageLimit)) : [],
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
        automationRunRecords: ai.automationRunRecords
      )
    )
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
      applyCodeBlock: { block, draft in
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown,
          to: draft,
          mode: .applyToCurrentEditor
        )
      },
      insertCodeBlockAtCursor: { block, draft in
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown,
          to: draft,
          mode: .insertAtCursor
        )
      },
      copyCodeBlock: { block in
        _ = ClipboardWriter.copy(
          block.fencedMarkdown,
          successMessage: String(localized: "已复制完整 Markdown 代码块。"),
          setMessage: { message in ai.setChatMessage(message) }
        )
      },
      branchConversation: { messageID, draft in
        _ = ai.branchChatConversation(after: messageID, draft: draft)
      },
      loadEarlierMessages: {
        loadEarlierMessages()
      },
      openCitation: { citation in
        _ = ai.openKnowledgeCitation(citation)
      },
      previewStructuredEdits: { message, review, draft in
        guard
          let current = ai.selectedChatDraft,
          current.id == draft.id,
          let updated = ai.reviewedStructuredEditDraft(
            message: message,
            review: review
          )
        else {
          return
        }
        draftDiffPreview = AIChatDraftDiffPreview(
          originalDraft: current,
          updatedDraft: updated,
          citations: [],
          applicationKind: .structuredEdit
        )
      },
      recordStructuredEditFeedback: { decision, proposal, model in
        ai.recordStructuredEditFeedback(
          decision,
          proposal: proposal,
          model: model
        )
      },
      createTranslationDraft: { plan in
        _ = ai.createLinkedTranslationDraft(from: plan)
      },
      localFeedbackDecision: { message in
        ai.localFeedbackDecision(for: message)
      },
      recordLocalFeedback: { decision, message in
        ai.recordLocalFeedback(decision, for: message)
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

  private var availableChatContextReferences: [AIContextReference] {
    guard let draft = ai.selectedChatDraft else { return [] }
    return ai.availableChatContextReferences(for: draft)
  }

  private var primaryChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter {
      $0.kind != .specifiedArticle && $0.kind != .knowledgeEntry
    }
  }

  private var articleChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter { $0.kind == .specifiedArticle }
  }

  private var knowledgeChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter { $0.kind == .knowledgeEntry }
  }

  private var contextReferenceMenu: some View {
    Menu {
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
          selectedContextReferences = []
        }
      }
    } label: {
      Label(
        selectedContextReferences.isEmpty
          ? String(localized: "@ 上下文")
          : "@ \(selectedContextReferences.count)",
        systemImage: "at"
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(ai.selectedChatDraft == nil || isSending)
    .help("明确选择本次发送给 AI 的文章、选区、站点配置或资料")
  }

  private func contextReferenceButton(
    _ reference: AIContextReference
  ) -> some View {
    Button {
      toggleContextReference(reference)
    } label: {
      Label(
        contextReferenceLabel(reference),
        systemImage: containsContextReference(reference)
          ? "checkmark.circle.fill"
          : "circle"
      )
    }
  }

  private func toggleContextReference(_ reference: AIContextReference) {
    if let index = selectedContextReferences.firstIndex(where: {
      sameContextReferenceTarget($0, reference)
    }) {
      selectedContextReferences.remove(at: index)
      return
    }
    guard selectedContextReferences.count < 8 else {
      ai.setChatMessage("每次最多选择 8 项 @ 上下文。")
      return
    }
    selectedContextReferences.append(reference)
  }

  private func removeContextReference(_ reference: AIContextReference) {
    selectedContextReferences.removeAll {
      sameContextReferenceTarget($0, reference)
    }
  }

  private func containsContextReference(_ reference: AIContextReference) -> Bool {
    selectedContextReferences.contains {
      sameContextReferenceTarget($0, reference)
    }
  }

  private func sameContextReferenceTarget(
    _ lhs: AIContextReference,
    _ rhs: AIContextReference
  ) -> Bool {
    lhs.kind == rhs.kind
      && lhs.resourceID == rhs.resourceID
      && lhs.sourceRange == rhs.sourceRange
  }

  private func contextReferenceLabel(_ reference: AIContextReference) -> String {
    AIChatContextReferencePresentation.label(for: reference)
  }

  private var availableChatImageAttachments: [DraftAttachment] {
    guard let draft = ai.selectedChatDraft else { return [] }
    return draft.attachments.filter { $0.mediaKind == .image }
  }

  private var selectedChatImageAttachments: [DraftAttachment] {
    availableChatImageAttachments.filter {
      selectedImageAttachmentIDs.contains($0.id)
    }
  }

  private var isComposerInputUnavailable: Bool {
    ai.selectedChatDraft == nil || isSending
  }

  private var canSubmitMessage: Bool {
    (!trimmedInput.isEmpty || !selectedImageAttachmentIDs.isEmpty)
      && !isComposerInputUnavailable
      && !isAIKeyMissing
  }

  private func submitMessage() {
    guard let draft = ai.selectedChatDraft else { return }
    let message = trimmedInput
    guard !message.isEmpty || !selectedImageAttachmentIDs.isEmpty,
      !isSending
    else { return }
    startSending(message, draft: draft, clearsComposerOnAccept: true)
  }

  private func toggleChatImageAttachment(_ attachmentID: UUID) {
    if selectedImageAttachmentIDs.remove(attachmentID) != nil {
      return
    }
    guard
      selectedImageAttachmentIDs.count
        < AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount
    else {
      ai.setChatMessage(
        "每次最多发送 \(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount) 张图片。"
      )
      return
    }
    selectedImageAttachmentIDs.insert(attachmentID)
  }

  private func saveCurrentInputAsCustomPrompt() {
    let prompt = trimmedInput
    guard !prompt.isEmpty else { return }
    let title =
      prompt
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .prefix(28) ?? Substring(String(localized: "自定义指令"))
    _ = ai.saveChatCustomPrompt(title: String(title), prompt: prompt)
  }

  private var isSending: Bool {
    isSubmitting || ai.isChatRunning
  }

  private var activeManualRetryState: AIChatManualRetryState? {
    guard let draftID = ai.selectedChatDraft?.id,
      let retryState = ai.chatManualRetryState,
      retryState.draftID == draftID,
      retryState.conversationID == ai.activeChatConversationID(for: draftID)
    else {
      return nil
    }
    return retryState
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
      config: ai.chatProviderConfig(for: draft)
    )
  }

  private var conversationNavigationTitle: String {
    AIChatInspectorHeaderPresentation.conversationTitle(state.draft?.conversationTitle)
  }

  private var currentAIProviderConfig: AIProviderConfig {
    guard let draft = ai.selectedChatDraft else { return AIProviderConfig() }
    return ai.chatProviderConfig(for: draft)
  }

  private var providerMenuTitle: String {
    guard ai.selectedChatDraft != nil else { return String(localized: "选择模型") }
    return AIChatInspectorHeaderPresentation.providerTitle(for: currentAIProviderConfig)
  }

  private var activeModelTitle: String {
    modelSelection?.activeModel.nilIfEmpty ?? String(localized: "未选择")
  }

  private var modelMenuSummary: String {
    guard ai.selectedChatDraft != nil else { return String(localized: "未选择") }
    return AIChatInspectorHeaderPresentation.modelSummary(
      for: currentAIProviderConfig,
      activeModel: modelSelection?.activeModel
    )
  }

  private var modelGradeCandidates: [AIChatInspectorModelGradeCandidate] {
    guard ai.selectedChatDraft != nil else { return [] }
    return AIChatInspectorHeaderPresentation.modelGradeCandidates(
      for: currentAIProviderConfig,
      currentModel: ai.chatSelectedModel
    )
  }

  private var trimmedCustomModelInput: String {
    customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var supportsSelectableReasoningLevel: Bool {
    AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
      config: currentAIProviderConfig,
      hasDraft: ai.selectedChatDraft != nil
    )
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

  private func openAISettings() {
    requestedSettingsTabID = SettingsTab.ai.id
    openSettings()
  }

  private func synchronizeCustomModelInput() {
    customModelInput =
      ai.chatSelectedModel.nilIfEmpty
      ?? modelSelection?.activeModel
      ?? ""
  }

  private func activateCustomModelEditing() {
    synchronizeCustomModelInput()
    ai.setChatModelGrade(.custom)
  }

  private func applyCustomModelInput() {
    let model = trimmedCustomModelInput
    guard !model.isEmpty else { return }
    customModelInput = model
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
    let requestedImageAttachmentIDs = selectedImageAttachmentIDs
    let requestedContextReferences = selectedContextReferences
    isSubmitting = true
    sendTask = Task {
      let imageAttachments = await ai.chatImageAttachments(
        for: draft,
        attachmentIDs: requestedImageAttachmentIDs
      )
      guard !Task.isCancelled else {
        isSubmitting = false
        sendTask = nil
        return
      }
      let reply = await ai.sendChatMessage(
        message,
        draft: draft,
        imageAttachments: imageAttachments,
        contextReferences: requestedContextReferences
      )
      let didAcceptUserMessage = ai.chatMessages.contains {
        !existingMessageIDs.contains($0.id) && $0.role == .user
      }
      if clearsComposerOnAccept,
        reply != nil || didAcceptUserMessage,
        trimmedInput == message
      {
        inputText = ""
        if selectedImageAttachmentIDs == requestedImageAttachmentIDs {
          selectedImageAttachmentIDs = []
        }
        if selectedContextReferences == requestedContextReferences {
          selectedContextReferences = []
        }
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
      context.totalMessageCount > context.messages.count
    else { return }
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

  private func synchronizeChatDraftWithSelection() {
    guard let draft = ai.selectedChatDraft,
      ai.chatDraftID != draft.id
    else { return }
    ai.prepareChat(for: draft)
  }

  private func scrollToLatestMessage(
    using proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard let latestMessageID else { return }
    DispatchQueue.main.async {
      if animated {
        withAnimation(WorkbenchMotion.standard) {
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
    guard
      let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
        content,
        to: draft,
        mode: .appendToBody
      )
    else {
      ai.setChatMessage(String(localized: "AI 回复为空，未应用。"))
      return
    }

    draftDiffPreview = AIChatDraftDiffPreview(
      originalDraft: draft,
      updatedDraft: result.draft,
      citations: message.knowledgeCitations
    )
    ai.setChatMessage(
      String(localized: "AI 修改预览已打开，接受后才会写入文章。")
    )
  }

  private func applyDraftDiffPreview(_ preview: AIChatDraftDiffPreview) {
    guard let current = ai.selectedChatDraft,
      AIChatDraftDiffApplicationPolicy.canApply(
        currentDraft: current,
        preview: preview
      )
    else {
      ai.setChatMessage(
        String(localized: "文章已变化，这份 AI 修改预览未应用；请重新预览。")
      )
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
      applicationSuccessMessage(for: preview)
    )
  }

  private func applicationSuccessMessage(
    for preview: AIChatDraftDiffPreview
  ) -> String {
    if preview.citationCount > 0 {
      return String(localized: "已追加 AI 回复并插入资料库脚注。")
    }
    switch preview.applicationKind {
    case .appendedReply:
      return String(localized: "已接受 AI 修改并追加到文章末尾。")
    case .structuredEdit:
      return String(localized: "已接受所选 AI 修改。")
    }
  }
}

private struct AIChatScrollBottomPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

struct AIChatContextInspectorContent: View {
  let state: AIChatContextInspectorState
  let actions: AIChatContextInspectorActions

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let draftContext = state.draft {
        AIChatConversationInspectorSection(context: draftContext, actions: actions)
        AIChatRelatedSuggestionsInspectorSection(context: draftContext, actions: actions)
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
      Text(verbatim: title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
