import Foundation
import PublishingKnowledgeCore

enum AIGenerationLane: Hashable, Sendable {
  case action
  case metadata(UUID)
  case imageText(UUID)
  case writingStyle
  case connectionTest
}

extension WorkbenchAIStore {
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
    switch lane {
    case .metadata(let id): return aiMetadataSuggestionGenerationsByDraftID[id]
    case .imageText(let id): return aiImageTextSuggestionGenerationsByDraftID[id]
    default: return aiRequestGenerations[lane]
    }
  }

  func beginAIRequest(_ lane: AIGenerationLane, showsActionLoading: Bool = false) -> UInt64 {
    if let previous = currentAIRequestGeneration(lane) {
      cancelAIRequest(lane, generation: previous)
    }
    let generation: UInt64
    switch lane {
    case .metadata(let id): generation = beginAIMetadataSuggestionOperation(for: id)
    case .imageText(let id): generation = beginAIImageTextSuggestionOperation(for: id)
    default:
      generation = nextAIRequestGeneration()
      aiRequestGenerations[lane] = generation
    }
    aiRequestPresentationGeneration = generation
    if showsActionLoading { aiRequestActionOperations[lane] = beginAIActionOperation() }
    if lane == .writingStyle { isAIWritingStyleExtractionRunning = true }
    return generation
  }

  func checkAIRequest(_ lane: AIGenerationLane, generation: UInt64) throws {
    try Task.checkCancellation()
    guard currentAIRequestGeneration(lane) == generation, store.canUseProtectedWorkbench,
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
    aiRequestBaselines[lane] = baseline
    aiRequestProfiles[lane] = profile
    let config = store.aiProviderConfig(for: profile)
    aiRequestContextChecks[lane] = { [weak self] in
      guard let self else { return false }
      return self.store.aiProviderConfig(for: profile) == config
    }
  }

  private func aiRequestContextMatches(_ lane: AIGenerationLane) -> Bool {
    guard aiRequestContextChecks[lane]?() != false else { return false }
    guard let baseline = aiRequestBaselines[lane], let profile = aiRequestProfiles[lane] else {
      return true
    }
    return draftOperationStillMatches(baseline, profile: profile)
  }

  func canPresentAIRequest(_ lane: AIGenerationLane, generation: UInt64) -> Bool {
    !Task.isCancelled && store.canUseProtectedWorkbench
      && currentAIRequestGeneration(lane) == generation
      && aiRequestPresentationGeneration == generation
      && aiRequestContextMatches(lane)
  }

  func finishAIRequest(_ lane: AIGenerationLane, generation: UInt64) {
    guard currentAIRequestGeneration(lane) == generation else { return }
    aiRequestCancellations.removeValue(forKey: lane)
    aiRequestBaselines.removeValue(forKey: lane)
    aiRequestProfiles.removeValue(forKey: lane)
    aiRequestContextChecks.removeValue(forKey: lane)
    if aiPublishingActionRequest?.generation == generation {
      aiPublishingActionRequest = nil
    }
    if let operation = aiRequestActionOperations.removeValue(forKey: lane) {
      finishAIActionOperation(operation)
    }
    switch lane {
    case .metadata(let id): finishAIMetadataSuggestionOperation(for: id, generation: generation)
    case .imageText(let id): finishAIImageTextSuggestionOperation(for: id, generation: generation)
    case .writingStyle: isAIWritingStyleExtractionRunning = false
    default: break
    }
  }

  func cancelAIRequest(_ lane: AIGenerationLane, generation: UInt64) {
    guard currentAIRequestGeneration(lane) == generation else { return }
    aiRequestCancellations[lane]?()
    finishAIRequest(lane, generation: generation)
    switch lane {
    case .metadata(let id): aiMetadataSuggestionGenerationsByDraftID.removeValue(forKey: id)
    case .imageText(let id): aiImageTextSuggestionGenerationsByDraftID.removeValue(forKey: id)
    default: aiRequestGenerations.removeValue(forKey: lane)
    }
  }

  func cancelAIGenerationRequests() {
    let lanes = Set(aiRequestGenerations.keys)
      .union(aiMetadataSuggestionGenerationsByDraftID.keys.map(AIGenerationLane.metadata))
      .union(aiImageTextSuggestionGenerationsByDraftID.keys.map(AIGenerationLane.imageText))
    for lane in lanes {
      if let generation = currentAIRequestGeneration(lane) {
        cancelAIRequest(lane, generation: generation)
      }
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
    aiRequestCancellations[lane] = cancel
    switch lane {
    case .metadata(let id):
      registerAIMetadataSuggestionCancellationHandler(
        for: id, generation: generation, handler: cancel)
    case .imageText(let id):
      registerAIImageTextSuggestionCancellationHandler(
        for: id, generation: generation, handler: cancel)
    default: break
    }
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
