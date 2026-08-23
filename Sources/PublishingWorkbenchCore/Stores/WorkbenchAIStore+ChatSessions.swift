import Foundation

struct AIAuthorizedPublishingChatAttempt {
  let transport: AIPreparedPublishingChatTransport
  let authorization: AIOutboundPayloadTransportAuthorization
  let knowledgeAuthorizationBindings: [KnowledgeAuthorizationBinding]
  let knowledgePolicy: KnowledgeRetrievalPolicy
}

/// The knowledge portion of a request has deliberately distinct states so an
/// intentional `nil` snapshot is never mistaken for "retrieve again".
enum AIKnowledgeContextAssembly {
  case derive
  /// Reuses the first knowledge snapshot while resolving non-knowledge
  /// explicit context again. This preserves drift checks for selections,
  /// articles, profiles, and publish checks.
  case frozenKnowledge(KnowledgeContextSnapshot?)
  /// Reuses the complete prompt shell. Continuation validation uses this
  /// while resolving task configuration from an already-persisted transcript.
  case frozen(
    knowledgeContext: KnowledgeContextSnapshot?,
    explicitContextPrompt: String?
  )
}

extension WorkbenchAIStore {
  public func prepareAIChat(for draft: ArticleDraft) {
    if aiChatDraftID == draft.id {
      return
    }
    aiChatManualRetryState = nil
    cacheCurrentAIChatSessionForAIStore()
    aiChatDraftID = draft.id
    applyCurrentAIChatSession(
      activeAIChatConversation(for: draft.id)?.sessionState
        ?? AIPublishingChatSessionState()
    )
  }

  public func aiChatConversations(
    for draftID: UUID,
    includingArchived: Bool = false
  ) -> [AIConversation] {
    aiConversations
      .filter {
        $0.draftID == draftID && (includingArchived || !$0.isArchived)
      }
      .sorted {
        if $0.updatedAt != $1.updatedAt {
          return $0.updatedAt > $1.updatedAt
        }
        return $0.createdAt > $1.createdAt
      }
  }

  public func activeAIChatConversationID(for draftID: UUID) -> UUID? {
    guard let conversationID = activeAIConversationIDsByDraftID[draftID],
      aiConversations.contains(where: {
        $0.id == conversationID && $0.draftID == draftID && !$0.isArchived
      })
    else {
      return nil
    }
    return conversationID
  }

  public func activeAIChatConversation(
    for draftID: UUID? = nil
  ) -> AIConversation? {
    guard let resolvedDraftID = draftID ?? aiChatDraftID,
      let conversationID = activeAIChatConversationID(for: resolvedDraftID)
    else {
      return nil
    }
    return aiConversations.first { $0.id == conversationID }
  }

  func aiChatSessionState(for draftID: UUID) -> AIPublishingChatSessionState? {
    if aiChatDraftID == draftID {
      return currentAIChatSessionState()
    }
    return activeAIChatConversation(for: draftID)?.sessionState
  }

  func aiChatConversationIdentity(
    for draftID: UUID
  ) -> AIChatConversationIdentity? {
    guard let conversationID = activeAIChatConversationID(for: draftID) else {
      return nil
    }
    return AIChatConversationIdentity(
      draftID: draftID,
      conversationID: conversationID
    )
  }

  func aiChatSessionState(
    for identity: AIChatConversationIdentity
  ) -> AIPublishingChatSessionState? {
    if aiChatDraftID == identity.draftID,
      activeAIChatConversationID(for: identity.draftID) == identity.conversationID
    {
      return currentAIChatSessionState()
    }
    return aiConversations.first {
      $0.id == identity.conversationID && $0.draftID == identity.draftID
    }?.sessionState
  }

  func setAIChatSessionState(_ state: AIPublishingChatSessionState, for draftID: UUID) {
    let prepared = state.prepared()
    if aiChatDraftID == draftID {
      applyCurrentAIChatSession(prepared)
      cacheCurrentAIChatSessionForAIStore()
    } else {
      upsertAIChatConversation(
        state: prepared,
        draftID: draftID,
        createIfNeeded: prepared.shouldCache
      )
    }
  }

  private func setAIChatSessionState(
    _ state: AIPublishingChatSessionState,
    for identity: AIChatConversationIdentity
  ) {
    guard
      let index = aiConversations.firstIndex(where: {
        $0.id == identity.conversationID && $0.draftID == identity.draftID
      })
    else {
      return
    }

    var updatedConversations = aiConversations
    updatedConversations[index].apply(state.prepared())
    aiConversations = updatedConversations
    if aiChatDraftID == identity.draftID,
      activeAIChatConversationID(for: identity.draftID) == identity.conversationID,
      let updatedConversation = aiConversations.first(where: {
        $0.id == identity.conversationID
      })
    {
      applyCurrentAIChatSession(updatedConversation.sessionState)
    }
    store.scheduleAutosave()
  }

  func removeAIChatSessionState(for draftID: UUID) {
    if let activeConversationID = activeAIConversationIDsByDraftID.removeValue(
      forKey: draftID
    ) {
      aiConversations.removeAll { $0.id == activeConversationID }
      store.scheduleAutosave()
    }
    if aiChatDraftID == draftID {
      applyCurrentAIChatSession(AIPublishingChatSessionState())
    }
  }

  func cacheCurrentAIChatSessionForAIStore() {
    guard let draftID = aiChatDraftID else { return }
    let prepared = currentAIChatSessionState().prepared()
    applyCurrentAIChatSession(prepared)
    upsertAIChatConversation(
      state: prepared,
      draftID: draftID,
      createIfNeeded: prepared.shouldCache
    )
  }

  private func currentAIChatSessionState() -> AIPublishingChatSessionState {
    return AIPublishingChatSessionState(
      conversationTitle: aiChatConversationTitle,
      messages: aiChatMessages,
      contextMode: aiChatContextMode,
      knowledgePolicy: aiChatKnowledgePolicy,
      modelGrade: aiChatModelGrade,
      reasoningLevel: aiChatReasoningLevel,
      selectedModel: aiChatSelectedModel,
      focusedParagraphID: aiChatFocusedParagraphID
    )
  }

  private func applyCurrentAIChatSession(_ state: AIPublishingChatSessionState) {
    aiChatConversationTitle = state.conversationTitle
    aiChatMessages = state.messages
    aiChatContextMode = state.contextMode
    aiChatKnowledgePolicy = state.knowledgePolicy
    aiChatModelGrade = state.modelGrade
    aiChatReasoningLevel = state.reasoningLevel
    aiChatSelectedModel = state.selectedModel
    aiChatFocusedParagraphID = state.focusedParagraphID
  }

  private func upsertAIChatConversation(
    state: AIPublishingChatSessionState,
    draftID: UUID,
    createIfNeeded: Bool,
    updatedAt: Date = Date()
  ) {
    if let conversationID = activeAIChatConversationID(for: draftID),
      let index = aiConversations.firstIndex(where: { $0.id == conversationID })
    {
      aiConversations[index].apply(state, updatedAt: updatedAt)
      store.scheduleAutosave()
      return
    }

    activeAIConversationIDsByDraftID.removeValue(forKey: draftID)
    guard createIfNeeded else { return }
    let conversation = AIConversation(
      draftID: draftID,
      title: state.conversationTitle,
      messages: state.messages,
      contextMode: state.contextMode,
      knowledgePolicy: state.knowledgePolicy,
      modelGrade: state.modelGrade,
      reasoningLevel: state.reasoningLevel,
      selectedModel: state.selectedModel,
      focusedParagraphID: state.focusedParagraphID,
      createdAt: updatedAt
    ).prepared()
    aiConversations.append(conversation)
    activeAIConversationIDsByDraftID[draftID] = conversation.id
    store.scheduleAutosave()
  }

  private func activateMostRecentAIChatConversation(for draftID: UUID) {
    if let conversation = aiChatConversations(for: draftID).first {
      activeAIConversationIDsByDraftID[draftID] = conversation.id
      if aiChatDraftID == draftID {
        applyCurrentAIChatSession(conversation.sessionState)
        aiChatManualRetryState = nil
      }
      return
    }

    activeAIConversationIDsByDraftID.removeValue(forKey: draftID)
    if aiChatDraftID == draftID {
      applyCurrentAIChatSession(AIPublishingChatSessionState())
      aiChatManualRetryState = nil
    }
  }

  func updateAIChatSession(for draftID: UUID, update: (inout [AIPublishingChatMessage]) -> Void) {
    if aiChatDraftID == draftID {
      update(&aiChatMessages)
      cacheCurrentAIChatSessionForAIStore()
      return
    }
    var state =
      activeAIChatConversation(for: draftID)?.sessionState
      ?? AIPublishingChatSessionState()
    update(&state.messages)
    setAIChatSessionState(state, for: draftID)
  }

  func updateAIChatSession(
    for identity: AIChatConversationIdentity,
    update: (inout [AIPublishingChatMessage]) -> Void
  ) {
    guard var state = aiChatSessionState(for: identity) else { return }
    update(&state.messages)
    setAIChatSessionState(state, for: identity)
  }

  func aiChatQuickHideOperationMessage() -> String {
    store.quickHideOperationMessage
  }

  func aiChatAvailableAPIKey(for profile: SiteProfile) throws -> String? {
    let connection = store.aiConnectionProfile(for: profile)
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
      let token = try aiCredentialStore.token(
        forConnectionProfileID: connection.id,
        legacyProfile: profile
      )?.nilIfEmpty
    else {
      throw AIPublishingAssistantError.missingAPIKey
    }
    return token
  }

  func setAIChatCancellationRequested(_ value: Bool) {
    aiChatOperationCoordinator.setCancellationRequested(value)
  }

  func aiChatCancellationRequested() -> Bool {
    aiChatOperationCoordinator.isCancellationRequested
  }

  @discardableResult func requestAIChatCancellation() -> Bool {
    guard
      aiChatOperationCoordinator.requestCancellation(
        whileRunning: isAIChatRunning
      )
    else { return false }
    aiChatMessage = "正在停止 AI 回复..."
    return true
  }

  @discardableResult func requestAIChatCancellation(expectedOwnerToken: UUID) -> Bool {
    guard
      aiChatOperationCoordinator.requestCancellation(
        whileRunning: isAIChatRunning,
        expectedOwnerToken: expectedOwnerToken
      )
    else { return false }
    aiChatMessage = "正在停止 AI 回复..."
    return true
  }

  func beginAIChatOperation(
    statusMessage: String,
    clearsManualRetryState: Bool = true,
    ownerToken: UUID? = nil
  ) -> UUID? {
    guard let operationID = aiChatOperationCoordinator.begin(ownerToken: ownerToken) else {
      store.setAIChatMessage("AI 正在回复，请先停止当前回复后再试。")
      return nil
    }
    if clearsManualRetryState {
      aiChatManualRetryState = nil
      aiGeneralChatManualRetryState = nil
    }
    store.setAIChatRunning(true)
    store.setAIChatMessage(statusMessage)
    return operationID
  }

  func finishAIChatOperation(_ operationID: UUID) {
    guard aiChatOperationCoordinator.finish(operationID) else { return }
    store.setAIChatRunning(false)
    store.save()
  }

  func checkAIChatOperation(_ operationID: UUID) throws {
    try aiChatOperationCoordinator.check(operationID)
  }

  func aiChatRequest(
    for draft: ArticleDraft,
    conversationIdentity: AIChatConversationIdentity,
    transportConfig: AIProviderConfig,
    transportVariant: AIOutboundPayloadTransportVariant? = nil,
    initialRequest: AIPublishingChatRequest? = nil
  ) async throws -> AIAuthorizedPublishingChatAttempt {
    let privacyService = AIOutboundPayloadPrivacyService()
    let resolvedInitialRequest: AIPublishingChatRequest
    if let initialRequest {
      resolvedInitialRequest = initialRequest
    } else {
      resolvedInitialRequest = await assembledAIChatRequest(
        for: draft,
        conversationIdentity: conversationIdentity,
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
      scopeID: conversationIdentity.conversationID
    )
    guard case .confirmed(let confirmation) = outcome else {
      throw AIOutboundPayloadConfirmationError.cancelled
    }
    guard !Task.isCancelled else {
      throw CancellationError()
    }

    try await requireValidAIKnowledgeAuthorization(
      resolvedInitialRequest.knowledgeContext?.authorizationBindings ?? [],
      policy: resolvedInitialRequest.knowledgePolicy
    )

    let refreshedRequest = await assembledAIChatRequest(
      for: draft,
      conversationIdentity: conversationIdentity,
      privacyService: privacyService,
      knowledgeContextAssembly: .frozenKnowledge(resolvedInitialRequest.knowledgeContext)
    )
    let refreshedConfig = privacyService.sanitizedProviderConfig(
      store.aiProviderConfig(for: refreshedRequest.profile)
    )
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
    return AIAuthorizedPublishingChatAttempt(
      transport: authorizedTransport,
      authorization: AIOutboundPayloadTransportAuthorization(
        confirmation: confirmation,
        prepared: authorizedTransport.payload,
        privacyService: privacyService
      ),
      knowledgeAuthorizationBindings: resolvedInitialRequest.knowledgeContext?.authorizationBindings
        ?? [],
      knowledgePolicy: resolvedInitialRequest.knowledgePolicy
    )
  }

  func assembledAIChatRequest(
    for draft: ArticleDraft,
    conversationIdentity: AIChatConversationIdentity,
    privacyService: AIOutboundPayloadPrivacyService,
    knowledgeContextAssembly: AIKnowledgeContextAssembly = .derive
  ) async -> AIPublishingChatRequest {
    let session =
      aiChatSessionState(for: conversationIdentity)
      ?? AIPublishingChatSessionState()
    let artifacts = await store.aiPublishingRequestArtifacts(for: draft)
    let focusedParagraph = session.focusedParagraphID.flatMap { focusedID in
      AIPublishingChatDraftParagraphParser.extract(from: artifacts.draft.bodyMarkdown).first {
        $0.id == focusedID
      }
    }
    let editorSelection = store.activeEditorSelection.flatMap { selection in
      selection.validatedRange(in: artifacts.draft) == nil ? nil : selection
    }
    let latestQuestion = session.messages.last(where: { $0.role == .user })?.content
    let explicitContextReferences =
      session.messages.last(where: { $0.role == .user })?.contextReferences ?? []
    let explicitContextPrompt: String?
    let knowledgeContext: KnowledgeContextSnapshot?
    switch knowledgeContextAssembly {
    case .derive:
      let explicitSnapshot = await explicitAIChatContextPromptSnapshot(
        references: explicitContextReferences,
        draft: artifacts.draft
      )
      explicitContextPrompt = explicitSnapshot?.prompt
      let automaticContext = await store.knowledge.context(
        query: knowledgeQuery(
          draft: artifacts.draft,
          selectedText: editorSelection?.selectedText ?? focusedParagraph?.text,
          instruction: latestQuestion
        ),
        policy: session.knowledgePolicy
      )
      knowledgeContext = mergedAIKnowledgeContext(
        automatic: automaticContext,
        explicitBindings: explicitSnapshot?.authorizationBindings ?? []
      )
    case .frozenKnowledge(let frozenContext):
      let explicitSnapshot = await explicitAIChatContextPromptSnapshot(
        references: explicitContextReferences,
        draft: artifacts.draft
      )
      explicitContextPrompt = explicitSnapshot?.prompt
      knowledgeContext = mergedAIKnowledgeContext(
        automatic: frozenContext,
        explicitBindings: explicitSnapshot?.authorizationBindings ?? []
      )
    case .frozen(let frozenContext, let frozenPrompt):
      explicitContextPrompt = frozenPrompt
      knowledgeContext = frozenContext
    }
    let sanitizedFocusedParagraph = focusedParagraph.map { paragraph in
      var updated = paragraph
      updated.title = privacyService.sanitize(paragraph.title).text
      updated.text = privacyService.sanitize(paragraph.text).text
      return updated
    }
    let sanitizedSuggestions = store.relatedArticleSuggestions(for: artifacts.draft).map {
      suggestion in
      var updated = suggestion
      updated.sourceTitle = privacyService.sanitize(suggestion.sourceTitle).text
      updated.targetTitle = privacyService.sanitize(suggestion.targetTitle).text
      updated.targetPath = privacyService.sanitize(suggestion.targetPath).text
      updated.reason = privacyService.sanitize(suggestion.reason).text
      updated.sharedLabels = suggestion.sharedLabels.map { privacyService.sanitize($0).text }
      return updated
    }
    return AIPublishingChatRequest(
      draft: privacyService.sanitizedDraft(artifacts.draft),
      profile: artifacts.profile,
      messages: privacyService.sanitizedChatMessages(session.messages),
      contextMode: session.contextMode,
      knowledgePolicy: session.knowledgePolicy,
      knowledgeContext: privacyService.sanitizedKnowledgeContext(knowledgeContext),
      modelGrade: session.modelGrade,
      reasoningLevel: session.reasoningLevel,
      selectedModel: session.selectedModel.nilIfEmpty,
      preflightIssues: artifacts.preflightIssues,
      publishPackage: artifacts.publishPackage,
      remoteReviewDraft: artifacts.remoteReviewDraft,
      workflowContext: artifacts.workflowContext,
      focusedParagraph: sanitizedFocusedParagraph,
      editorSelection: privacyService.sanitizedEditorSelection(editorSelection),
      explicitContextReferences: explicitContextReferences,
      explicitContextPrompt: explicitContextPrompt.map { privacyService.sanitize($0).text },
      relatedSuggestions: sanitizedSuggestions,
      automationDraftVersions: Dictionary(
        uniqueKeysWithValues: store.drafts.map { ($0.id, $0.updatedAt) }
      )
    )
  }

  /// Reuses the first retrieval result and keeps explicit @ references in the
  /// same hidden authorization envelope. Empty citations are intentional when
  /// a request has only an explicit binding; the binding itself is never
  /// serialized into the model prompt.
  func mergedAIKnowledgeContext(
    automatic: KnowledgeContextSnapshot?,
    explicitBindings: [KnowledgeAuthorizationBinding]
  ) -> KnowledgeContextSnapshot? {
    var seen = Set<KnowledgeAuthorizationBinding>()
    let bindings =
      (automatic?.authorizationBindings ?? [])
      .filter { seen.insert($0).inserted }
      + explicitBindings.filter { seen.insert($0).inserted }

    guard let automatic else {
      guard !bindings.isEmpty else { return nil }
      return KnowledgeContextSnapshot(
        query: "",
        citations: [],
        authorizationBindings: bindings
      )
    }

    return KnowledgeContextSnapshot(
      query: automatic.query,
      citations: automatic.citations,
      authorizationBindings: bindings
    )
  }

  func requireValidAIKnowledgeAuthorization(
    _ bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy
  ) async throws {
    guard !bindings.isEmpty else { return }
    let valid = await store.knowledge.validateKnowledgeAuthorizationBindings(
      bindings,
      policy: policy
    )
    guard valid else {
      throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
    }
  }

  func knowledgeQuery(
    draft: ArticleDraft,
    selectedText: String? = nil,
    instruction: String? = nil
  ) -> String {
    [
      instruction?.trimmedForPublishing.nilIfEmpty,
      draft.title.trimmedForPublishing.nilIfEmpty,
      draft.summary.trimmedForPublishing.nilIfEmpty,
      selectedText?.trimmedForPublishing.nilIfEmpty.map { String($0.prefix(1_500)) },
      String(draft.bodyMarkdown.prefix(1_500)).trimmedForPublishing.nilIfEmpty,
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
  }

  public func setAIChatKnowledgePolicy(_ policy: KnowledgeRetrievalPolicy) {
    aiChatKnowledgePolicy = policy
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatModelGrade(_ grade: AIChatModelGrade) {
    let config =
      store.selectedDraft.map { store.aiProviderConfig(for: store.profile(for: $0)) }
      ?? store.aiProviderConfig(for: store.activeProfile)
    aiChatModelGrade = grade
    // Preset grades resolve their provider-specific model at request time.
    // Persist only a model explicitly entered through the custom grade.
    aiChatSelectedModel =
      grade == .custom
      ? AIChatModelCatalog.model(
        for: grade,
        config: config,
        currentModel: aiChatSelectedModel
      )
      : ""
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatReasoningLevel(_ level: AIChatReasoningLevel) {
    aiChatReasoningLevel = level
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatCustomModel(_ model: String) {
    aiChatModelGrade = .custom
    aiChatSelectedModel = model
    cacheCurrentAIChatSessionForAIStore()
  }

  public func resetAIChatModelToProfileDefault() {
    setAIChatModelGrade(.standard)
  }

  public func clearAIChat() {
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: aiChatDraftID.flatMap { activeAIChatConversationID(for: $0) }
      )
    else {
      return
    }
    aiChatConversationTitle = nil
    aiChatMessages = []
    aiChatManualRetryState = nil
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = "AI 讨论已清空。"
    store.save()
  }

  public func setAIChatConversationTitle(_ title: String?, draft: ArticleDraft? = nil) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard aiChatDraftID != nil else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }

    aiChatConversationTitle = title?.trimmedForPublishing.nilIfEmpty
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = aiChatConversationTitle == nil ? "已恢复自动对话标题。" : "已更新 AI 对话标题。"
    store.save()
  }

  @discardableResult
  public func renameAIChatConversation(
    _ conversationID: UUID,
    title: String?
  ) -> Bool {
    guard let index = aiConversations.firstIndex(where: { $0.id == conversationID }) else {
      aiChatMessage = "找不到要重命名的 AI 对话。"
      return false
    }

    let resolvedTitle = title?.trimmedForPublishing.nilIfEmpty
    guard let draftID = aiConversations[index].draftID else {
      var updatedConversations = aiConversations
      updatedConversations[index].title = resolvedTitle
      updatedConversations[index].updatedAt = Date()
      aiConversations = updatedConversations
      aiChatMessage = resolvedTitle == nil ? "已恢复自动对话标题。" : "已更新 AI 对话标题。"
      store.save()
      return true
    }
    if activeAIChatConversationID(for: draftID) == conversationID,
      aiChatDraftID == draftID
    {
      aiChatConversationTitle = resolvedTitle
      cacheCurrentAIChatSessionForAIStore()
    } else {
      var updatedConversations = aiConversations
      updatedConversations[index].title = resolvedTitle
      updatedConversations[index].updatedAt = Date()
      aiConversations = updatedConversations
    }
    aiChatMessage = resolvedTitle == nil ? "已恢复自动对话标题。" : "已更新 AI 对话标题。"
    store.save()
    return true
  }

  @discardableResult
  public func selectAIChatConversation(_ conversationID: UUID) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再切换对话。"
      return false
    }
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && !$0.isArchived
      })
    else {
      aiChatMessage = "找不到可切换的 AI 对话。"
      return false
    }
    guard let draftID = conversation.draftID else {
      activeAIConversationIDsByScope[conversation.scope.storageKey] = conversation.id
      aiChatMessage = "已切换 AI 对话。"
      store.save()
      return true
    }
    guard store.drafts.contains(where: { $0.id == draftID }) else {
      aiChatMessage = "这条 AI 对话对应的文章已不存在。"
      return false
    }

    if aiChatDraftID == draftID,
      activeAIChatConversationID(for: draftID) == conversationID
    {
      return true
    }

    cacheCurrentAIChatSessionForAIStore()
    if store.selectedDraftID != draftID {
      guard store.focusDraft(draftID, section: .writing) else {
        aiChatMessage = "无法打开这条 AI 对话对应的文章。"
        return false
      }
    }
    aiChatDraftID = draftID
    activeAIConversationIDsByDraftID[draftID] = conversation.id
    applyCurrentAIChatSession(conversation.sessionState)
    aiChatManualRetryState = nil
    aiChatMessage = "已切换 AI 对话。"
    store.save()
    return true
  }

  @discardableResult
  public func archiveAIChatConversation(_ conversationID: UUID) -> Bool {
    guard let index = aiConversations.firstIndex(where: { $0.id == conversationID }) else {
      aiChatMessage = "找不到要归档的 AI 对话。"
      return false
    }
    let scope = aiConversations[index].scope
    let draftID = aiConversations[index].draftID
    let isActive = activeConversationID(for: scope) == conversationID
    guard !isActive || !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再归档这条对话。"
      return false
    }
    if aiConversations[index].isArchived {
      return true
    }
    guard !blockChatMutationForDeliveryUncertainty(conversationID: conversationID) else {
      return false
    }

    let now = Date()
    var updatedConversations = aiConversations
    updatedConversations[index].archivedAt = now
    updatedConversations[index].updatedAt = now
    aiConversations = updatedConversations
    if isActive {
      if let draftID {
        activateMostRecentAIChatConversation(for: draftID)
      } else {
        activateMostRecentGeneralAIChatConversation()
      }
    }
    aiChatMessage = "已归档 AI 对话。"
    store.save()
    return true
  }

  @discardableResult
  public func restoreAIChatConversation(_ conversationID: UUID) -> Bool {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再恢复对话。"
      return false
    }
    guard
      let index = aiConversations.firstIndex(where: {
        $0.id == conversationID && $0.isArchived
      })
    else {
      aiChatMessage = "找不到要恢复的 AI 对话。"
      return false
    }

    let now = Date()
    let scope = aiConversations[index].scope
    let draftID = aiConversations[index].draftID
    var updatedConversations = aiConversations
    updatedConversations[index].archivedAt = nil
    updatedConversations[index].updatedAt = now
    aiConversations = updatedConversations
    if let draftID {
      activeAIConversationIDsByDraftID[draftID] = conversationID
    } else {
      activeAIConversationIDsByScope[scope.storageKey] = conversationID
    }
    if aiChatDraftID == draftID,
      let restored = aiConversations.first(where: { $0.id == conversationID })
    {
      applyCurrentAIChatSession(restored.sessionState)
      aiChatManualRetryState = nil
    }
    aiChatMessage = "已恢复 AI 对话。"
    store.save()
    return true
  }

  @discardableResult
  public func deleteAIChatConversation(_ conversationID: UUID) -> Bool {
    guard let conversation = aiConversations.first(where: { $0.id == conversationID }) else {
      aiChatMessage = "找不到要删除的 AI 对话。"
      return false
    }
    let isActive = activeConversationID(for: conversation.scope) == conversationID
    guard !isActive || !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再删除这条对话。"
      return false
    }
    guard !blockChatMutationForDeliveryUncertainty(conversationID: conversationID) else {
      return false
    }

    aiConversations.removeAll { $0.id == conversationID }
    if isActive {
      if let draftID = conversation.draftID {
        activateMostRecentAIChatConversation(for: draftID)
      } else {
        activateMostRecentGeneralAIChatConversation()
      }
    }
    aiChatMessage = "已删除 AI 对话。"
    store.save()
    return true
  }

  public func setAIChatFocusedParagraph(_ paragraphID: String?, draft: ArticleDraft? = nil) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard aiChatDraftID != nil else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }

    aiChatFocusedParagraphID = paragraphID?.nilIfEmpty
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = aiChatFocusedParagraphID == nil ? "AI 已恢复整篇文章上下文。" : "AI 已聚焦引用段落。"
    store.save()
  }

  @discardableResult
  public func saveAIChatCustomPrompt(
    title: String,
    prompt: String
  ) -> AIPublishingCustomPrompt? {
    let trimmedPrompt = prompt.trimmedForPublishing
    guard !trimmedPrompt.isEmpty else {
      store.setAIChatMessage("提示内容为空，未保存。")
      return nil
    }

    let resolvedTitle =
      title.trimmedForPublishing.nilIfEmpty
      ?? trimmedPrompt.components(separatedBy: .newlines).first?.trimmedForPublishing.nilIfEmpty
      ?? "自定义提示"
    let customPrompt = AIPublishingCustomPrompt(
      title: String(resolvedTitle.prefix(40)),
      prompt: trimmedPrompt
    )
    var updatedPrompts = aiChatCustomPrompts
    updatedPrompts.removeAll {
      $0.prompt == customPrompt.prompt || $0.title == customPrompt.title
    }
    updatedPrompts.insert(customPrompt, at: 0)
    aiChatCustomPrompts = Array(updatedPrompts.prefix(80))
    store.setAIChatMessage("已保存自定义提示：\(customPrompt.title)")
    store.save()
    return customPrompt
  }

  public func deleteAIChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    var updatedPrompts = aiChatCustomPrompts
    let originalCount = updatedPrompts.count
    updatedPrompts.removeAll { $0.id == promptID }
    guard updatedPrompts.count < originalCount else {
      store.setAIChatMessage("找不到要删除的自定义提示。")
      return
    }
    aiChatCustomPrompts = updatedPrompts
    store.setAIChatMessage("已删除自定义提示。")
    store.save()
  }

  @discardableResult
  public func startNewAIChatConversation(
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    guard !isAIChatRunning else {
      aiChatMessage = "请先停止当前 AI 回复，再新建对话。"
      return nil
    }
    if let draft {
      prepareAIChat(for: draft)
    }
    guard let draftID = aiChatDraftID else {
      aiChatMessage = "请先选择一篇文章。"
      return nil
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: activeAIChatConversationID(for: draftID)
      )
    else {
      return nil
    }

    cacheCurrentAIChatSessionForAIStore()
    let now = Date()
    let conversation = AIConversation(
      draftID: draftID,
      contextMode: aiChatContextMode,
      knowledgePolicy: aiChatKnowledgePolicy,
      modelGrade: aiChatModelGrade,
      reasoningLevel: aiChatReasoningLevel,
      selectedModel: aiChatSelectedModel,
      focusedParagraphID: aiChatFocusedParagraphID,
      createdAt: now
    )
    aiConversations.append(conversation)
    activeAIConversationIDsByDraftID[draftID] = conversation.id
    applyCurrentAIChatSession(conversation.sessionState)
    aiChatMessage = "已新建 AI 对话。"
    store.save()
    return conversation
  }

  public func deleteAIChatMessage(
    _ messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) {
    if let draft {
      prepareAIChat(for: draft)
    }

    guard let draftID = store.aiChatDraftID else {
      store.setAIChatMessage("请先选择一篇文章。")
      return
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: activeAIChatConversationID(for: draftID)
      )
    else {
      return
    }

    if store.aiChatDraftID == draftID {
      let originalCount = store.aiChatMessages.count
      let updatedMessages = store.aiChatMessages.filter { $0.id != messageID }
      guard updatedMessages.count < originalCount else {
        store.setAIChatMessage("找不到要删除的 AI 消息。")
        return
      }

      store.setAIChatMessages(updatedMessages)
      cacheCurrentAIChatSessionForAIStore()
      store.setAIChatMessage("已删除 1 条 AI 消息。")
      store.save()
      return
    }

    guard var state = aiChatSessionState(for: draftID) else {
      store.setAIChatMessage("找不到要删除的 AI 消息。")
      return
    }

    let originalCount = state.messages.count
    state.messages = state.messages.filter { $0.id != messageID }
    guard state.messages.count < originalCount else {
      store.setAIChatMessage("找不到要删除的 AI 消息。")
      return
    }

    if state.shouldCache {
      setAIChatSessionState(state, for: draftID)
    } else {
      removeAIChatSessionState(for: draftID)
    }

    store.setAIChatMessage("已删除 1 条 AI 消息。")
    store.save()
  }

  @discardableResult
  public func branchAIChatConversation(
    after messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    guard !isAIChatRunning else {
      store.setAIChatMessage("请先停止当前 AI 回复，再创建对话分支。")
      return nil
    }
    if let draft {
      prepareAIChat(for: draft)
    }

    guard let draftID = store.aiChatDraftID else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }
    guard let index = store.aiChatMessages.firstIndex(where: { $0.id == messageID }) else {
      store.setAIChatMessage("找不到要分支的 AI 消息。")
      return nil
    }

    cacheCurrentAIChatSessionForAIStore()
    let now = Date()
    let branchTitle = aiChatConversationTitle.map {
      String("\($0) · 分支".prefix(80))
    }
    let branchMessages = agentSafeBranchMessages(
      Array(store.aiChatMessages.prefix(index + 1)),
      at: now
    )
    let conversation = AIConversation(
      draftID: draftID,
      title: branchTitle,
      messages: branchMessages,
      contextMode: aiChatContextMode,
      knowledgePolicy: aiChatKnowledgePolicy,
      modelGrade: aiChatModelGrade,
      reasoningLevel: aiChatReasoningLevel,
      selectedModel: aiChatSelectedModel,
      focusedParagraphID: aiChatFocusedParagraphID,
      createdAt: now
    ).prepared()
    aiConversations.append(conversation)
    activeAIConversationIDsByDraftID[draftID] = conversation.id
    applyCurrentAIChatSession(conversation.sessionState)
    store.setAIChatMessage("已从所选消息创建分支。")
    store.save()
    return conversation
  }

  private func agentSafeBranchMessages(
    _ messages: [AIPublishingChatMessage],
    at date: Date
  ) -> [AIPublishingChatMessage] {
    messages.map { message in
      guard
        message.agentContinuation != nil
          || message.automationPlan?.source == .agentLoop
      else {
        return message
      }
      var copy = message
      copy.agentContinuation = nil
      if var plan = copy.automationPlan {
        for index in plan.steps.indices where !plan.steps[index].status.isTerminal {
          plan.steps[index].status = .cancelled
          plan.steps[index].resultMessage = CoreL10n.text(
            "对话分支不会复制未完成的 Agent 操作。"
          )
        }
        copy.automationPlan = plan
      }
      for index in copy.toolRuns.indices
      where copy.toolRuns[index].status == .awaitingConfirmation {
        copy.toolRuns[index].status = .cancelled
        copy.toolRuns[index].completedAt = date
        copy.toolRuns[index].summary = CoreL10n.text(
          "对话分支不会复制未完成的 Agent 操作。"
        )
      }
      return copy
    }
  }

  public func cancelAIChatReply() {
    _ = requestAIChatCancellation()
  }

  public func cancelAIChatReply(expectedOwnerToken: UUID) {
    _ = requestAIChatCancellation(expectedOwnerToken: expectedOwnerToken)
  }

  @discardableResult
  public func retryLastFailedAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    draft: ArticleDraft? = nil,
    ownerToken: UUID? = nil,
    expectedContextMode: AIPublishingChatContextMode? = nil
  ) async -> AIPublishingChatMessage? {
    guard expectedContextMode == nil || expectedContextMode == aiChatContextMode else {
      store.setAIChatMessage(
        CoreL10n.text("AI 对话上下文已变化，本次未发送，请重试。")
      )
      return nil
    }
    guard let retryState = aiChatManualRetryState else {
      store.setAIChatMessage("当前没有可重试的 AI 请求。")
      return nil
    }
    guard let chatDraft = draft ?? store.selectedDraft,
      chatDraft.id == retryState.draftID
    else {
      store.setAIChatMessage("请先返回发生错误的文章，再重试 AI 回复。")
      return nil
    }
    guard activeAIChatConversationID(for: chatDraft.id) == retryState.conversationID else {
      store.setAIChatMessage("请先切回发生错误的 AI 对话，再重试回复。")
      return nil
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: retryState.conversationID
      )
    else {
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

    aiChatManualRetryState = nil
    return await regenerateLastAIChatReply(
      draft: chatDraft,
      ownerToken: ownerToken
    )
  }

  @discardableResult
  public func regenerateLastAIChatReply(
    draft: ArticleDraft? = nil,
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatQuickHideOperationMessage())
      return nil
    }

    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }
    guard store.aiChatDraftID == chatDraft.id else {
      prepareAIChat(for: chatDraft)
      store.setAIChatMessage("当前文章还没有可重新生成的 AI 回复。")
      return nil
    }
    guard store.aiChatMessages.contains(where: { $0.role == .user }) else {
      store.setAIChatMessage("当前对话还没有用户消息。")
      return nil
    }
    cacheCurrentAIChatSessionForAIStore()
    guard let conversationIdentity = aiChatConversationIdentity(for: chatDraft.id) else {
      store.setAIChatMessage("找不到可重新生成的 AI 对话。")
      return nil
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: conversationIdentity.conversationID
      )
    else {
      return nil
    }
    guard
      let operationID = beginAIChatOperation(
        statusMessage: "AI 正在重新生成回复...",
        ownerToken: ownerToken
      )
    else {
      return nil
    }

    let originalMessages =
      aiChatSessionState(for: conversationIdentity)?.messages
      ?? store.aiChatMessages
    updateAIChatSession(for: conversationIdentity) { messages in
      while messages.last?.role == .assistant {
        messages.removeLast()
      }
    }

    let reply = await generateAIChatReply(
      for: chatDraft,
      conversationIdentity: conversationIdentity,
      operationID: operationID
    )
    if reply == nil {
      updateAIChatSession(for: conversationIdentity) { messages in
        messages = originalMessages
      }
      store.save()
    }
    return reply
  }

  @discardableResult
  public func regenerateAIChatReply(
    messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatQuickHideOperationMessage())
      return nil
    }

    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }
    guard store.aiChatDraftID == chatDraft.id else {
      prepareAIChat(for: chatDraft)
      store.setAIChatMessage("当前文章还没有可重新生成的 AI 回复。")
      return nil
    }
    guard
      let assistantIndex = store.aiChatMessages.firstIndex(where: {
        $0.id == messageID && $0.role == .assistant
      })
    else {
      store.setAIChatMessage("找不到可重新生成的 AI 回复。")
      return nil
    }
    guard
      let userIndex = store.aiChatMessages[..<assistantIndex].lastIndex(where: { $0.role == .user })
    else {
      store.setAIChatMessage("找不到可重新生成的用户问题。")
      return nil
    }
    cacheCurrentAIChatSessionForAIStore()
    guard let conversationIdentity = aiChatConversationIdentity(for: chatDraft.id) else {
      store.setAIChatMessage("找不到可重新生成的 AI 对话。")
      return nil
    }
    guard
      !blockChatMutationForDeliveryUncertainty(
        conversationID: conversationIdentity.conversationID
      )
    else {
      return nil
    }
    guard
      let operationID = beginAIChatOperation(
        statusMessage: "AI 正在重新生成此回复..."
      )
    else {
      return nil
    }

    let originalMessages =
      aiChatSessionState(for: conversationIdentity)?.messages
      ?? store.aiChatMessages
    updateAIChatSession(for: conversationIdentity) { messages in
      messages = Array(messages.prefix(userIndex + 1))
    }
    let reply = await generateAIChatReply(
      for: chatDraft,
      conversationIdentity: conversationIdentity,
      operationID: operationID
    )
    if reply == nil {
      updateAIChatSession(for: conversationIdentity) { messages in
        messages = originalMessages
      }
      store.save()
    }
    return reply
  }

}
