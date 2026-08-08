import Foundation

extension WorkbenchStore {
  public func setAIActionResult(_ result: AIPublishingActionResult?) {
    aiWorkspaceStore.aiActionResult = result
  }

  public func setAIActionMessage(_ message: String?) {
    aiWorkspaceStore.aiActionMessage = message
  }

  func setAITokenAvailability(_ availability: KeychainTokenAvailability) {
    aiWorkspaceStore.aiTokenAvailability = availability
  }

  func setAIChatDraftID(_ draftID: UUID?) {
    aiWorkspaceStore.aiChatDraftID = draftID
  }

  public func setAIChatContextMode(_ mode: AIPublishingChatContextMode) {
    aiWorkspaceStore.aiChatContextMode = mode
    aiStore.cacheCurrentAIChatSessionForAIStore()
  }

  func setAIChatModelGradeState(_ grade: AIChatModelGrade) {
    aiWorkspaceStore.aiChatModelGrade = grade
  }

  func setAIChatSelectedModelState(_ model: String) {
    aiWorkspaceStore.aiChatSelectedModel = model
  }

  public func setAIChatMessage(_ message: String?) {
    aiWorkspaceStore.aiChatMessage = message
  }

  func setAIChatMessages(_ messages: [AIPublishingChatMessage]) {
    aiWorkspaceStore.aiChatMessages = messages
  }

  func setAIChatRunning(_ isRunning: Bool) {
    aiWorkspaceStore.isAIChatRunning = isRunning
  }

  func setAIImageTextSuggestionDraftID(_ draftID: UUID?) {
    aiWorkspaceStore.aiImageTextSuggestionDraftID = draftID
  }

  func setAIImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    aiWorkspaceStore.aiImageTextSuggestions = suggestions
  }

  func setAIImageTextRunning(_ isRunning: Bool) {
    aiWorkspaceStore.isAIImageTextRunning = isRunning
  }

  func setAIPublishingAssistantPresented(_ isPresented: Bool) {
    guard aiWorkspaceStore.isAIPublishingAssistantPresented != isPresented else { return }
    aiWorkspaceStore.isAIPublishingAssistantPresented = isPresented
  }
}
