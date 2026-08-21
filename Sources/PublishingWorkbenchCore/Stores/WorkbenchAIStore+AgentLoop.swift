import Foundation

/// `WorkbenchAIAgentLoopService` converts model-transport errors into a result
/// termination. Keep a small side channel so a revoked knowledge binding can
/// still use the dedicated zero-send cancellation path.
private final class AgentKnowledgeAuthorizationState: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  func markChanged() {
    lock.lock()
    changed = true
    lock.unlock()
  }

  var didChange: Bool {
    lock.lock()
    defer { lock.unlock() }
    return changed
  }
}

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
      let agentSettings = initialTaskConfig.resolvedAdvancedSettings
      let conversationAllowsTools = aiConversationAgentMode(
        for: conversationIdentity.conversationID
      )?.effectiveAllowsTools(
        connectionAllowsTools: agentSettings.resolvedAllowsApplicationTools
      ) ?? false
      var allowedCommands = WorkbenchAutomationRegistry.agentCommands(
        allowedBy: agentSettings.resolvedAgentPermissionPolicy,
        masterEnabled: conversationAllowsTools
      )
      if initialRequest.knowledgePolicy != .automatic {
        allowedCommands.subtract([.knowledgeSearch, .knowledgeRead])
      }
      let knowledgeAuthorizationState = AgentKnowledgeAuthorizationState()
      let loop = WorkbenchAIAgentLoopService(
        modelTransport: { [weak self] roundRequest in
          guard let self else { throw CancellationError() }
          do {
            try await self.validateAgentKnowledgeAuthorization(
              bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
              policy: initialRequest.knowledgePolicy,
              failureState: knowledgeAuthorizationState
            )
          } catch let error as AIOutboundPayloadConfirmationError
            where error == .knowledgeAuthorizationChanged
          {
            // The loop treats ordinary executor errors as failed tool
            // results and would otherwise issue another model round.
            throw CancellationError()
          }
          return try await self.authorizedAgentModelCompletion(
            roundRequest,
            chatDraft: chatDraft,
            conversationIdentity: conversationIdentity,
            operationID: operationID,
            initialRequest: initialRequest,
            initialProviderConfig: initialProviderConfig,
            initialTaskConfig: initialTaskConfig,
            privacyService: privacyService,
            knowledgeAuthorizationState: knowledgeAuthorizationState
          )
        },
        allowedCommands: allowedCommands,
        automaticExecutor: { [weak self] invocation in
          guard let self else { throw CancellationError() }
          guard
            await self.isAgentContextCurrent(
              initialRequest: initialRequest,
              initialProviderConfig: initialProviderConfig,
              conversationIdentity: conversationIdentity,
              privacyService: privacyService
            )
          else {
            throw AIOutboundPayloadConfirmationError.drifted
          }
          do {
            try await self.validateAgentKnowledgeAuthorization(
              bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
              policy: initialRequest.knowledgePolicy,
              failureState: knowledgeAuthorizationState
            )
          } catch let error as AIOutboundPayloadConfirmationError
            where error == .knowledgeAuthorizationChanged
          {
            throw CancellationError()
          }
          return try await self.executeAgentAutomaticInvocation(
            invocation,
            operationID: operationID,
            conversationID: conversationIdentity.conversationID
          )
        }
      )

      let result = await loop.run(
        request: baseRequest,
        context: context,
        toolCallingSupport: initialTaskConfig.capabilitySupport(for: .toolCalling)
      )
      try checkAIChatOperation(operationID)
      if knowledgeAuthorizationState.didChange {
        throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
      }

      switch result.termination {
      case .completed:
        let rawContent = result.assistantText
          .joined(separator: "\n\n")
          .trimmedForPublishing
        guard !rawContent.isEmpty else {
          store.setAIChatMessage("AI 讨论失败：AI 没有返回可显示的内容。")
          return nil
        }
        try await validateAgentKnowledgeAuthorization(
          bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
          policy: initialRequest.knowledgePolicy
        )
        let extraction = AIChatFollowUpSuggestionService.extractOrInferSuggestions(
          content: rawContent,
          draft: initialRequest.draft,
          hasAutomationPlan: false
        )
        var assistantMessage = AIPublishingChatMessage(
          role: .assistant,
          content: extraction.displayContent,
          model: initialTaskConfig.normalizedModel,
          contextMode: initialRequest.contextMode,
          knowledgeCitations: initialRequest.knowledgeContext?.citations ?? [],
          toolRuns: result.toolRuns,
          followUpSuggestions: extraction.suggestions
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
        guard let pendingPlan = result.pendingPlan,
          let checkpoint = result.checkpoint,
          let originConversation = aiConversations.first(where: {
            $0.id == conversationIdentity.conversationID
              && $0.draftID == conversationIdentity.draftID
          })
        else {
          store.setAIChatMessage("AI 讨论失败：未能生成可审阅的操作计划。")
          return nil
        }
        let rawContent = result.assistantText
          .joined(separator: "\n\n")
          .trimmedForPublishing
        try await validateAgentKnowledgeAuthorization(
          bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
          policy: initialRequest.knowledgePolicy
        )
        let extraction = AIChatFollowUpSuggestionService.extractOrInferSuggestions(
          content: rawContent,
          draft: initialRequest.draft,
          hasAutomationPlan: true
        )
        let assistantMessageID = UUID()
        let requestTemplate: AIChatCompletionRequest = {
          var template = baseRequest
          // The checkpoint owns the complete transcript. Keeping this request
          // shell message-free avoids persisting a second copy of the same
          // conversation and prevents a later resume from accidentally
          // appending a second trusted boundary.
          template.messages = []
          return template
        }()
        let continuation = AIPublishingChatAgentContinuation(
          ownerConversationID: conversationIdentity.conversationID,
          ownerScope: .draft(chatDraft.id),
          ownerMessageID: assistantMessageID,
          planID: pendingPlan.id,
          requestTemplate: requestTemplate,
          checkpoint: checkpoint,
          providerConfig: initialProviderConfig,
          taskConfig: initialTaskConfig,
          promptRevision: AIPublishingChatAgentPromptRevision(
            conversation: originConversation
          ),
          reviewDraftFingerprint: chatDraft.repositoryContentFingerprint,
          reviewDraftUpdatedAt: chatDraft.updatedAt,
          knowledgeAuthorizationBindings:
            initialRequest.knowledgeContext?.authorizationBindings ?? []
        )
        guard continuation.isValidForPersistence else {
          store.setAIChatMessage("AI 讨论失败：无法安全保存待确认操作。")
          return nil
        }
        var assistantMessage = AIPublishingChatMessage(
          id: assistantMessageID,
          role: .assistant,
          content: extraction.displayContent.isEmpty
            ? CoreL10n.text("AI 已生成一份待确认的应用内操作计划。")
            : extraction.displayContent,
          model: initialTaskConfig.normalizedModel,
          contextMode: initialRequest.contextMode,
          knowledgeCitations: initialRequest.knowledgeContext?.citations ?? [],
          toolRuns: result.toolRuns,
          agentContinuation: continuation,
          automationPlan: pendingPlan,
          followUpSuggestions: extraction.suggestions
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
        try await validateAgentKnowledgeAuthorization(
          bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
          policy: initialRequest.knowledgePolicy
        )
        updateAIChatSession(for: conversationIdentity) { messages in
          messages.append(assistantMessage)
        }
        recordAIResponseBacklinks(message: assistantMessage, request: initialRequest)
        if store.flushPendingChanges() {
          store.setAIChatMessage("AI 已生成待确认操作计划。")
        } else {
          store.setAIChatMessage(
            "AI 已生成待确认操作计划，但暂时无法安全保存；请勿退出应用。"
          )
        }
        return assistantMessage

      case .cancelled:
        store.setAIChatMessage("AI 回复已停止。")
        return nil

      case .capabilityUnavailable, .rejected, .limitReached, .modelTransportFailed:
        store.setAIChatMessage("AI 讨论失败：AI 操作回合未完成。")
        return nil
      }
    } catch let error as AIOutboundPayloadConfirmationError
      where error == .knowledgeAuthorizationChanged
    {
      store.setAIChatMessage(error.localizedDescription)
      return nil
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
    privacyService: AIOutboundPayloadPrivacyService,
    knowledgeAuthorizationState: AgentKnowledgeAuthorizationState? = nil
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
    try await validateAgentKnowledgeAuthorization(
      bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
      policy: initialRequest.knowledgePolicy,
      failureState: knowledgeAuthorizationState
    )

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
    try await validateAgentKnowledgeAuthorization(
      bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
      policy: initialRequest.knowledgePolicy,
      failureState: knowledgeAuthorizationState
    )
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
    try await validateAgentKnowledgeAuthorization(
      bindings: initialRequest.knowledgeContext?.authorizationBindings ?? [],
      policy: initialRequest.knowledgePolicy,
      failureState: knowledgeAuthorizationState
    )
    try authorization.consume()
    try checkAIChatOperation(operationID)
    return try await aiPublishingAssistantService.completePreparedResult(
      authorizedTransport,
      apiKey: token
    )
  }

  private func validateAgentKnowledgeAuthorization(
    bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy,
    failureState: AgentKnowledgeAuthorizationState? = nil
  ) async throws {
    guard await store.knowledge.validateKnowledgeAuthorizationBindings(
      bindings,
      policy: policy
    ) else {
      failureState?.markChanged()
      throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
    }
  }

  func executeAgentAutomaticInvocation(
    _ invocation: WorkbenchAIAgentToolInvocation,
    operationID: UUID,
    conversationID: UUID
  ) async throws -> WorkbenchAIAgentToolResult {
    try checkAIChatOperation(operationID)
    guard aiConversationAgentMode(for: conversationID) != .textOnly else {
      throw WorkbenchAutomationExecutionError.operationDidNotComplete(
        CoreL10n.text("当前对话已切换为仅问答模式，未执行工具。")
      )
    }
    guard WorkbenchAutomationRegistry.descriptor(
      for: invocation.step.command
    )?.allowsAgentAutomaticExecution == true
    else {
      throw WorkbenchAutomationExecutionError.operationDidNotComplete(
        CoreL10n.text("此 AI 操作必须等待确认。")
      )
    }
    let plan = WorkbenchAutomationPlan(
      goal: CoreL10n.text("执行 AI 请求允许自动运行的工作台操作"),
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
    guard let record = result.record.steps.first else {
      try checkAIChatOperation(operationID)
      return WorkbenchAIAgentToolResult(
        content: CoreL10n.text("应用内操作没有返回结果。"),
        isError: true
      )
    }

    // Automatic mutations must remain auditable and undoable even if the
    // enclosing model operation is cancelled immediately afterwards. Pure
    // read-only observations intentionally stay out of automation history.
    if result.record.steps.contains(where: { stepRecord in
      stepRecord.status == .succeeded
        && WorkbenchAutomationRegistry.descriptor(for: stepRecord.command)?.risk != .readOnly
    }) {
      store.recordAutomationRun(result.record)
      store.save()
    }
    try checkAIChatOperation(operationID)
    return WorkbenchAIAgentToolResult(
      content: String(record.message.prefix(4_000)),
      isError: record.status != .succeeded,
      targetDraftID: record.targetDraftID
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
      aiConversationAgentMode(for: conversationIdentity.conversationID) != .textOnly,
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
