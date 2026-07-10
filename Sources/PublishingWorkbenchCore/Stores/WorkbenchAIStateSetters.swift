import Foundation

extension WorkbenchStore {
  public func setSEOSocialPreviewMessage(_ message: String?) {
    aiWorkspaceStore.seoSocialPreviewMessage = message
  }

  public func setAIActionResult(_ result: AIPublishingActionResult?) {
    aiWorkspaceStore.aiActionResult = result
  }

  public func setAIActionMessage(_ message: String?) {
    aiWorkspaceStore.aiActionMessage = message
  }

  func setAITokenAvailability(_ availability: KeychainTokenAvailability) {
    aiWorkspaceStore.aiTokenAvailability = availability
  }

  func setAIActionRunning(_ isRunning: Bool) {
    aiWorkspaceStore.isAIActionRunning = isRunning
  }

  func setAIMetadataApplicationRecords(_ records: [AIPublishingMetadataApplicationRecord]) {
    aiWorkspaceStore.aiMetadataApplicationRecords = records
  }

  func setAIMetadataSuggestionDraftID(_ draftID: UUID?) {
    aiWorkspaceStore.aiMetadataSuggestionDraftID = draftID
  }

  func setAIMetadataSuggestion(_ suggestion: AIPublishingMetadataSuggestion?) {
    aiWorkspaceStore.aiMetadataSuggestion = suggestion
  }

  func setAIMetadataSuggestionRunning(_ isRunning: Bool) {
    aiWorkspaceStore.isAIMetadataSuggestionRunning = isRunning
  }

  func setAIChatDraftID(_ draftID: UUID?) {
    aiWorkspaceStore.aiChatDraftID = draftID
  }

  func setAIChatConversationTitleState(_ title: String?) {
    aiWorkspaceStore.aiChatConversationTitle = title
  }

  public func setAIChatContextMode(_ mode: AIPublishingChatContextMode) {
    aiWorkspaceStore.aiChatContextMode = mode
  }

  func setAIChatModelGradeState(_ grade: AIChatModelGrade) {
    aiWorkspaceStore.aiChatModelGrade = grade
  }

  func setAIChatSelectedModelState(_ model: String) {
    aiWorkspaceStore.aiChatSelectedModel = model
  }

  func setAIChatFocusedParagraphIDState(_ paragraphID: String?) {
    aiWorkspaceStore.aiChatFocusedParagraphID = paragraphID
  }

  func setPendingAIQuickPrompt(_ prompt: AIPublishingQuickPrompt?) {
    aiWorkspaceStore.pendingAIQuickPrompt = prompt
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

  func setAIChatCustomPrompts(_ prompts: [AIPublishingCustomPrompt]) {
    aiWorkspaceStore.aiChatCustomPrompts = prompts
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

  func setSEOSocialPreviewSnapshots(_ snapshots: [UUID: SEOSocialPreviewSnapshot]) {
    aiWorkspaceStore.seoSocialPreviewSnapshots = snapshots
  }

  func setSEOSocialPreviewSnapshot(_ snapshot: SEOSocialPreviewSnapshot?) {
    aiWorkspaceStore.seoSocialPreviewSnapshot = snapshot
  }

  func setAIPublishingAssistantPresented(_ isPresented: Bool) {
    aiWorkspaceStore.isAIPublishingAssistantPresented = isPresented
  }
}
