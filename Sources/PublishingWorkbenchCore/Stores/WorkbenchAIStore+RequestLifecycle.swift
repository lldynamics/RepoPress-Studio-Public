import Foundation
import PublishingKnowledgeCore

enum AIGenerationLane: Hashable, Sendable {
  case action
  case metadata(UUID)
  case writingStyle
  case connectionTest
  case modelDiscovery(UUID)
}

struct AINonStreamingAuthorizationBinding: Sendable {
  let profileID: UUID
  let connectionID: UUID?
  let config: AIProviderConfig
}

struct AINonStreamingDraftBinding {
  let baseline: DraftOperationBaseline
  let profile: SiteProfile
}

/// One lane owns its generation and every resource needed to finish or cancel
/// it. Removing a record invalidates late completions and releases its context.
struct AINonStreamingRequestRecord {
  let generation: UInt64
  var cancellation: (() -> Void)?
  var actionOperationID: UUID?
  var draftBinding: AINonStreamingDraftBinding?
  var contextCheck: (() -> Bool)?
  var authorization: AINonStreamingAuthorizationBinding?
}

extension WorkbenchAIStore {
  /// Capture the selected connection before any baseline or knowledge await.
  /// A later revoke can then cancel even a request still preparing its payload.
  func bindNonStreamingAuthorization(
    _ lane: AIGenerationLane, profile: SiteProfile
  ) -> AINonStreamingAuthorizationBinding {
    let binding = AINonStreamingAuthorizationBinding(
      profileID: profile.id,
      connectionID: profile.aiConnectionProfileID,
      config: store.aiProviderConfig(for: profile)
    )
    aiRequests[lane]?.authorization = binding
    return binding
  }

  /// Called by the client before every actual POST, including a retry. This
  /// synchronous check follows the async knowledge check so no suspension can
  /// turn a revoked grant or rotated key into a valid send.
  func checkNonStreamingAuthorization(
    _ binding: AINonStreamingAuthorizationBinding,
    apiKey: String?,
    lane: AIGenerationLane,
    generation: UInt64
  ) throws {
    try checkAIRequest(lane, generation: generation)
    guard aiRequests[lane]?.authorization?.profileID == binding.profileID,
      aiRequests[lane]?.authorization?.connectionID == binding.connectionID,
      aiRequests[lane]?.authorization?.config == binding.config,
      let liveProfile = store.profiles.first(where: { $0.id == binding.profileID }),
      liveProfile.aiConnectionProfileID == binding.connectionID
    else { throw AIOutboundPayloadConfirmationError.drifted }
    if let connectionID = binding.connectionID {
      guard let connection = store.aiConnectionProfile(for: connectionID),
        connection.config == binding.config
      else { throw AIOutboundPayloadConfirmationError.drifted }
    } else {
      guard liveProfile.aiProviderConfig == binding.config
      else { throw AIOutboundPayloadConfirmationError.drifted }
    }
    let consent = aiDataSharingConsentStore.presentation(for: binding.config)
    guard consent.isGranted else {
      throw AIPublishingAssistantError.dataSharingConsentRequired(
        providerName: consent.providerName,
        destination: consent.destination
      )
    }
    guard try aiChatAvailableAPIKey(for: liveProfile) == apiKey else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    try checkAIRequest(lane, generation: generation)
  }

  func cancelNonStreamingAuthorization(
    connectionID: UUID? = nil,
    profileID: UUID? = nil,
    revokedConfig: AIProviderConfig? = nil,
    remoteOnly: Bool = false,
    requiresAPIKeyOnly: Bool = false,
    requiresCapturedCredential: Bool = false
  ) {
    cancelStreamingAuthorization(
      connectionID: connectionID, remoteOnly: remoteOnly, profileID: profileID,
      revokedConfig: revokedConfig, requiresAPIKeyOnly: requiresAPIKeyOnly,
      requiresCapturedCredential: requiresCapturedCredential
    )
    for (lane, request) in aiRequests {
      guard let binding = request.authorization,
        connectionID == nil || binding.connectionID == connectionID,
        profileID == nil || binding.profileID == profileID,
        revokedConfig == nil
          || binding.config.dataSharingConsentIdentifier
            == revokedConfig?.dataSharingConsentIdentifier,
        !remoteOnly || !binding.config.isLocalEndpoint,
        !requiresAPIKeyOnly || binding.config.requiresAPIKey
      else { continue }
      cancelAIRequest(lane, generation: request.generation)
    }
  }

  func beginPublishingAIRequest(_ lane: AIGenerationLane) -> UInt64 {
    if let previous = aiPublishingActionRequest {
      cancelAIRequest(previous.lane, generation: previous.generation)
    }
    let generation = beginAIRequest(lane, showsActionLoading: true)
    aiPublishingActionRequest = (lane, generation)
    return generation
  }
  /// Store-wide monotonic IDs prevent delete/reinsert of a draft from reusing
  /// an in-flight generation. Per-draft lanes still allow independent requests.
  func nextAIRequestGeneration() -> UInt64 {
    aiRequestGeneration &+= 1
    return aiRequestGeneration
  }

  func currentAIRequestGeneration(_ lane: AIGenerationLane) -> UInt64? {
    aiRequests[lane]?.generation
  }

  func beginAIRequest(
    _ lane: AIGenerationLane,
    showsActionLoading: Bool = false,
    updatesPresentation: Bool = true
  ) -> UInt64 {
    if let previous = currentAIRequestGeneration(lane) {
      cancelAIRequest(lane, generation: previous)
    }
    let generation = nextAIRequestGeneration()
    aiRequests[lane] = AINonStreamingRequestRecord(
      generation: generation,
      actionOperationID: showsActionLoading ? beginAIActionOperation() : nil
    )
    if updatesPresentation { aiRequestPresentationGeneration = generation }
    switch lane {
    case .metadata(let id): startAIMetadataSuggestionPresentation(for: id)
    case .writingStyle: isAIWritingStyleExtractionRunning = true
    default: break
    }
    return generation
  }

  func checkAIRequest(_ lane: AIGenerationLane, generation: UInt64) throws {
    try Task.checkCancellation()
    guard currentAIRequestGeneration(lane) == generation,
      aiRequestContextMatches(lane)
    else {
      throw CancellationError()
    }
  }

  /// Automatic knowledge context is authorized again immediately before a
  /// publishing action crosses the transport boundary. The policy check is
  /// separate: `.off` intentionally still permits explicit chat references.
  func checkPublishingKnowledgeAuthorization(
    _ snapshot: KnowledgeContextSnapshot?,
    policy: KnowledgeRetrievalPolicy,
    lane: AIGenerationLane,
    generation: UInt64
  ) async throws {
    try checkAIRequest(lane, generation: generation)
    guard aiChatKnowledgePolicy == policy else {
      throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
    }
    try await requireValidAIKnowledgeAuthorization(
      snapshot?.authorizationBindings ?? [], policy: policy
    )
    // The authoritative read itself suspends. Do not let cancellation, a
    // draft edit or a policy change during that read pass the send boundary.
    try checkAIRequest(lane, generation: generation)
    guard aiChatKnowledgePolicy == policy else {
      throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
    }
  }

  func bindAIRequest(
    _ lane: AIGenerationLane, baseline: DraftOperationBaseline, profile: SiteProfile
  ) {
    aiRequests[lane]?.draftBinding = AINonStreamingDraftBinding(
      baseline: baseline, profile: profile
    )
    let config = store.aiProviderConfig(for: profile)
    aiRequests[lane]?.contextCheck = { [weak self] in
      guard let self else { return false }
      return self.store.aiProviderConfig(for: profile) == config
    }
  }

  private func aiRequestContextMatches(_ lane: AIGenerationLane) -> Bool {
    guard let request = aiRequests[lane], request.contextCheck?() != false else { return false }
    guard let binding = request.draftBinding else { return true }
    return draftOperationStillMatches(binding.baseline, profile: binding.profile)
  }

  func canPresentAIRequest(_ lane: AIGenerationLane, generation: UInt64) -> Bool {
    !Task.isCancelled
      && currentAIRequestGeneration(lane) == generation
      && aiRequestPresentationGeneration == generation
      && aiRequestContextMatches(lane)
  }

  func finishAIRequest(_ lane: AIGenerationLane, generation: UInt64) {
    guard let request = aiRequests[lane], request.generation == generation else { return }
    aiRequests.removeValue(forKey: lane)
    if aiPublishingActionRequest?.generation == generation {
      aiPublishingActionRequest = nil
    }
    if let operation = request.actionOperationID {
      finishAIActionOperation(operation)
    }
    switch lane {
    case .metadata(let id): finishAIMetadataSuggestionPresentation(for: id)
    case .writingStyle: isAIWritingStyleExtractionRunning = false
    default: break
    }
  }

  func cancelAIRequest(_ lane: AIGenerationLane, generation: UInt64) {
    guard let request = aiRequests[lane], request.generation == generation else { return }
    finishAIRequest(lane, generation: generation)
    request.cancellation?()
  }

  func cancelAIGenerationRequests() {
    for (lane, request) in aiRequests {
      cancelAIRequest(lane, generation: request.generation)
    }
  }

  /// Own the entire async preparation/transport phase. Cancellation clears its
  /// loading state immediately, even when a provider ignores task cancellation.
  /// Both successful and failed late completions become CancellationError.
  func awaitAIRequest<Value: Sendable>(
    _ lane: AIGenerationLane,
    generation: UInt64,
    operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    try checkAIRequest(lane, generation: generation)
    let worker = Task {
      try self.checkAIRequest(lane, generation: generation)
      return try await operation()
    }
    let cancel = { worker.cancel() }
    aiRequests[lane]?.cancellation = cancel
    return try await withTaskCancellationHandler {
      do {
        let value = try await worker.value
        try checkAIRequest(lane, generation: generation)
        return value
      } catch {
        try checkAIRequest(lane, generation: generation)
        throw error
      }
    } onCancel: {
      worker.cancel()
      Task { @MainActor in self.cancelAIRequest(lane, generation: generation) }
    }
  }
}
