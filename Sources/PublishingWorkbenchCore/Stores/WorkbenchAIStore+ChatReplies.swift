import Foundation

extension WorkbenchAIStore {
  @discardableResult
  public func sendAIChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    ownerToken: UUID? = nil,
    expectedContextMode: AIPublishingChatContextMode? = nil,
    expectedDraftConversation: AIChatDraftConversationExpectation? = nil
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatQuickHideOperationMessage())
      return nil
    }

    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty || !imageAttachments.isEmpty else {
      store.setAIChatMessage(CoreL10n.text("请先输入要发送给 AI 的内容。"))
      return nil
    }
    guard expectedContextMode == nil || expectedContextMode == aiChatContextMode else {
      store.setAIChatMessage(
        CoreL10n.text("AI 对话上下文已变化，本次未发送，请重试。")
      )
      return nil
    }
    if let expectedDraftConversation {
      let expectedConversation = expectedDraftConversation.conversation
      guard
        aiChatContextMode != .general,
        let candidateDraft = draft ?? store.selectedDraft,
        candidateDraft.id == expectedDraftConversation.draftID,
        expectedConversation?.draftID == candidateDraft.id
          || expectedConversation == nil,
        activeAIChatConversation(for: candidateDraft.id) == expectedConversation
      else {
        store.setAIChatMessage(
          CoreL10n.text("AI 对话上下文已变化，本次未发送，请重试。")
        )
        return nil
      }
    }
    if aiChatContextMode == .general {
      return await sendGeneralAIChatMessage(
        trimmed,
        imageAttachments: imageAttachments,
        contextReferences: contextReferences,
        ownerToken: ownerToken
      )
    }
    let selectedImageAttachments = Array(
      imageAttachments.prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    guard
      selectedImageAttachments.allSatisfy({ attachment in
        AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
          mimeType: attachment.mimeType,
          byteSize: Int64(attachment.data.count)
        )
      })
    else {
      store.setAIChatMessage(
        CoreL10n.format(
          "图片附件仅支持 PNG、JPEG、GIF 或 WebP，且每张不能超过 %@。",
          AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()
        )
      )
      return nil
    }
    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage(CoreL10n.text("请先选择一篇文章。"))
      return nil
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: activeAIChatConversationID(for: chatDraft.id)
      )
    else {
      return nil
    }

    let profile = store.profile(for: chatDraft)
    let privacyService = AIOutboundPayloadPrivacyService()
    let config = privacyService.sanitizedProviderConfig(
      store.aiProviderConfig(for: profile)
    )
    guard imageAttachments.isEmpty || config.supportsImageInput else {
      store.setAIChatMessage(
        CoreL10n.format(
          "%@ 当前接口不支持图片输入，请切换到支持视觉输入的模型。",
          config.normalizedDisplayName
        )
      )
      return nil
    }

    do {
      _ = try aiChatAvailableAPIKey(for: profile)
    } catch {
      store.setAIChatMessage(CoreL10n.format("AI 讨论失败：%@", error.localizedDescription))
      return nil
    }
    guard
      let operationID = beginAIChatOperation(
        statusMessage: CoreL10n.text("AI 正在结合当前文章回复..."),
        ownerToken: ownerToken
      )
    else {
      return nil
    }

    prepareAIChat(for: chatDraft)

    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: trimmed,
      contextMode: store.aiChatContextMode,
      imageAttachments: selectedImageAttachments,
      contextReferences: approvedAIChatContextReferences(
        contextReferences,
        for: chatDraft
      )
    )
    var updatedMessages = aiChatMessages
    updatedMessages.append(userMessage)
    aiChatMessages = updatedMessages
    cacheCurrentAIChatSessionForAIStore()
    guard let conversationIdentity = aiChatConversationIdentity(for: chatDraft.id) else {
      finishAIChatOperation(operationID)
      store.setAIChatMessage(CoreL10n.text("无法保存当前 AI 对话，请重试。"))
      return nil
    }

    return await generateAIChatReply(
      for: chatDraft,
      conversationIdentity: conversationIdentity,
      operationID: operationID
    )
  }

  @discardableResult
  func generateAIChatReply(
    for chatDraft: ArticleDraft,
    conversationIdentity: AIChatConversationIdentity,
    operationID: UUID
  ) async -> AIPublishingChatMessage? {
    defer { finishAIChatOperation(operationID) }
    let profile = store.profile(for: chatDraft)
    let config = AIOutboundPayloadPrivacyService().sanitizedProviderConfig(
      store.aiProviderConfig(for: profile)
    )
    do {
      // Preflight availability without retaining a credential across authorization.
      _ = try aiChatAvailableAPIKey(for: profile)
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
    // Refresh locally derived request context before preview. There must be no
    // await that can change request state after authorization is prepared.
    await store.refreshSiteMaintenanceSnapshot()

    // Native tool-calling is selected from the same resolved task config that
    // the exact privacy transport will bind. Unknown and unsupported pairs
    // intentionally stay on the ordinary text path, which never declares
    // tools and never parses marker/JSON automation syntax.
    let agentCandidate = await assembledAIChatRequest(
      for: chatDraft,
      conversationIdentity: conversationIdentity,
      privacyService: AIOutboundPayloadPrivacyService()
    )
    let agentSettings = config.resolvedAdvancedSettings
    let conversationAllowsTools =
      aiConversationAgentMode(
        for: conversationIdentity.conversationID
      )?.effectiveAllowsTools(
        connectionAllowsTools: agentSettings.resolvedAllowsApplicationTools
      ) ?? false
    var allowedAgentCommands = WorkbenchAutomationRegistry.agentCommands(
      allowedBy: agentSettings.resolvedAgentPermissionPolicy,
      masterEnabled: conversationAllowsTools
    )
    if agentCandidate.knowledgePolicy != .automatic {
      allowedAgentCommands.subtract([.knowledgeSearch, .knowledgeRead])
    }
    if !allowedAgentCommands.isEmpty,
      let agentTaskConfig = try? aiPublishingAssistantService.resolvedChatTaskConfig(
        for: agentCandidate,
        config: config
      ), agentTaskConfig.capabilitySupport(for: .toolCalling) == .supported
    {
      return await generateAgentAIChatReply(
        for: chatDraft,
        conversationIdentity: conversationIdentity,
        operationID: operationID,
        initialRequest: agentCandidate,
        initialProviderConfig: config,
        initialTaskConfig: agentTaskConfig
      )
    }

    let attempt: AIAuthorizedPublishingChatAttempt
    do {
      attempt = try await aiChatRequest(
        for: chatDraft,
        conversationIdentity: conversationIdentity,
        transportConfig: config,
        initialRequest: agentCandidate
      )
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return nil
    } catch {
      store.setAIChatMessage(error.localizedDescription)
      return nil
    }
    do {
      try checkAIChatOperation(operationID)
    } catch {
      store.setAIChatMessage("AI 回复已停止。")
      return nil
    }
    do {
      // Re-check consent and read the current credential only after authorization.
      // The next call sends the exact automatically sanitized body; no fallback
      // or normalization is allowed to reuse this one-shot authorization.
      try await requireValidAIKnowledgeAuthorization(
        attempt.knowledgeAuthorizationBindings,
        policy: attempt.knowledgePolicy
      )
      // Knowledge authorization is bound to the approved payload and must be
      // checked before any later connection-state error can mask a revoked
      // explicit reference. Both checks remain before authorization consume
      // and before the transport boundary.
      let token = try aiChatAvailableAPIKey(for: profile)
      try attempt.authorization.consume()
      switch attempt.transport.preparedRequest.mode {
      case .streaming:
        return try await generateStreamingAIChatReply(
          transport: attempt.transport,
          conversationIdentity: conversationIdentity,
          operationID: operationID,
          apiKey: token
        )
      case .nonStreaming:
        return try await generateCompleteAIChatReply(
          transport: attempt.transport,
          conversationIdentity: conversationIdentity,
          operationID: operationID,
          apiKey: token
        )
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return aiChatSessionState(for: conversationIdentity)?
        .messages.last { $0.role == .assistant }
    } catch let error as AIChatCompletionClientError {
      configureManualRetry(for: error, conversationIdentity: conversationIdentity)
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      if error.didReceivePartialContent {
        return aiChatSessionState(for: conversationIdentity)?
          .messages.last { $0.role == .assistant }
      }
      return nil
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
  }

  private func generateStreamingAIChatReply(
    transport: AIPreparedPublishingChatTransport,
    conversationIdentity: AIChatConversationIdentity,
    operationID: UUID,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    guard let request = transport.publishingRequest else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let replyStream = try await aiPublishingAssistantService.streamPrepared(
      transport,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    var assistantMessage = replyStream.initialMessage
    updateAIChatSession(for: conversationIdentity) { messages in
      messages.append(assistantMessage)
    }
    let clock = ContinuousClock()
    var pendingContent = ""
    var pendingTokenUsage: AIChatTokenUsage?
    var nextPublishAt = clock.now.advanced(by: aiChatStreamPublishInterval)

    func flushPendingStreamUpdate(force: Bool = false) {
      guard !pendingContent.isEmpty || pendingTokenUsage != nil else { return }
      guard force || clock.now >= nextPublishAt else { return }

      assistantMessage.content += pendingContent
      pendingContent = ""
      if let tokenUsage = pendingTokenUsage {
        assistantMessage.tokenUsage = tokenUsage
        pendingTokenUsage = nil
      }
      updateAIChatSession(for: conversationIdentity, streaming: true) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      nextPublishAt = clock.now.advanced(by: aiChatStreamPublishInterval)
    }

    do {
      for try await update in replyStream.updates {
        try checkAIChatOperation(operationID)
        if !update.contentDelta.isEmpty {
          pendingContent += update.contentDelta
        }
        if let tokenUsage = update.tokenUsage {
          pendingTokenUsage = tokenUsage
        }
        flushPendingStreamUpdate(force: update.isFinished)
        if update.isFinished {
          break
        }
      }

      try checkAIChatOperation(operationID)

      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        throw AIChatCompletionClientError.emptyContent
      }
      let extraction = AIChatFollowUpSuggestionService.extractOrInferSuggestions(
        content: finalContent,
        draft: request.draft,
        hasAutomationPlan: assistantMessage.automationPlan != nil
      )
      assistantMessage.content = extraction.displayContent
      assistantMessage.followUpSuggestions = extraction.suggestions
      assistantMessage = aiPublishingAssistantService.preparingProtectedEdit(
        in: assistantMessage,
        request: request
      )
      updateAIChatSession(for: conversationIdentity) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      store.setAIChatMessage("AI 已回复。")
      return assistantMessage
    } catch is CancellationError {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateAIChatSession(for: conversationIdentity) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw CancellationError()
      }
      assistantMessage.content = finalContent
      updateAIChatSession(for: conversationIdentity) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      store.setAIChatMessage("AI 回复已停止。")
      return assistantMessage
    } catch let error as AIChatCompletionClientError where error.didReceivePartialContent {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateAIChatSession(for: conversationIdentity) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw error
      }
      assistantMessage.content = finalContent
      updateAIChatSession(for: conversationIdentity) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      throw error
    } catch {
      updateAIChatSession(for: conversationIdentity) { messages in
        messages.removeAll { $0.id == assistantMessage.id }
      }
      throw error
    }
  }

  private func generateCompleteAIChatReply(
    transport: AIPreparedPublishingChatTransport,
    conversationIdentity: AIChatConversationIdentity,
    operationID: UUID,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    guard let request = transport.publishingRequest else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    var assistantMessage = try await aiPublishingAssistantService.completePrepared(
      transport,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    let extraction = AIChatFollowUpSuggestionService.extractOrInferSuggestions(
      content: assistantMessage.content,
      draft: request.draft,
      hasAutomationPlan: assistantMessage.automationPlan != nil
    )
    assistantMessage.content = extraction.displayContent
    assistantMessage.followUpSuggestions = extraction.suggestions
    assistantMessage = aiPublishingAssistantService.preparingProtectedEdit(
      in: assistantMessage,
      request: request
    )
    updateAIChatSession(for: conversationIdentity) { messages in
      messages.append(assistantMessage)
    }
    recordAIResponseBacklinks(message: assistantMessage, request: request)
    store.setAIChatMessage("AI 已回复。")
    return assistantMessage
  }

  func recordAIResponseBacklinks(
    message: AIPublishingChatMessage,
    request: AIPublishingChatRequest
  ) {
    guard !message.knowledgeCitations.isEmpty else { return }
    store.knowledge.recordBacklinks(
      citations: message.knowledgeCitations,
      target: KnowledgeBacklinkTarget(
        kind: .aiResponse,
        id: message.id.uuidString,
        title: "AI 回复：\(request.draft.title)",
        location: message.createdAt.formatted(date: .abbreviated, time: .shortened)
      )
    )
  }

  private func configureManualRetry(
    for error: AIChatCompletionClientError,
    conversationIdentity: AIChatConversationIdentity
  ) {
    guard error.supportsManualRetry else {
      aiChatManualRetryState = nil
      return
    }
    aiChatManualRetryState = AIChatManualRetryState(
      draftID: conversationIdentity.draftID,
      conversationID: conversationIdentity.conversationID,
      requiresDuplicateChargeConfirmation: error.didReceivePartialContent,
      retryAfter: error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
    )
  }

  @discardableResult
  public func openAIChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    if let draftID {
      guard store.focusDraft(draftID, section: .writing) else {
        return false
      }
    } else if store.selectedDraftID == nil {
      _ = store.ensureEditableDraftSelected()
    }

    store.selectSection(.writing)

    guard let draft = store.selectedDraft else {
      pendingAIQuickPrompt = nil
      isAIPublishingAssistantPresented = false
      store.setInspectorPresented(false)
      return false
    }

    pendingAIQuickPrompt = quickPrompt
    prepareAIChat(for: draft)

    // Prepare the route before asking SwiftUI to present the Inspector. This
    // avoids briefly mounting the article Inspector and replacing it with the
    // AI Inspector in the same presentation transaction.
    isAIPublishingAssistantPresented = true
    store.setInspectorPresented(true)
    return true
  }

  public func consumePendingAIQuickPrompt() -> AIPublishingQuickPrompt? {
    let prompt = pendingAIQuickPrompt
    pendingAIQuickPrompt = nil
    return prompt
  }

  public func focusedAIChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    guard let focusedID = aiChatFocusedParagraphID?.nilIfEmpty else { return nil }
    return AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown).first {
      $0.id == focusedID
    }
  }

  public func showAIPublishingAssistant(for draftID: UUID? = nil) {
    _ = openAIChatWorkspace(for: draftID)
  }

  public func hideAIPublishingAssistant() {
    guard isAIPublishingAssistantPresented else { return }
    isAIPublishingAssistantPresented = false
  }

}
