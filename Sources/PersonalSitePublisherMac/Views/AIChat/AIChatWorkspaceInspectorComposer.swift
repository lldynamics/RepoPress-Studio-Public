import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum AIChatDataSharingConsentPolicy {
  static func requiresConfirmation(
    _ presentation: AIDataSharingConsentPresentation
  ) -> Bool {
    presentation.requiresConsent && !presentation.isGranted
  }

  static func requiresAccountSettingsRedirect(
    for config: AIProviderConfig,
    presentation: AIDataSharingConsentPresentation
  ) -> Bool {
    config.usesCodexAppServer
      && requiresConfirmation(presentation)
  }
}

extension AIChatContextInspectorView {

  var agentToolAvailability: AIChatAgentToolAvailability? {
    guard let mode = ai.conversationAgentMode(for: inspectorSurfaceConversationID) else {
      return nil
    }
    return AIChatAgentToolAvailabilityPresentation.availability(
      config: currentAIProviderConfig,
      conversationMode: mode
    )
  }

  @ViewBuilder
  var agentToolsUnavailableBanner: some View {
    if let availability = agentToolAvailability,
      let message = availability.message,
      let actionTitle = availability.actionTitle
    {
      HStack(alignment: .center, spacing: 10) {
        Label(message, systemImage: "wand.and.stars")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 8)

        Button(actionTitle) {
          switch availability {
          case .conversationTextOnly:
            _ = ai.setConversationAgentMode(
              .inheritConnection,
              conversationID: inspectorSurfaceConversationID
            )
          case .connectionDisabled, .draftCreationDenied, .capabilityUnknown,
            .capabilityUnsupported:
            openAISettings()
          case .available:
            break
          }
        }
        .controlSize(.small)
        .disabled(isChatBusy)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.orange.opacity(0.08))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("ai-assistant-agent-unavailable")
    }
  }

  var messageComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let status = inspectorStatusText {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(status)
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .accessibilityLabel("AI 状态")
            .accessibilityValue(status)

          Spacer(minLength: 0)

          if let requiresDuplicateChargeConfirmation =
            activeRetryRequiresDuplicateChargeConfirmation
          {
            if requiresDuplicateChargeConfirmation {
              Button(String(localized: "重新生成")) {
                isPartialRetryConfirmationPresented = true
              }
              .controlSize(.regular)
              .disabled(isChatBusy)
              .help(String(localized: "部分回复已保留；确认后才会重新发起请求"))
            } else {
              Button(String(localized: "手动重试")) {
                retryLastFailedReply(confirmingPossibleDuplicateCharge: false)
              }
              .controlSize(.regular)
              .disabled(isChatBusy)
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
          Text("AI 思考中…")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      }

      AIOutboundPayloadSummaryView(scopeID: inspectorSurfaceConversationID)

      VStack(alignment: .leading, spacing: 8) {
        if !selectedContextReferences.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            ScrollView(.horizontal, showsIndicators: true) {
              HStack(spacing: 6) {
                ForEach(selectedContextReferences) { reference in
                  selectedContextReferenceChip(reference)
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
          ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
              ForEach(selectedChatImageAttachments) { attachment in
                selectedImageAttachmentChip(attachment)
              }
            }
          }
          .accessibilityLabel("待发送图片")
        }

        ZStack(alignment: .topLeading) {
          if inputText.isEmpty {
            Text(
              ai.chatContextMode == .general
                ? String(localized: "开始通用聊天…")
                : String(localized: "询问当前文章…")
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.top, 7)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          }

          TextEditor(text: inspectorComposerTextBinding)
            .accessibilityLabel("AI 消息")
            .accessibilityIdentifier("ai-assistant-input")
            .accessibilityHint("输入问题；⌘Return 发送")
            .scrollContentBackground(.hidden)
            .font(.body)
            .disabled(isComposerInputUnavailable)
            .focused($isComposerFocused)
        }
        .frame(minHeight: 44, idealHeight: 72, maxHeight: 122)

        HStack(spacing: 8) {
          contextReferenceMenu

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
                setSelectedImageAttachmentIDs([])
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
              || isChatBusy
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
          .disabled(!isSending && (!canSubmitMessage || isChatBusyElsewhere))
          .help(
            isSending
              ? String(localized: "停止生成")
              : String(localized: "发送当前输入；也可以按 Command-Return")
          )
          .accessibilityLabel(
            isSending
              ? String(localized: "停止 AI 回复")
              : String(localized: "发送 AI 消息")
          )
          .accessibilityIdentifier("ai-assistant-send-button")
        }
      }
      .padding(9)
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
    }
    .padding(10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-assistant-composer")
  }

  var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var availableChatContextReferences: [AIContextReference] {
    if ai.chatContextMode == .general {
      return ai.availableGeneralChatContextReferences()
    }
    guard let draft = ai.selectedChatDraft else { return [] }
    return ai.availableChatContextReferences(for: draft)
  }

  var primaryChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter {
      $0.kind != .specifiedArticle && $0.kind != .knowledgeEntry
    }
  }

  var articleChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter { $0.kind == .specifiedArticle }
  }

  var knowledgeChatContextReferences: [AIContextReference] {
    availableChatContextReferences.filter { $0.kind == .knowledgeEntry }
  }

  var contextReferenceMenu: some View {
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
          setSelectedContextReferences([])
        }
      }
    } label: {
      Label(
        selectedContextReferences.isEmpty
          ? String(localized: "引用上下文")
          : "@ \(selectedContextReferences.count)",
        systemImage: "at"
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(availableChatContextReferences.isEmpty || isChatBusy)
    .help("明确选择本次发送给 AI 的文章、选区、站点配置或资料")
    .accessibilityLabel(String(localized: "引用上下文"))
    .accessibilityIdentifier("ai-assistant-context-menu")
  }

  func contextReferenceButton(
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

  func toggleContextReference(_ reference: AIContextReference) {
    var references = selectedContextReferences
    if let index = references.firstIndex(where: {
      sameContextReferenceTarget($0, reference)
    }) {
      references.remove(at: index)
      setSelectedContextReferences(references)
      return
    }
    guard references.count < 8 else {
      ai.setChatMessage("每次最多选择 8 项 @ 上下文。")
      return
    }
    references.append(reference)
    setSelectedContextReferences(references)
  }

  func removeContextReference(_ reference: AIContextReference) {
    var references = selectedContextReferences
    references.removeAll {
      sameContextReferenceTarget($0, reference)
    }
    setSelectedContextReferences(references)
  }

  func containsContextReference(_ reference: AIContextReference) -> Bool {
    selectedContextReferences.contains {
      sameContextReferenceTarget($0, reference)
    }
  }

  func sameContextReferenceTarget(
    _ lhs: AIContextReference,
    _ rhs: AIContextReference
  ) -> Bool {
    lhs.kind == rhs.kind
      && lhs.resourceID == rhs.resourceID
      && lhs.sourceRange == rhs.sourceRange
  }

  func contextReferenceLabel(_ reference: AIContextReference) -> String {
    AIChatContextReferencePresentation.label(for: reference)
  }

  @ViewBuilder
  func selectedContextReferenceChip(_ reference: AIContextReference) -> some View {
    let label = contextReferenceLabel(reference)
    HStack(spacing: 4) {
      Image(systemName: "at")
      Text(label)
        .lineLimit(1)
      Button {
        removeContextReference(reference)
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("移除上下文 \(label)")
    }
    .font(.caption)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.07), in: Capsule())
  }

  var availableChatImageAttachments: [DraftAttachment] {
    guard let draft = ai.selectedChatDraft else { return [] }
    return draft.attachments.filter { $0.mediaKind == .image }
  }

  var selectedChatImageAttachments: [DraftAttachment] {
    availableChatImageAttachments.filter {
      selectedImageAttachmentIDs.contains($0.id)
    }
  }

  @ViewBuilder
  func selectedImageAttachmentChip(_ attachment: DraftAttachment) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "photo")
      Text(attachment.originalFilename)
        .lineLimit(1)
      Button {
        removeSelectedImageAttachment(attachment.id)
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

  func removeSelectedImageAttachment(_ attachmentID: UUID) {
    var attachmentIDs = selectedImageAttachmentIDs
    attachmentIDs.remove(attachmentID)
    setSelectedImageAttachmentIDs(attachmentIDs)
  }

  var isComposerInputUnavailable: Bool {
    if ai.chatContextMode == .general {
      return ai.generalChatConversation(withID: inspectorSurfaceConversationID)?.isArchived == true
        || isChatBusy
    }
    return ai.selectedChatDraft == nil || isChatBusy
  }

  var canSubmitMessage: Bool {
    (!trimmedInput.isEmpty || !selectedImageAttachmentIDs.isEmpty)
      && !isComposerInputUnavailable
      && !isAIKeyMissing
  }

  func submitMessage() {
    guard let draft = ai.selectedChatDraft else { return }
    let message = trimmedInput
    guard !message.isEmpty || !selectedImageAttachmentIDs.isEmpty,
      !isChatBusy
    else { return }
    let config = currentAIProviderConfig
    let consent = ai.dataSharingConsent(for: config)
    if AIChatDataSharingConsentPolicy.requiresConfirmation(consent) {
      pendingDataSharingConsentConfig = config
      pendingDataSharingConsentPresentation = consent
      isDataSharingConsentConfirmationPresented = true
      return
    }
    startSending(message, draft: draft, clearsComposerOnAccept: true)
  }

  func grantPendingDataSharingConsentAndSubmit() {
    guard let config = pendingDataSharingConsentConfig else { return }
    guard !config.usesCodexAppServer else {
      openCodexAccountSettingsForConsent()
      return
    }
    ai.grantDataSharingConsent(for: config, enablingRemoteAI: true)
    clearPendingDataSharingConsent()
    submitMessage()
  }

  func openCodexAccountSettingsForConsent() {
    clearPendingDataSharingConsent()
    SettingsNavigation.present(
      destination: .ai(.connection),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }

  func clearPendingDataSharingConsent() {
    pendingDataSharingConsentConfig = nil
    pendingDataSharingConsentPresentation = nil
    isDataSharingConsentConfirmationPresented = false
  }

  func toggleChatImageAttachment(_ attachmentID: UUID) {
    var attachmentIDs = selectedImageAttachmentIDs
    if attachmentIDs.remove(attachmentID) != nil {
      setSelectedImageAttachmentIDs(attachmentIDs)
      return
    }
    guard
      attachmentIDs.count
        < AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount
    else {
      ai.setChatMessage(
        "每次最多发送 \(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount) 张图片。"
      )
      return
    }
    attachmentIDs.insert(attachmentID)
    setSelectedImageAttachmentIDs(attachmentIDs)
  }

  func saveCurrentInputAsCustomPrompt() {
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

  var ownsInspectorOperation: Bool {
    AIChatSurfaceOperationOwnershipPolicy.ownsLocalTask(
      localTaskExists: operationSession.hasActiveTask,
      ownerToken: operationSession.activeOwnerToken
    )
  }

  var isSending: Bool {
    ownsInspectorOperation
  }

  var isChatBusy: Bool {
    operationSession.hasActiveTask || ai.isChatRunning
  }

  var isChatBusyElsewhere: Bool {
    isChatBusy && !ownsInspectorOperation
  }

  var inspectorStatusText: String? {
    if isChatBusyElsewhere {
      return String(localized: "AI 正在其他界面处理，本界面暂时不能发送。")
    }
    return ai.chatMessage?.nilIfEmpty
  }

  var activeManualRetryState: AIChatManualRetryState? {
    guard ai.chatContextMode != .general else { return nil }
    guard let draftID = ai.selectedChatDraft?.id,
      let retryState = ai.chatManualRetryState,
      retryState.draftID == draftID,
      retryState.conversationID == ai.activeChatConversationID(for: draftID)
    else {
      return nil
    }
    return retryState
  }

  var activeGeneralManualRetryState: AIGeneralChatManualRetryState? {
    guard ai.chatContextMode == .general,
      let retryState = ai.generalChatManualRetryState,
      retryState.conversationID == inspectorSurfaceConversationID
    else {
      return nil
    }
    return retryState
  }

  var activeRetryRequiresDuplicateChargeConfirmation: Bool? {
    activeManualRetryState?.requiresDuplicateChargeConfirmation
      ?? activeGeneralManualRetryState?.requiresDuplicateChargeConfirmation
  }

  func handleSendButton() {
    if isSending {
      stopSending()
    } else if !isChatBusyElsewhere {
      submitMessage()
    }
  }

}

extension AIChatContextInspectorView {
  var inspectorSurfaceConversationID: UUID {
    if let selectedConversationID = surfaceState.selectedConversationID {
      return selectedConversationID
    }
    if ai.chatContextMode == .general,
      let activeConversationID = ai.activeGeneralChatConversationID
    {
      return activeConversationID
    }
    if let draftID = ai.selectedChatDraft?.id,
      let activeConversationID = ai.activeChatConversationID(for: draftID)
    {
      return activeConversationID
    }
    return ai.selectedChatDraft?.id ?? inspectorTransientConversationID
  }

  var inputText: String {
    surfaceState.composerText(for: inspectorSurfaceConversationID)
  }

  var inspectorComposerTextBinding: Binding<String> {
    Binding(
      get: { inputText },
      set: { setInputText($0) }
    )
  }

  var selectedContextReferences: [AIContextReference] {
    surfaceState.contextReferences(for: inspectorSurfaceConversationID)
  }

  var selectedImageAttachmentIDs: Set<UUID> {
    surfaceState.imageAttachmentIDs(for: inspectorSurfaceConversationID)
  }

  func updateInspectorSurfaceState(
    _ update: (inout AIChatSurfaceState) -> Void
  ) {
    var updatedState = $surfaceState.wrappedValue
    update(&updatedState)
    $surfaceState.wrappedValue = updatedState
  }

  func setInputText(_ text: String) {
    let conversationID = inspectorSurfaceConversationID
    updateInspectorSurfaceState { state in
      state.setComposerText(text, for: conversationID)
    }
  }

  func setSelectedContextReferences(_ references: [AIContextReference]) {
    let conversationID = inspectorSurfaceConversationID
    updateInspectorSurfaceState { state in
      state.setContextReferences(references, for: conversationID)
    }
  }

  func setSelectedImageAttachmentIDs(_ attachmentIDs: Set<UUID>) {
    let conversationID = inspectorSurfaceConversationID
    updateInspectorSurfaceState { state in
      state.setImageAttachmentIDs(attachmentIDs, for: conversationID)
    }
  }

  func setInspectorSurfaceConversationID(_ conversationID: UUID?) {
    var updatedState = $surfaceState.wrappedValue
    updatedState.selectedConversationID = conversationID
    $surfaceState.wrappedValue = updatedState
  }

  func ensureInspectorSurfaceConversationSelection() {
    if ai.chatContextMode == .general {
      if let selectedConversationID = surfaceState.selectedConversationID,
        ai.generalChatConversation(
          withID: selectedConversationID,
          includingArchived: false
        ) != nil
      {
        return
      }
    } else if let draftID = ai.selectedChatDraft?.id {
      if let selectedConversationID = surfaceState.selectedConversationID,
        ai.chatConversations(for: draftID).contains(where: {
          $0.id == selectedConversationID
        })
      {
        return
      }
    }
    synchronizeInspectorSurfaceWithActiveConversation()
  }

  func synchronizeInspectorSurfaceWithActiveConversation(
    discarding discardedConversationID: UUID? = nil
  ) {
    var updatedState = $surfaceState.wrappedValue
    if let discardedConversationID {
      updatedState.discardState(for: discardedConversationID)
    }
    if ai.chatContextMode == .general {
      updatedState.selectedConversationID =
        ai.activeGeneralChatConversationID ?? inspectorTransientConversationID
    } else if let draftID = ai.selectedChatDraft?.id {
      updatedState.selectedConversationID =
        ai.activeChatConversationID(for: draftID) ?? draftID
    } else {
      updatedState.selectedConversationID = inspectorTransientConversationID
    }
    $surfaceState.wrappedValue = updatedState
  }

  func synchronizeInspectorConversationForContextMode(
    _ mode: AIPublishingChatContextMode
  ) {
    switch mode {
    case .general:
      let conversation =
        ai.activeGeneralChatConversation
        ?? ai.startNewGeneralChatConversation(
          connectionProfileID: ai.activeChatConnectionProfile.id
        )
      setInspectorSurfaceConversationID(
        conversation?.id ?? inspectorTransientConversationID
      )
    case .site:
      setInspectorSurfaceConversationID(nil)
      ensureInspectorSurfaceConversationSelection()
      synchronizeChatDraftWithSelection()
    }
    focusComposerIfAvailable()
  }

  @discardableResult
  func startNewInspectorConversation(draft: ArticleDraft?) -> AIConversation? {
    let conversation: AIConversation?
    if ai.chatContextMode == .general {
      conversation = ai.startNewGeneralChatConversation(
        connectionProfileID: ai.activeGeneralChatConnectionProfile.id
      )
    } else {
      conversation = ai.startNewChatConversation(draft: draft)
    }
    guard let conversation else {
      return nil
    }
    setInspectorSurfaceConversationID(conversation.id)
    return conversation
  }
}
