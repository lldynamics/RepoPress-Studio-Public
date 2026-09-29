import Foundation

/// Compatibility endpoints for persisted Agent history. No endpoint can execute,
/// resume, or alter the old checkpoint; new writing requests remain available.
extension WorkbenchAIStore {
  @discardableResult
  public func abandonAgentContinuation(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    expectedRevision: Int
  ) -> Bool {
    store.setAIChatMessage(AIAgentRetirement.message)
    return false
  }

  func blockChatMutationForDeliveryUncertainty(conversationID: UUID?) -> Bool {
    // Delivery uncertainty is historical now: nothing is resumed or replayed.
    false
  }
}
