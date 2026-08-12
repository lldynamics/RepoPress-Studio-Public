import Foundation

extension WorkbenchAIStore {
  private var generalConversationScopeKey: String {
    AIConversationScope.general.storageKey
  }

  func activeConversationID(for scope: AIConversationScope) -> UUID? {
    switch scope {
    case let .draft(draftID):
      return activeAIConversationIDsByDraftID[draftID]
    case .general:
      return activeAIConversationIDsByScope[generalConversationScopeKey]
    }
  }

  func activateMostRecentGeneralAIChatConversation() {
    guard let conversation = generalAIChatConversations().first else {
      activeAIConversationIDsByScope.removeValue(forKey: generalConversationScopeKey)
      return
    }
    activeAIConversationIDsByScope[generalConversationScopeKey] = conversation.id
  }

  public func generalAIChatConversations(
    includingArchived: Bool = false
  ) -> [AIConversation] {
    aiConversations
      .filter { conversation in
        conversation.scope == .general && (includingArchived || !conversation.isArchived)
      }
      .sorted {
        if $0.updatedAt != $1.updatedAt {
          return $0.updatedAt > $1.updatedAt
        }
        return $0.createdAt > $1.createdAt
      }
  }

  public var activeGeneralAIChatConversationID: UUID? {
    guard let id = activeAIConversationIDsByScope[generalConversationScopeKey],
      let conversation = aiConversations.first(where: {
        $0.id == id && $0.scope == .general && !$0.isArchived
      })
    else { return nil }
    return conversation.id
  }

  public var activeGeneralAIChatConversation: AIConversation? {
    guard let id = activeGeneralAIChatConversationID else { return nil }
    return aiConversations.first { $0.id == id }
  }

  public var activeGeneralAIChatKnowledgePolicy: KnowledgeRetrievalPolicy {
    activeGeneralAIChatConversation?.knowledgePolicy ?? .automatic
  }

  public func generalAIChatConversation(
    withID conversationID: UUID,
    includingArchived: Bool = true
  ) -> AIConversation? {
    aiConversations.first {
      $0.id == conversationID
        && $0.scope == .general
        && (includingArchived || !$0.isArchived)
    }
  }

  @discardableResult
  public func startNewGeneralAIChatConversation(
    connectionProfileID: UUID? = nil
  ) -> AIConversation? {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再新建对话。"
      return nil
    }
    let connection: AIConnectionProfile
    if let connectionProfileID {
      guard let requestedConnection = store.aiConnectionProfile(for: connectionProfileID) else {
        aiChatMessage = "找不到指定的 AI 连接档案，未创建通用对话。"
        return nil
      }
      connection = requestedConnection
    } else {
      connection = store.activeAIConnectionProfile
    }
    let now = Date()
    let conversation = AIConversation(
      scope: .general,
      connectionProfileID: connection.id,
      contextMode: .general,
      createdAt: now
    )
    aiConversations.append(conversation)
    activeAIConversationIDsByScope[generalConversationScopeKey] = conversation.id
    aiGeneralChatManualRetryState = nil
    aiChatMessage = "已新建通用 AI 对话。"
    store.save()
    return conversation
  }

  @discardableResult
  public func selectGeneralAIChatConversation(_ conversationID: UUID) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换对话。"
      return false
    }
    guard let conversation = aiConversations.first(where: {
      $0.id == conversationID && $0.scope == .general && !$0.isArchived
    }) else {
      aiChatMessage = "找不到可切换的通用 AI 对话。"
      return false
    }
    activeAIConversationIDsByScope[generalConversationScopeKey] = conversation.id
    aiGeneralChatManualRetryState = nil
    aiChatMessage = "已切换通用 AI 对话。"
    store.save()
    return true
  }

  @discardableResult
  public func setGeneralAIChatConnectionProfile(
    _ connectionProfileID: UUID,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换连接档案。"
      return false
    }
    guard store.aiConnectionProfile(for: connectionProfileID) != nil else {
      return false
    }
    let resolvedID = conversationID ?? activeGeneralAIChatConversationID
    guard let resolvedID,
      let index = aiConversations.firstIndex(where: {
        $0.id == resolvedID && $0.scope == .general
      })
    else { return false }
    var updated = aiConversations
    updated[index].connectionProfileID = connectionProfileID
    updated[index].updatedAt = Date()
    aiConversations = updated
    aiChatMessage = "已切换通用 AI 连接档案。"
    store.save()
    return true
  }

  @discardableResult
  public func setGeneralAIChatModelGrade(
    _ modelGrade: AIChatModelGrade,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换模型。"
      return false
    }
    let resolvedID = conversationID ?? activeGeneralAIChatConversationID
    guard let resolvedID,
      updateGeneralConversation(resolvedID, update: { conversation in
        conversation.modelGrade = modelGrade
        if modelGrade != .custom {
          conversation.selectedModel = ""
        }
      }) != nil
    else { return false }
    aiChatMessage = "已切换通用 AI 模型。"
    store.save()
    return true
  }

  @discardableResult
  public func setGeneralAIChatKnowledgePolicy(
    _ policy: KnowledgeRetrievalPolicy,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换资料库策略。"
      return false
    }
    let resolvedID = conversationID ?? activeGeneralAIChatConversationID
    guard let resolvedID,
      updateGeneralConversation(resolvedID, update: { conversation in
        conversation.knowledgePolicy = policy
      }) != nil
    else { return false }
    aiChatMessage = "已切换通用 AI 资料库策略。"
    store.save()
    return true
  }

  public var activeGeneralAIChatReasoningLevel: AIChatReasoningLevel {
    activeGeneralAIChatConversation?.reasoningLevel ?? .deep
  }

  @discardableResult
  public func setGeneralAIChatReasoningLevel(
    _ level: AIChatReasoningLevel,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换思考级别。"
      return false
    }
    let resolvedID = conversationID ?? activeGeneralAIChatConversationID
    guard let resolvedID,
      updateGeneralConversation(resolvedID, update: { conversation in
        conversation.reasoningLevel = level
      }) != nil
    else { return false }
    aiChatMessage = "已切换通用 AI 思考级别。"
    store.save()
    return true
  }

  func aiChatAvailableAPIKey(for connection: AIConnectionProfile) throws -> String? {
    let config = connection.config
    let consent = aiDataSharingConsentStore.presentation(for: config)
    guard consent.isGranted else {
      throw AIPublishingAssistantError.dataSharingConsentRequired(
        providerName: consent.providerName,
        destination: consent.destination
      )
    }
    guard config.requiresAPIKey else { return nil }
    guard let token = try aiCredentialStore
      .token(forConnectionProfileID: connection.id)?.nilIfEmpty
    else {
      throw AIPublishingAssistantError.missingAPIKey
    }
    return token
  }

  func generalAIChatRequest(
    for conversation: AIConversation
  ) async -> AIChatRequest {
    let latestUserMessage = conversation.messages.last(where: { $0.role == .user })
    let explicitReferences = latestUserMessage?.contextReferences ?? []
    let explicitPrompt = await explicitGeneralAIChatContextPrompt(
      references: explicitReferences
    )
    let query = latestUserMessage?.content.trimmedForPublishing ?? ""
    let knowledgeContext: KnowledgeContextSnapshot?
    if query.isEmpty || conversation.knowledgePolicy == .off {
      knowledgeContext = nil
    } else {
      // General retrieval is driven by the user's question only. In
      // particular, no current draft, editor selection, repository or publish
      // status is read to enrich this query.
      knowledgeContext = await store.knowledge.context(
        query: query,
        policy: conversation.knowledgePolicy
      )
    }
    let envelope = AIContextAssembler.generalEnvelope(
      knowledgePolicy: conversation.knowledgePolicy,
      explicitContextReferences: explicitReferences,
      explicitContextPrompt: explicitPrompt,
      knowledgeContext: knowledgeContext
    )
    return AIChatRequest(
      messages: conversation.messages,
      context: envelope,
      modelGrade: conversation.modelGrade,
      reasoningLevel: conversation.reasoningLevel,
      selectedModel: conversation.selectedModel.nilIfEmpty
    )
  }

  @discardableResult
  public func sendGeneralAIChatMessage(
    _ text: String,
    conversationID: UUID? = nil,
    connectionProfileID: UUID? = nil,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    guard !Task.isCancelled else { return nil }
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatQuickHideOperationMessage())
      return nil
    }
    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty || !imageAttachments.isEmpty else {
      store.setAIChatMessage("请先输入要发送给 AI 的内容。")
      return nil
    }
    let selectedImageAttachments = Array(
      imageAttachments.prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    guard selectedImageAttachments.allSatisfy({ attachment in
      AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
        mimeType: attachment.mimeType,
        byteSize: Int64(attachment.data.count)
      )
    }) else {
      store.setAIChatMessage("图片附件仅支持 PNG、JPEG、GIF 或 WebP，且每张不能超过 10 MB。")
      return nil
    }

    let resolvedConversationID = conversationID ?? activeGeneralAIChatConversationID
    let conversation: AIConversation
    if let resolvedConversationID,
      let found = aiConversations.first(where: {
        $0.id == resolvedConversationID && $0.scope == .general && !$0.isArchived
      }) {
      conversation = found
    } else if let created = startNewGeneralAIChatConversation(
      connectionProfileID: connectionProfileID
    ) {
      conversation = created
    } else {
      return nil
    }

    guard let boundConnectionProfileID = conversation.connectionProfileID else {
      store.setAIChatMessage("当前通用对话没有绑定 AI 连接档案，请先选择有效档案。")
      return nil
    }
    if let connectionProfileID, connectionProfileID != boundConnectionProfileID {
      store.setAIChatMessage("当前通用对话的连接档案已变化，请先重新选择后再发送。")
      return nil
    }
    guard let connection = store.aiConnectionProfile(for: boundConnectionProfileID) else {
      store.setAIChatMessage("当前通用对话绑定的 AI 连接档案已不存在，请先重新绑定。")
      return nil
    }
    guard imageAttachments.isEmpty || connection.config.supportsImageInput else {
      store.setAIChatMessage(
        "\(connection.config.normalizedDisplayName) 当前接口不支持图片输入，请切换到支持视觉输入的模型。"
      )
      return nil
    }
    guard AIChatImageAttachmentBudget.canAppend(
      selectedImageAttachments,
      to: conversation.messages
    ) else {
      store.setAIChatMessage("本次图片会超过当前对话的 8 MB 总预算，请减少或移除图片后重试。")
      return nil
    }
    let token: String?
    do {
      token = try aiChatAvailableAPIKey(for: connection)
    } catch {
      store.setAIChatMessage("AI 通用对话失败：\(error.localizedDescription)")
      return nil
    }
    guard !Task.isCancelled else { return nil }
    guard let operationID = beginAIChatOperation(
      statusMessage: "AI 正在回复...",
      ownerToken: ownerToken
    ) else {
      return nil
    }

    activeAIConversationIDsByScope[generalConversationScopeKey] = conversation.id
    if let connectionProfileID,
      connectionProfileID != conversation.connectionProfileID {
      _ = setGeneralAIChatConnectionProfile(
        connectionProfileID,
        conversationID: conversation.id
      )
    }
    var updated = aiConversations
    guard let index = updated.firstIndex(where: { $0.id == conversation.id }) else {
      finishAIChatOperation(operationID)
      store.setAIChatMessage("无法保存当前 AI 对话，请重试。")
      return nil
    }
    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: trimmed,
      contextMode: .general,
      imageAttachments: selectedImageAttachments,
      contextReferences: approvedGeneralAIChatContextReferences(contextReferences)
    )
    guard !Task.isCancelled else {
      finishAIChatOperation(operationID)
      return nil
    }
    updated[index].messages.append(userMessage)
    updated[index].contextMode = .general
    updated[index].updatedAt = Date()
    aiConversations = updated
    store.save()

    return await generateGeneralAIChatReply(
      conversationID: conversation.id,
      operationID: operationID,
      config: connection.config,
      apiKey: token
    )
  }

  private func updateGeneralConversation(
    _ conversationID: UUID,
    update: (inout AIConversation) -> Void
  ) -> AIConversation? {
    var updated = aiConversations
    guard let index = updated.firstIndex(where: {
      $0.id == conversationID && $0.scope == .general
    }) else { return nil }
    update(&updated[index])
    updated[index].updatedAt = max(updated[index].updatedAt, Date())
    aiConversations = updated
    return aiConversations.first { $0.id == conversationID }
  }

  private func updateGeneralConversationMessages(
    _ conversationID: UUID,
    update: (inout [AIPublishingChatMessage]) -> Void
  ) {
    _ = updateGeneralConversation(conversationID) { conversation in
      update(&conversation.messages)
    }
  }

  private func generateGeneralAIChatReply(
    conversationID: UUID,
    operationID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async -> AIPublishingChatMessage? {
    defer { finishAIChatOperation(operationID) }
    guard let conversation = aiConversations.first(where: {
      $0.id == conversationID && $0.scope == .general
    }) else {
      store.setAIChatMessage("找不到当前通用 AI 对话。")
      return nil
    }
    let request = await generalAIChatRequest(for: conversation)
    do {
      try checkAIChatOperation(operationID)
      do {
        return try await generateStreamingGeneralAIChatReply(
          request: request,
          conversationID: conversationID,
          operationID: operationID,
          config: config,
          apiKey: apiKey
        )
      } catch AIChatCompletionClientError.streamingUnsupported {
        return try await generateCompleteGeneralAIChatReply(
          request: request,
          conversationID: conversationID,
          operationID: operationID,
          config: config,
          apiKey: apiKey
        )
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return aiConversations.first(where: { $0.id == conversationID })?.messages.last {
        $0.role == .assistant
      }
    } catch let error as AIChatCompletionClientError {
      configureGeneralManualRetry(for: error, conversationID: conversationID)
      store.setAIChatMessage("AI 通用对话失败：\(error.localizedDescription)")
      if error.didReceivePartialContent {
        return aiConversations.first(where: { $0.id == conversationID })?.messages.last {
          $0.role == .assistant
        }
      }
      return nil
    } catch {
      store.setAIChatMessage("AI 通用对话失败：\(error.localizedDescription)")
      return nil
    }
  }

  private func generateStreamingGeneralAIChatReply(
    request: AIChatRequest,
    conversationID: UUID,
    operationID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let replyStream = try await aiPublishingAssistantService.streamReply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    var assistantMessage = replyStream.initialMessage
    updateGeneralConversationMessages(conversationID) { $0.append(assistantMessage) }
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
      updateGeneralConversationMessages(conversationID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      nextPublishAt = clock.now.advanced(by: aiChatStreamPublishInterval)
    }

    do {
      for try await update in replyStream.updates {
        try checkAIChatOperation(operationID)
        pendingContent += update.contentDelta
        if let tokenUsage = update.tokenUsage { pendingTokenUsage = tokenUsage }
        flushPendingStreamUpdate(force: update.isFinished)
        if update.isFinished { break }
      }
      try checkAIChatOperation(operationID)
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else { throw AIChatCompletionClientError.emptyContent }
      assistantMessage.content = finalContent
      updateGeneralConversationMessages(conversationID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      store.setAIChatMessage("AI 已回复。")
      return assistantMessage
    } catch is CancellationError {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateGeneralConversationMessages(conversationID) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw CancellationError()
      }
      assistantMessage.content = finalContent
      updateGeneralConversationMessages(conversationID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      store.setAIChatMessage("AI 回复已停止。")
      return assistantMessage
    } catch let error as AIChatCompletionClientError where error.didReceivePartialContent {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateGeneralConversationMessages(conversationID) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw error
      }
      assistantMessage.content = finalContent
      updateGeneralConversationMessages(conversationID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      throw error
    } catch {
      updateGeneralConversationMessages(conversationID) { messages in
        messages.removeAll { $0.id == assistantMessage.id }
      }
      throw error
    }
  }

  private func generateCompleteGeneralAIChatReply(
    request: AIChatRequest,
    conversationID: UUID,
    operationID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let assistantMessage = try await aiPublishingAssistantService.reply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    updateGeneralConversationMessages(conversationID) { $0.append(assistantMessage) }
    store.setAIChatMessage("AI 已回复。")
    return assistantMessage
  }

  private func configureGeneralManualRetry(
    for error: AIChatCompletionClientError,
    conversationID: UUID
  ) {
    guard error.supportsManualRetry else {
      aiGeneralChatManualRetryState = nil
      return
    }
    aiGeneralChatManualRetryState = AIGeneralChatManualRetryState(
      conversationID: conversationID,
      requiresDuplicateChargeConfirmation: error.didReceivePartialContent,
      retryAfter: error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
    )
  }

  @discardableResult
  public func retryLastFailedGeneralAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    conversationID: UUID? = nil,
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    guard let retryState = aiGeneralChatManualRetryState else {
      store.setAIChatMessage("当前没有可重试的通用 AI 请求。")
      return nil
    }
    if let conversationID, retryState.conversationID != conversationID {
      store.setAIChatMessage("当前对话没有可重试的通用 AI 请求。")
      return nil
    }
    guard let conversation = aiConversations.first(where: {
      $0.id == retryState.conversationID && $0.scope == .general && !$0.isArchived
    }) else {
      store.setAIChatMessage("请先切回发生错误的通用 AI 对话，再重试回复。")
      return nil
    }
    if let retryAfter = retryState.retryAfter, retryAfter > Date() {
      let remainingSeconds = max(1, Int(ceil(retryAfter.timeIntervalSinceNow)))
      store.setAIChatMessage("服务器要求稍后重试，请等待约 \(remainingSeconds) 秒。")
      return nil
    }
    if retryState.requiresDuplicateChargeConfirmation,
      !confirmingPossibleDuplicateCharge
    {
      store.setAIChatMessage("已保留部分回复。再次生成可能产生重复内容和费用，请确认后手动重新生成。")
      return nil
    }
    guard let boundConnectionProfileID = conversation.connectionProfileID,
          let connection = store.aiConnectionProfile(for: boundConnectionProfileID) else {
      store.setAIChatMessage("当前通用对话绑定的 AI 连接档案已不存在，请先重新绑定。")
      return nil
    }
    let token: String?
    do {
      token = try aiChatAvailableAPIKey(for: connection)
    } catch {
      store.setAIChatMessage("AI 通用对话失败：\(error.localizedDescription)")
      return nil
    }
    guard let operationID = beginAIChatOperation(
      statusMessage: "AI 正在重新生成回复...",
      clearsManualRetryState: false,
      ownerToken: ownerToken
    ) else {
      return nil
    }

    // Do not destroy the partial assistant or retry state until every
    // preflight check and operation admission has succeeded.
    var updated = conversation
    if updated.messages.last?.role == .assistant {
      updated.messages.removeLast()
    }
    aiConversations = aiConversations.map { $0.id == updated.id ? updated : $0 }
    aiGeneralChatManualRetryState = nil

    let result = await generateGeneralAIChatReply(
      conversationID: conversation.id,
      operationID: operationID,
      config: connection.config,
      apiKey: token
    )
    let didCompleteRetry = result != nil
      && aiGeneralChatManualRetryState == nil
      && aiChatMessage == "AI 已回复。"
    if !didCompleteRetry {
      // Cancellation and non-retryable failure must not turn a retryable
      // partial response into an unrecoverable empty history. This also
      // restores the original partial response when a second retry receives
      // another partial stream before failing.
      aiConversations = aiConversations.map { $0.id == conversation.id ? conversation : $0 }
      aiGeneralChatManualRetryState = retryState
      store.save()
    }
    return result
  }
}
