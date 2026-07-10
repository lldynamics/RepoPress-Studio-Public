import Foundation

@MainActor
public final class WorkbenchAIFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var tokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var isActionRunning: Bool {
    store.isAIActionRunning
  }

  public var actionMessage: String? {
    store.aiActionMessage
  }

  public var actionResult: AIPublishingActionResult? {
    store.aiActionResult
  }

  public var metadataSuggestion: AIPublishingMetadataSuggestion? {
    store.aiMetadataSuggestion
  }

  public var chatDraftID: UUID? {
    store.aiChatDraftID
  }

  public var chatConversationTitle: String? {
    store.aiChatConversationTitle
  }

  public var chatMessages: [AIPublishingChatMessage] {
    store.aiChatMessages
  }

  public var chatContextMode: AIPublishingChatContextMode {
    store.aiChatContextMode
  }

  public var chatModelGrade: AIChatModelGrade {
    store.aiChatModelGrade
  }

  public var chatSelectedModel: String {
    store.aiChatSelectedModel
  }

  public var chatFocusedParagraphID: String? {
    store.aiChatFocusedParagraphID
  }

  public var chatCustomPrompts: [AIPublishingCustomPrompt] {
    store.aiChatCustomPrompts
  }

  public var pendingQuickPrompt: AIPublishingQuickPrompt? {
    store.pendingAIQuickPrompt
  }

  public var selectedChatDraft: ArticleDraft? {
    store.selectedDraft
  }

  public var chatVisibleDrafts: [ArticleDraft] {
    store.visibleDrafts
  }

  public var chatMessage: String? {
    store.aiChatMessage
  }

  public var isChatRunning: Bool {
    store.isAIChatRunning
  }

  public var isImageTextRunning: Bool {
    store.isAIImageTextRunning
  }

  public var archivedConversations: [AIPublishingChatArchivedConversation] {
    store.aiArchivedConversations
  }

  public func refreshKeyAvailability() {
    store.aiRefreshKeyAvailability()
  }

  public func saveAPIKey(_ token: String) {
    store.aiSaveAPIKey(token)
  }

  public func deleteAPIKey() {
    store.aiDeleteAPIKey()
  }

  public func testConnection() async -> AIConnectionTestReport? {
    await store.aiTestConnection()
  }

  @discardableResult
  public func openChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    store.aiOpenChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  public func prepareChat(for draft: ArticleDraft) {
    store.aiPrepareChat(for: draft)
  }

  public func clearChat() {
    store.aiClearChat()
  }

  public func setChatModelGrade(_ grade: AIChatModelGrade) {
    store.aiSetChatModelGrade(grade)
  }

  public func setChatCustomModel(_ model: String) {
    store.aiSetChatCustomModel(model)
  }

  public func resetChatModelToProfileDefault() {
    store.aiResetChatModelToProfileDefault()
  }

  public func setChatConversationTitle(_ title: String?, draft: ArticleDraft? = nil) {
    store.aiSetChatConversationTitle(title, draft: draft)
  }

  public func setChatFocusedParagraph(_ paragraphID: String?, draft: ArticleDraft? = nil) {
    store.aiSetChatFocusedParagraph(paragraphID, draft: draft)
  }

  public func updateChatDraft(_ draft: ArticleDraft) {
    store.updateDraft(draft)
  }

  public func selectChatDraft(_ id: UUID?) {
    store.selectDraft(id)
  }

  public func saveChatDraftChanges() {
    store.save()
  }

  public func chatProfile(for draft: ArticleDraft) -> SiteProfile {
    store.profile(for: draft)
  }

  public func activeChatEditorSelectionRange(for draft: ArticleDraft) -> NSRange? {
    store.activeEditorSelectionRange(for: draft)
  }

  public func chatPublishingPackage(for draft: ArticleDraft) -> PublishPackage {
    store.publishingPackage(for: draft)
  }

  public func chatPreflightIssues(for draft: ArticleDraft) -> [PreflightIssue] {
    store.preflightIssues(for: draft)
  }

  public func chatImageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    store.imageWorkbenchReport(for: draft)
  }

  public func refreshChatImageWorkbenchReport() {
    store.refreshImageWorkbenchReport()
  }

  public func relatedChatArticleSuggestions(
    for draft: ArticleDraft,
    limit: Int = 5
  ) -> [SiteRelationSuggestion] {
    store.relatedArticleSuggestions(for: draft, limit: limit)
  }

  public func setActionResult(_ result: AIPublishingActionResult?) {
    store.setAIActionResult(result)
  }

  public func setActionMessage(_ message: String?) {
    store.setAIActionMessage(message)
  }

  public func setChatContextMode(_ mode: AIPublishingChatContextMode) {
    store.setAIChatContextMode(mode)
  }

  public func setChatMessage(_ message: String?) {
    store.setAIChatMessage(message)
  }

  @discardableResult
  public func saveChatCustomPrompt(title: String, prompt: String) -> AIPublishingCustomPrompt? {
    store.aiSaveChatCustomPrompt(title: title, prompt: prompt)
  }

  public func deleteChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    store.aiDeleteChatCustomPrompt(promptID)
  }

  public func startNewChatConversation(draft: ArticleDraft? = nil) {
    store.aiStartNewChatConversation(draft: draft)
  }

  public func restoreArchivedChatConversation(_ conversationID: AIPublishingChatArchivedConversation.ID, draft: ArticleDraft? = nil) {
    store.aiRestoreArchivedChatConversation(conversationID, draft: draft)
  }

  public func deleteArchivedChatConversation(_ conversationID: AIPublishingChatArchivedConversation.ID, draft: ArticleDraft? = nil) {
    store.aiDeleteArchivedChatConversation(conversationID, draft: draft)
  }

  public func deleteChatMessage(_ messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    store.aiDeleteChatMessage(messageID, draft: draft)
  }

  public func branchChatConversation(after messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    store.aiBranchChatConversation(after: messageID, draft: draft)
  }

  public func cancelChatReply() {
    store.aiCancelChatReply()
  }

  @discardableResult
  public func regenerateLastChatReply(draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await store.aiRegenerateLastChatReply(draft: draft)
  }

  @discardableResult
  public func regenerateChatReply(messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await store.aiRegenerateChatReply(messageID: messageID, draft: draft)
  }

  @discardableResult
  public func sendChatMessage(_ text: String, draft: ArticleDraft? = nil, imageAttachments: [AIChatImageAttachment] = []) async -> AIPublishingChatMessage? {
    await store.aiSendChatMessage(text, draft: draft, imageAttachments: imageAttachments)
  }

  public func consumePendingQuickPrompt() -> AIPublishingQuickPrompt? {
    store.aiConsumePendingQuickPrompt()
  }

  public func focusedChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    store.aiFocusedChatParagraph(for: draft)
  }

  @discardableResult
  public func performAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await store.aiPerformAction(kind, draft: draft, selectedText: selectedText)
  }

  @discardableResult
  public func generateImageTextSuggestions(draft: ArticleDraft) async -> [AIPublishingImageTextSuggestion] {
    await store.aiGenerateImageTextSuggestions(draft: draft)
  }

  public func chatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) -> [AIChatImageAttachment] {
    store.aiChatImageAttachments(for: draft, attachmentIDs: attachmentIDs)
  }

  public func makeImageAttachment(from url: URL, draft: ArticleDraft) -> DraftAttachment {
    store.makeAIChatImageAttachment(from: url, draft: draft)
  }
}
