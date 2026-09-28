import PublishingWorkbenchCore

extension AIChatContextInspectorView {
  var availableChatContextReferences: [AIContextReference] {
    guard let windowID = workspaceWindowSession?.windowID else { return [] }
    if ai.chatContextMode == .general {
      return ai.availableGeneralChatContextReferences(
        windowID: windowID
      )
    }
    guard let draft = inspectorDraft else { return [] }
    return ai.availableChatContextReferences(
      for: draft,
      windowID: windowID
    )
  }
}
