import Foundation

extension WorkbenchAIStore {
  func configureGeneralManualRetry(
    for error: AIChatCompletionClientError,
    conversationID: UUID,
    operationID: UUID
  ) {
    guard error.supportsManualRetry else {
      aiGeneralChatManualRetryState = nil
      return
    }
    aiGeneralChatManualRetryState = AIGeneralChatManualRetryState(
      conversationID: conversationID,
      operationID: operationID,
      requiresDuplicateChargeConfirmation: error.requiresDuplicateChargeConfirmation,
      retryAfter: error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
    )
  }

  func generateCompleteGeneralAIChatReply(
    attempt: AIAuthorizedGeneralChatAttempt,
    conversationID: UUID,
    operationID: UUID,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let config = attempt.providerConfig
    let connectionID = attempt.connectionProfileID
    let assistant = authorizedChatAssistant(
      operationID: operationID, config: config, connectionID: connectionID,
      knowledgeBindings: attempt.knowledgeAuthorizationBindings,
      knowledgePolicy: attempt.knowledgePolicy, apiKey: apiKey
    ) { [weak self] in
      guard let self else { throw CancellationError() }
      return try self.currentGeneralAIChatAPIKey(
        conversationID: conversationID, matching: config,
        connectionProfileID: connectionID
      )
    }
    let message = try await assistant.completePrepared(attempt.transport, apiKey: apiKey)
    try checkAIChatOperation(operationID)
    updateGeneralConversationMessages(conversationID) { $0.append(message) }
    store.setAIChatMessage("AI 已回复。")
    return message
  }

  func generateStreamingGeneralAIChatReply(
    attempt: AIAuthorizedGeneralChatAttempt,
    conversationID: UUID,
    operationID: UUID,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let providerConfig = attempt.providerConfig
    let connectionID = attempt.connectionProfileID
    let assistant = authorizedChatAssistant(
      operationID: operationID,
      config: providerConfig,
      connectionID: connectionID,
      knowledgeBindings: attempt.knowledgeAuthorizationBindings,
      knowledgePolicy: attempt.knowledgePolicy,
      apiKey: apiKey
    ) { [weak self] in
      guard let self else { throw CancellationError() }
      return try self.currentGeneralAIChatAPIKey(
        conversationID: conversationID,
        matching: providerConfig,
        connectionProfileID: connectionID
      )
    }
    let replyStream = try await assistant.streamPrepared(
      attempt.transport,
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
}
