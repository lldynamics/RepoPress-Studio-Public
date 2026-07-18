import Foundation

extension WorkbenchStore {
  func aiRefreshKeyAvailability() {
    aiStore.refreshAIKeyAvailability()
  }

  @discardableResult
  func aiSaveAPIKey(_ token: String) -> Bool {
    aiStore.saveAIAPIKey(token)
  }

  func aiDeleteAPIKey() {
    aiStore.deleteAIAPIKey()
  }

  func aiTestConnection() async -> AIConnectionTestReport? {
    await aiStore.testAIConnection()
  }

  @discardableResult
  func aiOpenChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    aiStore.openAIChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  func aiPrepareChat(for draft: ArticleDraft) {
    aiStore.prepareAIChat(for: draft)
  }

  func aiClearChat() {
    aiStore.clearAIChat()
  }

  func aiSetChatModelGrade(_ grade: AIChatModelGrade) {
    aiStore.setAIChatModelGrade(grade)
  }

  func aiSetChatReasoningLevel(_ level: AIChatReasoningLevel) {
    aiStore.setAIChatReasoningLevel(level)
  }

  func aiSetChatCustomModel(_ model: String) {
    aiStore.setAIChatCustomModel(model)
  }

  func aiResetChatModelToProfileDefault() {
    aiStore.resetAIChatModelToProfileDefault()
  }

  func aiSetChatConversationTitle(_ title: String?, draft: ArticleDraft? = nil) {
    aiStore.setAIChatConversationTitle(title, draft: draft)
  }

  func aiSetChatFocusedParagraph(_ paragraphID: String?, draft: ArticleDraft? = nil) {
    aiStore.setAIChatFocusedParagraph(paragraphID, draft: draft)
  }

  @discardableResult
  func aiSaveChatCustomPrompt(title: String, prompt: String) -> AIPublishingCustomPrompt? {
    aiStore.saveAIChatCustomPrompt(title: title, prompt: prompt)
  }

  func aiDeleteChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    aiStore.deleteAIChatCustomPrompt(promptID)
  }

  func aiStartNewChatConversation(draft: ArticleDraft? = nil) {
    aiStore.startNewAIChatConversation(draft: draft)
  }

  func aiDeleteChatMessage(_ messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    aiStore.deleteAIChatMessage(messageID, draft: draft)
  }

  func aiBranchChatConversation(after messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    aiStore.branchAIChatConversation(after: messageID, draft: draft)
  }

  func aiCancelChatReply() {
    aiStore.cancelAIChatReply()
  }

  @discardableResult
  func aiRegenerateLastChatReply(draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await aiStore.regenerateLastAIChatReply(draft: draft)
  }

  @discardableResult
  func aiRegenerateChatReply(messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await aiStore.regenerateAIChatReply(messageID: messageID, draft: draft)
  }

  @discardableResult
  func aiSendChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = []
  ) async -> AIPublishingChatMessage? {
    await aiStore.sendAIChatMessage(text, draft: draft, imageAttachments: imageAttachments)
  }

  func aiConsumePendingQuickPrompt() -> AIPublishingQuickPrompt? {
    aiStore.consumePendingAIQuickPrompt()
  }

  func aiFocusedChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    aiStore.focusedAIChatParagraph(for: draft)
  }

  @discardableResult
  func aiPerformAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await aiStore.performAIAction(kind, draft: draft, selectedText: selectedText)
  }

  @discardableResult
  func aiGenerateImageTextSuggestions(draft: ArticleDraft) async -> [AIPublishingImageTextSuggestion] {
    await aiStore.generateAIImageTextSuggestions(draft: draft)
  }

  func aiPrepareImageTextSuggestions(for draft: ArticleDraft) {
    aiStore.prepareAIImageTextSuggestions(for: draft)
  }

  func aiApplyImageTextSuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    aiStore.applyAIImageTextSuggestion(suggestion)
  }

  func aiApplyImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    aiStore.applyAIImageTextSuggestions(suggestions)
  }

  func aiClearImageTextSuggestions() {
    aiStore.clearAIImageTextSuggestions()
  }

  func makeAIChatImageAttachment(from url: URL, draft: ArticleDraft) -> DraftAttachment {
    imageStore.makeAttachment(from: url, draft: draft)
  }
}
