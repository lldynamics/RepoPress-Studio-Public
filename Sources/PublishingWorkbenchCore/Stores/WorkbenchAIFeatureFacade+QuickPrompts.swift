import Foundation

extension WorkbenchAIFeatureFacade {
  public var pendingQuickPrompt: AIPublishingQuickPrompt? {
    store.pendingAIQuickPrompt
  }

  public var pendingQuickPromptRequest: AIPublishingQuickPromptRequest? {
    store.pendingAIQuickPromptRequest
  }

  @discardableResult
  public func openChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil,
    ownerWindowID: UUID? = nil
  ) -> Bool {
    store.openAIChatWorkspace(
      for: draftID, quickPrompt: quickPrompt, ownerWindowID: ownerWindowID
    )
  }

  public func consumePendingQuickPrompt() -> AIPublishingQuickPrompt? {
    store.consumePendingAIQuickPrompt()
  }

  public func consumePendingQuickPrompt(
    ownerWindowID: UUID?,
    draftID: UUID?,
    conversationID: UUID?
  ) -> AIPublishingQuickPrompt? {
    store.consumePendingAIQuickPrompt(
      ownerWindowID: ownerWindowID,
      draftID: draftID,
      conversationID: conversationID
    )
  }
}
