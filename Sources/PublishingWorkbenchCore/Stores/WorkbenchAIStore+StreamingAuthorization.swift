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
  }

  func cancelStreamingAuthorization(
    connectionID: UUID? = nil, destination: String? = nil, remoteOnly: Bool = false
  ) {
    guard let active = activeStreamingAuthorization,
      connectionID == nil || connectionID == active.connectionID,
      destination == nil || destination == active.config.dataSharingDestination,
      !remoteOnly || !active.config.isLocalEndpoint
    else { return }
    active.cancellation.cancel()
    _ = requestAIChatCancellation(expectedOperationID: active.operationID)
  }

  func cancelArticleStreamingAuthorization(profileID: UUID) {
    let draftID: UUID
    switch activeAIChatOperationTarget {
    case .draft(let id), .articleConversation(let id, _):
      draftID = id
    default:
      return
    }
    guard let draft = store.drafts.first(where: { $0.id == draftID }),
      store.profile(for: draft).id == profileID
    else { return }
    cancelStreamingAuthorization()
  }

  /// Prepared requests retain a frozen payload, not an enduring grant. Recheck
  /// the live operation, knowledge permissions and credential before every POST.
  func streamingAssistant(
    operationID: UUID,
    config: AIProviderConfig,
    connectionID: UUID?,
    knowledgeBindings: [KnowledgeAuthorizationBinding],
    knowledgePolicy: KnowledgeRetrievalPolicy,
    apiKey: String?,
    currentAPIKey: @escaping @MainActor @Sendable () throws -> String?
  ) -> AIPublishingAssistantService {
    let cancellation = AIChatStreamingRequestCancellation()
    activeStreamingAuthorization = ActiveStreamingAuthorization(
      operationID: operationID, config: config, connectionID: connectionID,
      cancellation: cancellation
    )
    return aiPublishingAssistantService.cancellingStreamingRequests(with: cancellation)
      .authorizingStreamingRequests { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        try self.checkAIChatOperation(operationID)
        try await self.requireValidAIKnowledgeAuthorization(
          knowledgeBindings,
          policy: knowledgePolicy
        )
        try self.checkAIChatOperation(operationID)
        // A rotated key must not authorize sending the captured old credential.
        guard try currentAPIKey() == apiKey else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        try self.checkAIChatOperation(operationID)
      }
  }

}
