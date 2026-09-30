import Foundation

extension WorkbenchAIStore {
  @discardableResult
  public func openAIChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil,
    ownerWindowID: UUID? = nil
  ) -> Bool {
    let preservesGeneralContext = quickPrompt == nil && aiChatContextMode == .general
    if let draftID {
      guard store.focusDraft(draftID, section: .writing) else {
        return false
      }
    } else if store.selectedDraftID == nil {
      _ = store.ensureEditableDraftSelected()
    }

    store.selectSection(.writing)

    guard let draft = store.selectedDraft else {
      isAIPublishingAssistantPresented = false
      store.setInspectorPresented(false)
      return false
    }

    prepareAIChat(for: draft)
    if let quickPrompt {
      // Article templates explicitly request article context, including when
      // prepareAIChat preserves the same draft's previous general mode.
      if aiChatContextMode != .site {
        aiChatContextMode = .site
        cacheCurrentAIChatSessionForAIStore()
      }
      pendingAIQuickPromptRequest = AIPublishingQuickPromptRequest(
        prompt: quickPrompt,
        ownerWindowID: ownerWindowID,
        draftID: draft.id,
        conversationID: activeAIChatConversationID(for: draft.id)
      )
    } else if preservesGeneralContext, aiChatContextMode != .general {
      aiChatContextMode = .general
      cacheCurrentAIChatSessionForAIStore()
    }

    // Prepare the route before asking SwiftUI to present the Inspector. This
    // avoids briefly mounting the article Inspector and replacing it with the
    // AI Inspector in the same presentation transaction.
    isAIPublishingAssistantPresented = true
    store.setInspectorPresented(true)
    return true
  }

  /// Compatibility for standalone callers. Window-owned requests always need
  /// the explicit surface identity and cannot be consumed through this entry.
  public func consumePendingAIQuickPrompt() -> AIPublishingQuickPrompt? {
    guard pendingAIQuickPromptRequest?.ownerWindowID == nil else { return nil }
    return consumePendingAIQuickPrompt(
      ownerWindowID: nil,
      draftID: aiChatDraftID,
      conversationID: aiChatDraftID.flatMap { activeAIChatConversationID(for: $0) }
    )
  }

  public func consumePendingAIQuickPrompt(
    ownerWindowID: UUID?,
    draftID: UUID?,
    conversationID: UUID?
  ) -> AIPublishingQuickPrompt? {
    guard aiChatContextMode == .site,
      let request = pendingAIQuickPromptRequest,
      store.draft(for: request.draftID) != nil,
      activeAIChatConversationID(for: request.draftID) == request.conversationID,
      request.matches(
        ownerWindowID: ownerWindowID,
        draftID: draftID,
        conversationID: conversationID
      )
    else { return nil }
    pendingAIQuickPromptRequest = nil
    return request.prompt
  }
}
