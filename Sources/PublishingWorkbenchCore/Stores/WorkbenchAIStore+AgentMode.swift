import Foundation

/// Per-conversation Agent mode is deliberately kept separate from the
/// connection settings.  This API can only narrow an existing conversation's
/// authority; missing and archived conversations fail closed.
extension WorkbenchAIStore {
  /// Returns the mode for a live conversation.  Archived or unknown IDs are
  /// intentionally indistinguishable from a missing value to callers.
  public func aiConversationAgentMode(
    for conversationID: UUID
  ) -> AIConversationAgentMode? {
    aiConversations.first {
      $0.id == conversationID && !$0.isArchived
    }?.agentMode
  }

  /// Updates the mode for one live conversation and persists the change.
  /// `textOnly` is the only stricter mode; neither this method nor the model
  /// can grant tools when the connection-level switch is disabled.
  @discardableResult
  public func setAIConversationAgentMode(
    _ mode: AIConversationAgentMode,
    for conversationID: UUID
  ) -> Bool {
    guard
      let index = aiConversations.firstIndex(where: {
        $0.id == conversationID && !$0.isArchived
      })
    else {
      return false
    }

    guard aiConversations[index].agentMode != mode else {
      return true
    }

    var updatedConversations = aiConversations
    updatedConversations[index].agentMode = mode
    updatedConversations[index].updatedAt = max(
      Date(),
      updatedConversations[index].createdAt
    )
    aiConversations = updatedConversations
    store.save()
    return true
  }
}
