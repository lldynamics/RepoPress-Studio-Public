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
  @State private var customModelInput = ""
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
      synchronizeChatDraftWithSelection()
      applyPendingQuickPrompt()
      focusComposerIfAvailable()
    }
    .onChange(of: ai.selectedChatDraft?.id) { _, _ in
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

      Button("配置") {
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
    return ai.chatProfile(for: draft).aiProviderConfig.requiresAPIKey
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
    let conversationCount = ai.selectedChatDraft != nil ? ai.chatConversations(for: ai.selectedChatDraft!.id, includingArchived: false).count : 0

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
            .foregroundStyle(isHeaderTitleHovered ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.5))
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
        withAnimation(.easeOut(duration: 0.15)) {
          isHeaderTitleHovered = isHovered
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(ai.selectedChatDraft == nil)
      .help("点击切换对话历史（当前草稿共 \(conversationCount) 条对话）")
      .accessibilityLabel("当前对话")
      .accessibilityValue(conversationNavigationTitle)
      .accessibilityIdentifier("ai-assistant-conversation-picker")
      .popover(isPresented: $isConversationPopoverPresented, arrowEdge: .top) {
        conversationPickerContent
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
      .help("新对话")

      Button {
        ai.closeAssistantPanel()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.plain)
      .help("关闭 AI 助手")
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
    HStack(spacing: 6) {
      contextSelectionMenu

      modelSelectionPopoverButton

      Spacer(minLength: 0)

      assistantOptionsMenu
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    .accessibilityLabel("上下文")
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
    .accessibilityLabel("AI 模型")
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
        .help("关闭模型选择")
        .accessibilityLabel("关闭模型选择")
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
              Image(systemName: ai.chatModelGrade == candidate.grade ? "checkmark.circle.fill" : "circle")
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
          .accessibilityLabel("\(candidate.title)模型")
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
        Picker("思考级别", selection: reasoningLevelBinding) {
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

      quickActionChips

      if isSending {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.workbenchMetadata)
            .foregroundStyle(Color.accentColor)
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

  @State private var chipsDragOffset: CGFloat = 0
  @State private var chipsAccumulatedOffset: CGFloat = 0

  private var quickActionChips: some View {
    ZStack(alignment: .leading) {
      HStack(spacing: 6) {
        ForEach([
          ("✨ 润色全文", "请帮我润色优化整篇文章的表达，保持专业顺畅，纠正错别字与语病。"),
          ("🏷️ 提取标签", "请分析当前文章内容，推荐 3-5 个最精准的 Front-matter 标签和分类。"),
          ("📝 生成摘要", "请为当前文章生成一段 100 字左右吸睛的 SEO 简短摘要。"),
          ("🔍 检查错别字", "请检查当前草稿中是否有错别字、标点误用或病句，并逐一列出修正建议。"),
          ("🌐 翻译为英文", "请将当前文章的高光段落优雅地翻译为地道的英文表达。")
        ], id: \.0) { chip, prompt in
          Button {
            inputText = prompt
            isComposerFocused = true
          } label: {
            Text(chip)
              .font(.workbenchMetadata.weight(.medium))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.primary.opacity(0.06), in: Capsule())
              .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
          }
          .buttonStyle(.plain)
        }
      }
      .offset(x: chipsAccumulatedOffset + chipsDragOffset)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { value in
          chipsDragOffset = value.translation.width
        }
        .onEnded { value in
          let total = chipsAccumulatedOffset + value.translation.width
          chipsDragOffset = 0
          withAnimation(.easeOut(duration: 0.25)) {
            if total > 0 {
              chipsAccumulatedOffset = 0
            } else if total < -240 {
              chipsAccumulatedOffset = -240
            } else {
              chipsAccumulatedOffset = total
            }
          }
        }
    )
    .padding(.horizontal, 2)
    .padding(.bottom, 4)
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
      branchConversation: { messageID, draft in
        _ = ai.branchChatConversation(after: messageID, draft: draft)
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
          retryState.draftID == draftID,
          retryState.conversationID == ai.activeChatConversationID(for: draftID) else {
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
      config: ai.chatProfile(for: draft).aiProviderConfig
    )
  }

  private var conversationNavigationTitle: String {
    AIChatInspectorHeaderPresentation.conversationTitle(state.draft?.conversationTitle)
  }

  private var currentAIProviderConfig: AIProviderConfig {
    guard let draft = ai.selectedChatDraft else { return AIProviderConfig() }
    return ai.chatProfile(for: draft).aiProviderConfig
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
    customModelInput = ai.chatSelectedModel.nilIfEmpty
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

  private func synchronizeChatDraftWithSelection() {
    guard let draft = ai.selectedChatDraft,
          ai.chatDraftID != draft.id else { return }
    ai.prepareChat(for: draft)
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
