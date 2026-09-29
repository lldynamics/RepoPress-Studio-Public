import Foundation

struct AIAuthorizedGeneralChatAttempt {
  let transport: AIPreparedPublishingChatTransport
  let authorization: AIOutboundPayloadTransportAuthorization
  let knowledgeAuthorizationBindings: [KnowledgeAuthorizationBinding]
  let knowledgePolicy: KnowledgeRetrievalPolicy
  let providerConfig: AIProviderConfig
  let connectionProfileID: UUID
}

extension WorkbenchAIStore {
  private var generalConversationScopeKey: String {
    AIConversationScope.general.storageKey
  }

  func activeConversationID(for scope: AIConversationScope) -> UUID? {
    switch scope {
    case .draft(let draftID):
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
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && $0.scope == .general && !$0.isArchived
      })
    else {
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
      updateGeneralConversation(
        resolvedID,
        update: { conversation in
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
  public func setGeneralAIChatSelectedModel(
    _ model: String,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换模型。"
      return false
    }
    let resolvedID = conversationID ?? activeGeneralAIChatConversationID
    guard let resolvedID,
      updateGeneralConversation(
        resolvedID,
        update: { conversation in
          conversation.selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
          if !conversation.selectedModel.isEmpty {
            conversation.modelGrade = .custom
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
      updateGeneralConversation(
        resolvedID,
        update: { conversation in
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
      updateGeneralConversation(
        resolvedID,
        update: { conversation in
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
    guard
      let token = try aiCredentialStore
        .token(forConnectionProfileID: connection.id)?.nilIfEmpty
    else {
      throw AIPublishingAssistantError.missingAPIKey
    }
    return token
  }

  func generalAIChatRequest(
    for conversation: AIConversation
  ) async throws -> AIChatRequest {
    let privacyService = AIOutboundPayloadPrivacyService()
    return await assembledGeneralAIChatRequest(
      for: conversation,
      privacyService: privacyService
    )
  }

  private func authorizedGeneralAIChatAttempt(
    for conversation: AIConversation,
    transportConfig: AIProviderConfig,
    transportVariant: AIOutboundPayloadTransportVariant? = nil,
    initialRequest: AIChatRequest? = nil
  ) async throws -> AIAuthorizedGeneralChatAttempt {
    let privacyService = AIOutboundPayloadPrivacyService()
    let resolvedInitialRequest: AIChatRequest
    if let initialRequest {
      resolvedInitialRequest = initialRequest
    } else {
      resolvedInitialRequest = await assembledGeneralAIChatRequest(
        for: conversation,
        privacyService: privacyService,
        knowledgeContextAssembly: .derive
      )
    }
    let initialTransport = try aiPublishingAssistantService.prepareTransport(
      for: resolvedInitialRequest,
      config: transportConfig,
      privacyService: privacyService,
      transportVariant: transportVariant
    )
    let outcome = await AIOutboundPayloadApprovalBroker.shared.requestApproval(
      for: initialTransport.payload.preview,
      scopeID: conversation.id
    )
    guard case .confirmed(let confirmation) = outcome else {
      throw AIOutboundPayloadConfirmationError.cancelled
    }
    guard !Task.isCancelled else {
      throw CancellationError()
    }
    try await requireValidAIKnowledgeAuthorization(
      resolvedInitialRequest.context.knowledgeContext?.authorizationBindings ?? [],
      policy: resolvedInitialRequest.context.knowledgePolicy
    )
    guard
      let refreshedConversation = aiConversations.first(where: {
        $0.id == conversation.id && $0.scope == .general && !$0.isArchived
      }),
      let connectionProfileID = refreshedConversation.connectionProfileID,
      let refreshedConnection = store.aiConnectionProfile(for: connectionProfileID)
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedRequest = await assembledGeneralAIChatRequest(
      for: refreshedConversation,
      privacyService: privacyService,
      knowledgeContextAssembly: .frozenKnowledge(
        resolvedInitialRequest.context.knowledgeContext
      )
    )
    let refreshedConfig = privacyService.sanitizedProviderConfig(refreshedConnection.config)
    guard refreshedConfig == transportConfig else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedTransport = try aiPublishingAssistantService.prepareTransport(
      for: refreshedRequest,
      config: refreshedConfig,
      privacyService: privacyService,
      transportVariant: transportVariant,
      now: initialTransport.payload.preview.createdAt,
      nonce: initialTransport.payload.preview.nonce
    )
    try privacyService.validate(
      confirmation: confirmation,
      prepared: refreshedTransport.payload
    )
    let authorizedTransport = refreshedTransport.bindingAuthorizationDeadline(
      refreshedTransport.payload.preview.expiresAt
    )
    return AIAuthorizedGeneralChatAttempt(
      transport: authorizedTransport,
      authorization: AIOutboundPayloadTransportAuthorization(
        confirmation: confirmation,
        prepared: authorizedTransport.payload,
        privacyService: privacyService
      ),
      knowledgeAuthorizationBindings: resolvedInitialRequest.context.knowledgeContext?
        .authorizationBindings ?? [],
      knowledgePolicy: resolvedInitialRequest.context.knowledgePolicy,
      providerConfig: refreshedConfig,
      connectionProfileID: connectionProfileID
    )
  }

  private func assembledGeneralAIChatRequest(
    for conversation: AIConversation,
    privacyService: AIOutboundPayloadPrivacyService,
    knowledgeContextAssembly: AIKnowledgeContextAssembly = .derive
  ) async -> AIChatRequest {
    let latestUserMessage = conversation.messages.last(where: { $0.role == .user })
    let explicitReferences = latestUserMessage?.contextReferences ?? []
    let explicitPrompt: String?
    let knowledgeContext: KnowledgeContextSnapshot?
    switch knowledgeContextAssembly {
    case .derive:
      let explicitSnapshot = await explicitGeneralAIChatContextPromptSnapshot(
        references: explicitReferences
      )
      explicitPrompt = explicitSnapshot?.prompt
      let query = latestUserMessage?.content.trimmedForPublishing ?? ""
      let automaticContext: KnowledgeContextSnapshot?
      if query.isEmpty || conversation.knowledgePolicy == .off {
        automaticContext = nil
      } else {
        // General retrieval is driven by the user's question only. In
        // particular, no current draft, editor selection, repository or publish
        // status is read to enrich this query.
        automaticContext = await store.knowledgeContext(
          query: query,
          policy: conversation.knowledgePolicy
        )
      }
      knowledgeContext = mergedAIKnowledgeContext(
        automatic: automaticContext,
        explicitBindings: explicitSnapshot?.authorizationBindings ?? []
      )
    case .frozenKnowledge(let frozenContext):
      let explicitSnapshot = await explicitGeneralAIChatContextPromptSnapshot(
        references: explicitReferences
      )
      explicitPrompt = explicitSnapshot?.prompt
      knowledgeContext = mergedAIKnowledgeContext(
        automatic: frozenContext,
        explicitBindings: explicitSnapshot?.authorizationBindings ?? []
      )
    case .frozen(let frozenContext, let frozenPrompt):
      explicitPrompt = frozenPrompt
      knowledgeContext = frozenContext
    }
    let envelope = AIContextAssembler.generalEnvelope(
      knowledgePolicy: conversation.knowledgePolicy,
      explicitContextReferences: explicitReferences,
      explicitContextPrompt: explicitPrompt.map { privacyService.sanitize($0).text },
      knowledgeContext: privacyService.sanitizedKnowledgeContext(knowledgeContext)
    )
    return AIChatRequest(
      messages: privacyService.sanitizedChatMessages(conversation.messages),
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
    ownerToken: UUID? = nil,
    expectedConversation: AIChatGeneralConversationExpectation? = nil
  ) async -> AIPublishingChatMessage? {
    guard !Task.isCancelled else { return nil }
    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty || !imageAttachments.isEmpty else {
      store.setAIChatMessage("请先输入要发送给 AI 的内容。")
      return nil
    }
    if let expectedConversation {
      let expectationIsCurrent: Bool
      if let expectedSnapshot = expectedConversation.conversation {
        expectationIsCurrent =
          conversationID == expectedSnapshot.id
          && expectedSnapshot.scope == .general
          && !expectedSnapshot.isArchived
          && aiConversations.first(where: {
            $0.id == expectedSnapshot.id
              && $0.scope == .general
              && !$0.isArchived
          }) == expectedSnapshot
      } else {
        expectationIsCurrent =
          conversationID == nil
          && activeGeneralAIChatConversationID == nil
      }
      guard expectationIsCurrent else {
        store.setAIChatMessage(
          CoreL10n.text("AI 对话上下文已变化，本次未发送，请重试。")
        )
        return nil
      }
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
      store.setAIChatMessage("图片附件仅支持 PNG、JPEG、GIF 或 WebP，且每张不能超过 10 MB。")
      return nil
    }

    let resolvedConversationID = conversationID ?? activeGeneralAIChatConversationID
    let conversation: AIConversation
    if let resolvedConversationID,
      let found = aiConversations.first(where: {
        $0.id == resolvedConversationID && $0.scope == .general && !$0.isArchived
      })
    {
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
    guard
      AIChatImageAttachmentBudget.canAppend(
        selectedImageAttachments,
        to: conversation.messages
      )
    else {
      store.setAIChatMessage("本次图片会超过当前对话的 8 MB 总预算，请减少或移除图片后重试。")
      return nil
    }
    do {
      // Availability check only. The token is deliberately not retained while
      // the outbound payload sheet is awaiting a decision.
      _ = try aiChatAvailableAPIKey(for: connection)
    } catch {
      store.setAIChatFailureMessage(CoreL10n.format("AI 通用对话失败：%@", error.localizedDescription))
      return nil
    }
    guard !Task.isCancelled else { return nil }
    guard
      let operationID = beginAIChatOperation(
        statusMessage: "AI 正在回复...",
        ownerToken: ownerToken,
        target: .generalAIConversation(conversation.id)
      )
    else {
      return nil
    }

    activeAIConversationIDsByScope[generalConversationScopeKey] = conversation.id
    if let connectionProfileID,
      connectionProfileID != conversation.connectionProfileID
    {
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

    return await runAIChatRequestTask(operationID: operationID) { [weak self] in
      guard let self else { return nil }
      return await self.generateGeneralAIChatReply(
        conversationID: conversation.id,
        operationID: operationID,
        config: connection.config
      )
    }
  }

  private func updateGeneralConversation(
    _ conversationID: UUID,
    update: (inout AIConversation) -> Void
  ) -> AIConversation? {
    var updated = aiConversations
    guard
      let index = updated.firstIndex(where: {
        $0.id == conversationID && $0.scope == .general
      })
    else { return nil }
    update(&updated[index])
    updated[index].updatedAt = max(updated[index].updatedAt, Date())
    aiConversations = updated
    return aiConversations.first { $0.id == conversationID }
  }

  func updateGeneralConversationMessages(
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
    config: AIProviderConfig
  ) async -> AIPublishingChatMessage? {
    defer { finishAIChatOperation(operationID) }
    let minimizedConfig = AIOutboundPayloadPrivacyService().sanitizedProviderConfig(config)
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && $0.scope == .general
      })
    else {
      store.setAIChatMessage("找不到当前通用 AI 对话。")
      return nil
    }

    if generalAIChatRequestsDraftCreation(
      conversation.messages.last(where: { $0.role == .user })?.content ?? ""
    ) {
      store.setAIChatMessage(CoreL10n.text("请使用“新建文章”创建草稿，再让写作助手生成或修改内容。"))
      return nil
    }
    let initialRequest = await assembledGeneralAIChatRequest(
      for: conversation,
      privacyService: AIOutboundPayloadPrivacyService(),
      knowledgeContextAssembly: .derive
    )

    let attempt: AIAuthorizedGeneralChatAttempt
    do {
      attempt = try await authorizedGeneralAIChatAttempt(
        for: conversation,
        transportConfig: minimizedConfig,
        initialRequest: initialRequest
      )
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return nil
    } catch let error as AIOutboundPayloadConfirmationError where error == .drifted {
      discardUnsentGeneralAIChatUserMessage(conversationID: conversationID)
      store.setAIChatMessage(
        CoreL10n.text("AI 连接配置已变化，本次未发送；输入已保留，请重新确认后发送。")
      )
      return nil
    } catch {
      store.setAIChatFailureMessage(error.localizedDescription)
      return nil
    }
    do {
      try checkAIChatOperation(operationID)
      try await requireValidAIKnowledgeAuthorization(
        attempt.knowledgeAuthorizationBindings,
        policy: attempt.knowledgePolicy
      )
      try checkAIChatOperation(operationID)
      let token = try currentGeneralAIChatAPIKey(
        conversationID: conversationID,
        matching: attempt.providerConfig,
        connectionProfileID: attempt.connectionProfileID
      )
      try checkAIChatOperation(operationID)
      try attempt.authorization.consume()
      switch attempt.transport.preparedRequest.mode {
      case .streaming:
        return try await generateStreamingGeneralAIChatReply(
          attempt: attempt,
          conversationID: conversationID,
          operationID: operationID,
          apiKey: token
        )
      case .nonStreaming:
        return try await generateCompleteGeneralAIChatReply(
          transport: attempt.transport,
          conversationID: conversationID,
          operationID: operationID,
          apiKey: token
        )
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return aiConversations.first(where: { $0.id == conversationID })?.messages.last {
        $0.role == .assistant
      }
    } catch let error as AIChatCompletionClientError {
      configureGeneralManualRetry(
        for: error,
        conversationID: conversationID,
        operationID: operationID
      )
      if error == .requestAuthorizationChanged {
        discardUnsentGeneralAIChatUserMessage(conversationID: conversationID)
      }
      store.setAIChatFailureMessage(CoreL10n.format("AI 通用对话失败：%@", error.localizedDescription))
      if error.didReceivePartialContent {
        return aiConversations.first(where: { $0.id == conversationID })?.messages.last {
          $0.role == .assistant
        }
      }
      return nil
    } catch let error as AIOutboundPayloadConfirmationError where error == .drifted {
      discardUnsentGeneralAIChatUserMessage(conversationID: conversationID)
      store.setAIChatMessage(
        CoreL10n.text("AI 连接配置已变化，本次未发送；输入已保留，请重新确认后发送。")
      )
      return nil
    } catch {
      store.setAIChatFailureMessage(CoreL10n.format("AI 通用对话失败：%@", error.localizedDescription))
      return nil
    }
  }

  private func discardUnsentGeneralAIChatUserMessage(conversationID: UUID) {
    updateGeneralConversationMessages(conversationID) { messages in
      guard messages.last?.role == .user else { return }
      messages.removeLast()
    }
  }

  /// Redirect explicit local creation requests to the editor. Content requests
  /// (including an article outline) remain ordinary text-only writing tasks.
  private func generalAIChatRequestsDraftCreation(_ text: String) -> Bool {
    let normalized = text.lowercased()
    let compact = normalized.filter { !$0.isWhitespace && !$0.isNewline }
    guard !compact.isEmpty else { return false }

    // Meta questions may quote the exact command the user wants to learn
    // about. They should remain questions instead of being executed merely
    // because the quoted example contains “帮我新建…”.
    let informationalMarkers = [
      "如何", "怎么", "怎样", "教程", "方法", "步骤", "流程",
      "是否支持", "能否实现", "可以实现", "能不能实现", "可不可以实现",
      "howto", "howdo", "canrepopress", "doesrepopress", "isitpossible",
    ]
    guard !informationalMarkers.contains(where: compact.contains) else {
      return false
    }

    let writingDeliverables = [
      "提纲", "大纲", "标题", "正文", "内容", "文案", "示例", "模板", "摘要",
    ]
    if writingDeliverables.contains(where: compact.contains)
      || normalized.range(
        of: #"\b(outline|title|content|copy|example|template|summary|text)\b"#,
        options: .regularExpression
      ) != nil
    {
      return false
    }

    let hasChineseTarget = ["文章", "草稿", "博文", "博客", "帖子"]
      .contains(where: compact.contains)
    let hasChineseCreateInstruction = [
      "请新建", "请创建", "请新增", "帮我新建", "帮我创建", "帮我新增",
      "给我新建", "给我创建", "替我新建", "替我创建", "为我新建", "为我创建",
      "直接新建", "直接创建", "我要新建", "我要创建", "新建一篇", "创建一篇",
      "新增一篇", "建立一篇", "新建文章", "创建文章", "新建草稿", "创建草稿",
    ].contains(where: compact.contains)
    if hasChineseTarget && hasChineseCreateInstruction {
      return true
    }

    // Keep English matching token based: substring checks such as "new" in
    // "news article" would otherwise turn ordinary reading questions into
    // application commands.
    let englishInstruction =
      #"\b(create|make|start)\s+(me\s+)?(a\s+|an\s+)?(new\s+)?(article|draft|blog\s+post|post)\b"#
    return normalized.range(of: englishInstruction, options: .regularExpression) != nil
  }

  func currentGeneralAIChatAPIKey(
    conversationID: UUID,
    matching expectedConfig: AIProviderConfig,
    connectionProfileID expectedConnectionProfileID: UUID
  ) throws -> String? {
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && $0.scope == .general && !$0.isArchived
      }),
      let connectionProfileID = conversation.connectionProfileID,
      connectionProfileID == expectedConnectionProfileID,
      let connection = store.aiConnectionProfile(for: connectionProfileID)
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    guard
      AIOutboundPayloadPrivacyService().sanitizedProviderConfig(connection.config) == expectedConfig
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    return try aiChatAvailableAPIKey(for: connection)
  }

  private func generateCompleteGeneralAIChatReply(
    transport: AIPreparedPublishingChatTransport,
    conversationID: UUID,
    operationID: UUID,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let assistantMessage = try await aiPublishingAssistantService.completePrepared(
      transport,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    updateGeneralConversationMessages(conversationID) { $0.append(assistantMessage) }
    store.setAIChatMessage("AI 已回复。")
    return assistantMessage
  }

  private func configureGeneralManualRetry(
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
      requiresDuplicateChargeConfirmation: error.didReceivePartialContent,
      retryAfter: error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
    )
  }

  @discardableResult
  public func retryLastFailedGeneralAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    conversationID: UUID? = nil,
    operationID: UUID? = nil,
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
    if let operationID, retryState.operationID != operationID {
      store.setAIChatMessage("当前通用 AI 请求已变化，未执行旧任务重试。")
      return nil
    }
    guard
      let conversation = aiConversations.first(where: {
        $0.id == retryState.conversationID && $0.scope == .general && !$0.isArchived
      })
    else {
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
      let connection = store.aiConnectionProfile(for: boundConnectionProfileID)
    else {
      store.setAIChatMessage("当前通用对话绑定的 AI 连接档案已不存在，请先重新绑定。")
      return nil
    }
    do {
      _ = try aiChatAvailableAPIKey(for: connection)
    } catch {
      store.setAIChatFailureMessage(CoreL10n.format("AI 通用对话失败：%@", error.localizedDescription))
      return nil
    }
    guard
      let operationID = beginAIChatOperation(
        statusMessage: "AI 正在重新生成回复...",
        clearsManualRetryState: false,
        ownerToken: ownerToken,
        target: .generalAIConversation(conversation.id)
      )
    else {
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
      config: connection.config
    )
    let didCompleteRetry =
      result != nil
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
