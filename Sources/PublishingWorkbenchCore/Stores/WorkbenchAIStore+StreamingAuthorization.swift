import Foundation

extension WorkbenchAIStore {
  func finishAIChatOperation(_ operationID: UUID) {
    guard aiChatOperationCoordinator.finish(operationID) else { return }
    if activeStreamingAuthorization?.operationID == operationID {
      activeStreamingAuthorization?.cancellation.finish()
      activeStreamingAuthorization = nil
    }
    store.setAIChatRunning(false)
    store.save()
  }

  struct ActiveStreamingAuthorization {
    let operationID: UUID
    let config: AIProviderConfig
    let connectionID: UUID?
    let cancellation: AIChatStreamingRequestCancellation
    var hasCapturedCredential = false
  }

  func checkAIChatOperation(_ operationID: UUID) throws {
    try aiChatOperationCoordinator.check(operationID)
  }

  func setAIChatCancellationRequested(_ value: Bool) {
    aiChatOperationCoordinator.setCancellationRequested(value)
  }

  func aiChatCancellationRequested() -> Bool {
    aiChatOperationCoordinator.isCancellationRequested
  }

  func bindAIChatAuthorization(operationID: UUID, target: WorkbenchTaskTarget?) {
    let config: AIProviderConfig
    let connectionID: UUID?
    switch target {
    case .draft(let id), .articleConversation(let id, _):
      guard let draft = store.drafts.first(where: { $0.id == id }) else { return }
      let profile = store.profile(for: draft)
      config = store.aiProviderConfig(for: profile)
      connectionID = profile.aiConnectionProfileID
    case .generalAIConversation(let id):
      guard let conversation = aiConversations.first(where: { $0.id == id }),
        let id = conversation.connectionProfileID,
        let connection = store.aiConnectionProfile(for: id)
      else { return }
      config = connection.config
      connectionID = id
    default: return
    }
    bindAIChatAuthorization(
      operationID: operationID,
      config: AIOutboundPayloadPrivacyService().sanitizedProviderConfig(config),
      connectionID: connectionID
    )
  }

  /// Both transport modes share the operation's revocation lifetime, starting
  /// before context assembly or payload approval can suspend.
  @discardableResult
  func bindAIChatAuthorization(
    operationID: UUID, config: AIProviderConfig, connectionID: UUID?
  ) -> AIChatStreamingRequestCancellation {
    if let active = activeStreamingAuthorization, active.operationID == operationID {
      return active.cancellation
    }
    let cancellation = AIChatStreamingRequestCancellation()
    activeStreamingAuthorization = ActiveStreamingAuthorization(
      operationID: operationID, config: config, connectionID: connectionID,
      cancellation: cancellation
    )
    return cancellation
  }

  func cancelStreamingAuthorization(
    connectionID: UUID? = nil, destination: String? = nil, remoteOnly: Bool = false,
    profileID: UUID? = nil, revokedConfig: AIProviderConfig? = nil,
    requiresAPIKeyOnly: Bool = false, requiresCapturedCredential: Bool = false
  ) {
    guard let active = activeStreamingAuthorization,
      connectionID == nil || connectionID == active.connectionID,
      destination == nil || destination == active.config.dataSharingDestination,
      !remoteOnly || !active.config.isLocalEndpoint,
      !requiresAPIKeyOnly || active.config.requiresAPIKey,
      !requiresCapturedCredential || active.hasCapturedCredential,
      revokedConfig == nil
        || active.config.dataSharingConsentIdentifier
          == revokedConfig?.dataSharingConsentIdentifier,
      profileID == nil || activeAIChatArticleProfileID == profileID
    else { return }
    active.cancellation.cancel()
    _ = requestAIChatCancellation(expectedOperationID: active.operationID)
  }

  func cancelArticleStreamingAuthorization(profileID: UUID) {
    cancelStreamingAuthorization(profileID: profileID)
  }

  private var activeAIChatArticleProfileID: UUID? {
    let draftID: UUID
    switch activeAIChatOperationTarget {
    case .draft(let id), .articleConversation(let id, _):
      draftID = id
    default:
      return nil
    }
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else { return nil }
    return store.profile(for: draft).id
  }

  /// Prepared requests retain a frozen payload, not an enduring grant. Recheck
  /// the live operation, knowledge permissions and credential before every POST.
  func authorizedChatAssistant(
    operationID: UUID,
    config: AIProviderConfig,
    connectionID: UUID?,
    knowledgeBindings: [KnowledgeAuthorizationBinding],
    knowledgePolicy: KnowledgeRetrievalPolicy,
    apiKey: String?,
    currentAPIKey: @escaping @MainActor @Sendable () throws -> String?
  ) -> AIPublishingAssistantService {
    let cancellation = bindAIChatAuthorization(
      operationID: operationID, config: config, connectionID: connectionID
    )
    // Credential lookup follows payload approval. Rotation before this point
    // can still use the new key; a frozen attempt must be cancelled instead.
    activeStreamingAuthorization?.hasCapturedCredential = true
    let authorization: @Sendable () async throws -> Void = { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      try self.checkAIChatOperation(operationID)
      try await self.requireValidAIKnowledgeAuthorization(
        knowledgeBindings,
        policy: knowledgePolicy
      )
      try self.checkAIChatOperation(operationID)
      guard self.activeStreamingAuthorization?.operationID == operationID,
        self.activeStreamingAuthorization?.config == config,
        self.activeStreamingAuthorization?.connectionID == connectionID
      else { throw AIOutboundPayloadConfirmationError.drifted }
      // A rotated key must not authorize sending the captured old credential.
      guard try currentAPIKey() == apiKey else {
        throw AIOutboundPayloadConfirmationError.drifted
      }
      try self.checkAIChatOperation(operationID)
    }
    return aiPublishingAssistantService.cancellingStreamingRequests(with: cancellation)
      .authorizingStreamingRequests(authorization)
      .authorizingNonStreamingRequests(authorization)
  }

}
