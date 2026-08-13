import Foundation

/// The native article agent runtime. This file intentionally owns only the
/// store wiring: the loop policy and the automation registry remain in their
/// dedicated services. Every model round is treated as an independent,
/// privacy-bound interactive request.
extension WorkbenchAIStore {
  func generateAgentAIChatReply(
    for chatDraft: ArticleDraft,
    conversationIdentity: AIChatConversationIdentity,
    operationID: UUID,
    initialRequest: AIPublishingChatRequest,
    initialProviderConfig: AIProviderConfig,
    initialTaskConfig: AIProviderConfig
  ) async -> AIPublishingChatMessage? {
    do {
      try checkAIChatOperation(operationID)

      let context = WorkbenchAIAgentContext(
        goal: initialRequest.messages.last(where: { $0.role == .user })?.content ?? "",
        currentDraft: initialRequest.draft,
        draftVersions: initialRequest.automationDraftVersions
      )
      let baseRequest = aiPublishingAssistantService.chatCompletionRequest(
        for: initialRequest,
        taskConfig: initialTaskConfig
      )
      let privacyService = AIOutboundPayloadPrivacyService()
      let loop = WorkbenchAIAgentLoopService(
        modelTransport: { [weak self] roundRequest in
          guard let self else { throw CancellationError() }
          return try await self.authorizedAgentModelCompletion(
            roundRequest,
            chatDraft: chatDraft,
            conversationIdentity: conversationIdentity,
            operationID: operationID,
            initialRequest: initialRequest,
            initialProviderConfig: initialProviderConfig,
            initialTaskConfig: initialTaskConfig,
            privacyService: privacyService
          )
        },
        readOnlyExecutor: { [weak self] invocation in
          guard let self else { throw CancellationError() }
          return try await self.executeAgentReadOnlyInvocation(
            invocation,
            operationID: operationID
          )
        }
      )

      let result = await loop.run(
        request: baseRequest,
        context: context,
        toolCallingSupport: initialTaskConfig.capabilitySupport(for: .toolCalling)
      )
      try checkAIChatOperation(operationID)

      switch result.termination {
      case .completed:
        let content = result.assistantText
          .joined(separator: "\n\n")
          .trimmedForPublishing
        guard !content.isEmpty else {
          store.setAIChatMessage("AI 讨论失败：AI 没有返回可显示的内容。")
          return nil
        }
        var assistantMessage = AIPublishingChatMessage(
          role: .assistant,
          content: content,
          model: initialTaskConfig.normalizedModel,
          contextMode: initialRequest.contextMode,
          knowledgeCitations: initialRequest.knowledgeContext?.citations ?? []
        )
        assistantMessage = aiPublishingAssistantService.preparingProtectedEdit(
          in: assistantMessage,
          request: initialRequest
        )
        try checkAIChatOperation(operationID)
        updateAIChatSession(for: conversationIdentity) { messages in
          messages.append(assistantMessage)
        }
        recordAIResponseBacklinks(message: assistantMessage, request: initialRequest)
        store.setAIChatMessage("AI 已回复。")
        return assistantMessage

      case .awaitingReview:
        guard let pendingPlan = result.pendingPlan else {
          store.setAIChatMessage("AI 讨论失败：未能生成可审阅的操作计划。")
          return nil
        }
        let content = result.assistantText
          .joined(separator: "\n\n")
          .trimmedForPublishing
        var assistantMessage = AIPublishingChatMessage(
          role: .assistant,
          content: content.isEmpty
            ? CoreL10n.text("AI 已生成一份待确认的应用内操作计划。")
            : content,
          model: initialTaskConfig.normalizedModel,
          contextMode: initialRequest.contextMode,
          knowledgeCitations: initialRequest.knowledgeContext?.citations ?? [],
          automationPlan: pendingPlan
        )
        assistantMessage = aiPublishingAssistantService.preparingProtectedEdit(
          in: assistantMessage,
          request: initialRequest
        )
        // Never attach a plan or a late model result after the operation was
        // cancelled or its draft/config context changed.
        try checkAIChatOperation(operationID)
        guard
          await isAgentContextCurrent(
            initialRequest: initialRequest,
            initialProviderConfig: initialProviderConfig,
            conversationIdentity: conversationIdentity,
            privacyService: privacyService
          )
        else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        updateAIChatSession(for: conversationIdentity) { messages in
          messages.append(assistantMessage)
        }
        recordAIResponseBacklinks(message: assistantMessage, request: initialRequest)
        store.setAIChatMessage("AI 已生成待确认操作计划。")
        return assistantMessage

      case .cancelled:
        store.setAIChatMessage("AI 回复已停止。")
        return nil

      case .capabilityUnavailable, .rejected, .limitReached, .modelTransportFailed:
        store.setAIChatMessage("AI 讨论失败：AI 操作回合未完成。")
        return nil
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return nil
    } catch let error as AIChatCompletionClientError {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
  }

  private func authorizedAgentModelCompletion(
    _ roundRequest: AIChatCompletionRequest,
    chatDraft: ArticleDraft,
    conversationIdentity: AIChatConversationIdentity,
    operationID: UUID,
    initialRequest: AIPublishingChatRequest,
    initialProviderConfig: AIProviderConfig,
    initialTaskConfig: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService
  ) async throws -> AIChatCompletionResult {
    try checkAIChatOperation(operationID)
    guard
      await isAgentContextCurrent(
        initialRequest: initialRequest,
        initialProviderConfig: initialProviderConfig,
        conversationIdentity: conversationIdentity,
        privacyService: privacyService
      )
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }

    let initialTransport = try aiPublishingAssistantService.prepareTransport(
      completion: roundRequest,
      taskConfig: initialTaskConfig,
      privacyService: privacyService,
      contextBindingValues: ["agent-round"]
    )
    let outcome = await AIOutboundPayloadApprovalBroker.shared.requestApproval(
      for: initialTransport.payload.preview,
      scopeID: conversationIdentity.conversationID
    )
    guard case .confirmed(let confirmation) = outcome else {
      throw AIOutboundPayloadConfirmationError.cancelled
    }
    try checkAIChatOperation(operationID)

    guard
      await isAgentContextCurrent(
        initialRequest: initialRequest,
        initialProviderConfig: initialProviderConfig,
        conversationIdentity: conversationIdentity,
        privacyService: privacyService
      )
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedConfig = privacyService.sanitizedProviderConfig(
      store.aiProviderConfig(for: initialRequest.profile)
    )
    guard refreshedConfig == initialProviderConfig else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedTaskConfig = try aiPublishingAssistantService.resolvedChatTaskConfig(
      for: initialRequest,
      config: refreshedConfig
    )
    guard refreshedTaskConfig == initialTaskConfig else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedTransport = try aiPublishingAssistantService.prepareTransport(
      completion: roundRequest,
      taskConfig: refreshedTaskConfig,
      privacyService: privacyService,
      contextBindingValues: ["agent-round"],
      now: initialTransport.payload.preview.createdAt,
      nonce: initialTransport.payload.preview.nonce
    )
    try privacyService.validate(
      confirmation: confirmation,
      prepared: refreshedTransport.payload
    )

    // Bind the expiry to the immutable prepared request before reading the
    // current credential and consuming the one-shot authorization. The client
    // has no replay/fallback path for interactive prepared requests.
    let authorizedTransport = refreshedTransport.bindingAuthorizationDeadline(
      refreshedTransport.payload.preview.expiresAt
    )
    let authorization = AIOutboundPayloadTransportAuthorization(
      confirmation: confirmation,
      prepared: authorizedTransport.payload,
      privacyService: privacyService
    )
    let token = try aiChatAvailableAPIKey(for: initialRequest.profile)
    try authorization.consume()
    try checkAIChatOperation(operationID)
    return try await aiPublishingAssistantService.completePreparedResult(
      authorizedTransport,
      apiKey: token
    )
  }

  private func executeAgentReadOnlyInvocation(
    _ invocation: WorkbenchAIAgentToolInvocation,
    operationID: UUID
  ) async throws -> WorkbenchAIAgentToolResult {
    try checkAIChatOperation(operationID)
    guard WorkbenchAutomationRegistry.descriptor(for: invocation.step.command)?.risk == .readOnly
    else {
      throw WorkbenchAutomationExecutionError.operationDidNotComplete(
        CoreL10n.text("非只读 AI 操作必须等待确认。")
      )
    }
    let plan = WorkbenchAutomationPlan(
      goal: CoreL10n.text("执行 AI 请求的只读工作台操作"),
      steps: [invocation.step],
      source: .agentLoop
    )
    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: store,
      onlyStepID: invocation.step.id,
      shouldCancel: { [weak self] in
        guard let self else { return true }
        return self.aiChatCancellationRequested() || Task.isCancelled
      }
    )
    try checkAIChatOperation(operationID)
    guard let record = result.record.steps.first else {
      return WorkbenchAIAgentToolResult(
        content: CoreL10n.text("只读操作没有返回结果。"),
        isError: true
      )
    }
    return WorkbenchAIAgentToolResult(
      content: String(record.message.prefix(4_000)),
      isError: record.status != .succeeded
    )
  }

  private func isAgentContextCurrent(
    initialRequest: AIPublishingChatRequest,
    initialProviderConfig: AIProviderConfig,
    conversationIdentity: AIChatConversationIdentity,
    privacyService: AIOutboundPayloadPrivacyService
  ) async -> Bool {
    store.flushDraftBodyEditorBuffer(for: initialRequest.draft.id)
    guard let currentDraft = store.drafts.first(where: { $0.id == initialRequest.draft.id }),
      privacyService.sanitizedDraft(currentDraft) == initialRequest.draft
    else {
      return false
    }
    guard store.profile(for: currentDraft) == initialRequest.profile else {
      return false
    }
    guard
      privacyService.sanitizedProviderConfig(
        store.aiProviderConfig(for: initialRequest.profile)
      ) == initialProviderConfig
    else {
      return false
    }
    guard let session = aiChatSessionState(for: conversationIdentity),
      privacyService.sanitizedChatMessages(session.messages) == initialRequest.messages,
      session.contextMode == initialRequest.contextMode,
      session.knowledgePolicy == initialRequest.knowledgePolicy,
      session.modelGrade == initialRequest.modelGrade,
      session.reasoningLevel == initialRequest.reasoningLevel,
      session.selectedModel.nilIfEmpty == initialRequest.selectedModel
    else {
      return false
    }
    let currentSelection = store.activeEditorSelection
    return privacyService.sanitizedEditorSelection(currentSelection)
      == initialRequest.editorSelection
  }
}
