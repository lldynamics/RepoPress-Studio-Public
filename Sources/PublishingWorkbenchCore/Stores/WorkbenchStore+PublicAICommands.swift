import Foundation

extension WorkbenchStore {
  public func prepareAIChat(for draft: ArticleDraft) {
    aiStore.prepareAIChat(for: draft)
  }

  public func refreshAIKeyAvailability() {
    aiStore.refreshAIKeyAvailability()
  }

  public func prepareSEOSocialPreview(for draft: ArticleDraft) {
    aiStore.prepareSEOSocialPreview(for: draft)
  }

  public func refreshSEOSocialPreview(
    for draft: ArticleDraft,
    message: String? = "SEO / 社交预览已刷新。"
  ) {
    aiStore.refreshSEOSocialPreview(for: draft, message: message)
  }

  public func isSEOSocialPreviewStale(for draft: ArticleDraft) -> Bool {
    aiStore.isSEOSocialPreviewStale(for: draft)
  }

  public func seoSocialPreviewSnapshot(for draft: ArticleDraft) -> SEOSocialPreviewSnapshot? {
    aiStore.seoSocialPreviewSnapshot(for: draft)
  }

  public func seoSocialPreviewCachePresentation(for draft: ArticleDraft) -> SEOSocialPreviewCachePresentation {
    aiStore.seoSocialPreviewCachePresentation(for: draft)
  }

  public func seoReport(for draft: ArticleDraft) -> SEOAuditReport {
    aiStore.seoReport(for: draft)
  }

  @discardableResult
  public func saveAIAPIKey(_ token: String) -> Bool {
    aiStore.saveAIAPIKey(token)
  }

  public func deleteAIAPIKey() {
    aiStore.deleteAIAPIKey()
  }

  public func testAIConnection() async -> AIConnectionTestReport? {
    await aiStore.testAIConnection()
  }

  public func clearAIChat() {
    aiStore.clearAIChat()
  }

  public func setAIChatModelGrade(_ grade: AIChatModelGrade) {
    aiStore.setAIChatModelGrade(grade)
  }

  public func setAIChatReasoningLevel(_ level: AIChatReasoningLevel) {
    aiStore.setAIChatReasoningLevel(level)
  }

  public func setAIChatKnowledgePolicy(_ policy: KnowledgeRetrievalPolicy) {
    aiStore.setAIChatKnowledgePolicy(policy)
  }

  public func setAIChatCustomModel(_ model: String) {
    aiStore.setAIChatCustomModel(model)
  }

  public func resetAIChatModelToProfileDefault() {
    aiStore.resetAIChatModelToProfileDefault()
  }

  public func setAIChatConversationTitle(_ title: String?, draft: ArticleDraft? = nil) {
    aiStore.setAIChatConversationTitle(title, draft: draft)
  }

  public func setAIChatFocusedParagraph(_ paragraphID: String?, draft: ArticleDraft? = nil) {
    aiStore.setAIChatFocusedParagraph(paragraphID, draft: draft)
  }

  @discardableResult
  public func saveAIChatCustomPrompt(title: String, prompt: String) -> AIPublishingCustomPrompt? {
    aiStore.saveAIChatCustomPrompt(title: title, prompt: prompt)
  }

  public func deleteAIChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    aiStore.deleteAIChatCustomPrompt(promptID)
  }

  public func startNewAIChatConversation(draft: ArticleDraft? = nil) {
    aiStore.startNewAIChatConversation(draft: draft)
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
  /// Seeds a runtime-only conversation for deterministic screenshot fixtures.
  public func seedTransientAIChatPreview(_ messages: [AIPublishingChatMessage]) {
    setAIChatMessages(messages)
    aiStore.cacheCurrentAIChatSessionForAIStore()
  }
  #endif

  public func deleteAIChatMessage(_ messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    aiStore.deleteAIChatMessage(messageID, draft: draft)
  }

  public func branchAIChatConversation(after messageID: AIPublishingChatMessage.ID, draft: ArticleDraft? = nil) {
    aiStore.branchAIChatConversation(after: messageID, draft: draft)
  }

  public func cancelAIChatReply() {
    aiStore.cancelAIChatReply()
  }

  @discardableResult
  public func retryLastFailedAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    await aiStore.retryLastFailedAIChatReply(
      confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
      draft: draft
    )
  }

  @discardableResult
  public func regenerateLastAIChatReply(draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await aiStore.regenerateLastAIChatReply(draft: draft)
  }

  @discardableResult
  public func regenerateAIChatReply(
    messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    await aiStore.regenerateAIChatReply(messageID: messageID, draft: draft)
  }

  @discardableResult
  public func sendAIChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = []
  ) async -> AIPublishingChatMessage? {
    await aiStore.sendAIChatMessage(text, draft: draft, imageAttachments: imageAttachments)
  }

  public func consumePendingAIQuickPrompt() -> AIPublishingQuickPrompt? {
    aiStore.consumePendingAIQuickPrompt()
  }

  public func showAIPublishingAssistant(for draftID: UUID? = nil) {
    aiStore.showAIPublishingAssistant(for: draftID)
  }

  public func hideAIPublishingAssistant() {
    aiStore.hideAIPublishingAssistant()
  }

  public func openAIChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    aiStore.openAIChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  public func focusedAIChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    aiStore.focusedAIChatParagraph(for: draft)
  }

  @discardableResult
  public func applyAIMetadataSuggestion(
    field: AIPublishingMetadataField,
    value: String,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    aiStore.applyAIMetadataSuggestion(field: field, value: value, draft: draft)
  }

  @discardableResult
  public func applyAIMetadataSuggestion(
    _ suggestion: AIPublishingMetadataSuggestion,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    aiStore.applyAIMetadataSuggestion(suggestion, draft: draft)
  }

  public func recentAIMetadataApplicationRecords(
    for draft: ArticleDraft,
    limit: Int = 10
  ) -> [AIPublishingMetadataApplicationRecord] {
    aiStore.recentAIMetadataApplicationRecords(for: draft, limit: limit)
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecord(
    _ record: AIPublishingMetadataApplicationRecord
  ) -> ArticleDraft? {
    aiStore.rollbackAIMetadataApplicationRecord(record)
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecords(
    _ records: [AIPublishingMetadataApplicationRecord]
  ) -> AIPublishingMetadataApplicationBatchRollbackResult {
    aiStore.rollbackAIMetadataApplicationRecords(records)
  }

  public func clearAIMetadataApplicationRecords(for draft: ArticleDraft) {
    aiStore.clearAIMetadataApplicationRecords(for: draft)
  }

  public func aiChatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> [AIChatImageAttachment] {
    await aiStore.aiChatImageAttachments(for: draft, attachmentIDs: attachmentIDs)
  }

  public func makeAttachment(from url: URL, draft: ArticleDraft) -> DraftAttachment {
    imageStore.makeAttachment(from: url, draft: draft)
  }

  public func prepareAIImageTextSuggestions(for draft: ArticleDraft) {
    aiStore.prepareAIImageTextSuggestions(for: draft)
  }

  @discardableResult
  public func generateAIImageTextSuggestions(draft: ArticleDraft) async -> [AIPublishingImageTextSuggestion] {
    await aiStore.generateAIImageTextSuggestions(draft: draft)
  }

  public func applyAIImageTextSuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    aiStore.applyAIImageTextSuggestion(suggestion)
  }

  public func applyAIImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    aiStore.applyAIImageTextSuggestions(suggestions)
  }

  public func clearAIImageTextSuggestions() {
    aiStore.clearAIImageTextSuggestions()
  }

  public func seoSitemapPreview(for draft: ArticleDraft) -> SEOSitemapPreview {
    aiStore.seoSitemapPreview(for: draft)
  }

  public func seoSocialPublishPackageMarkdown(for draft: ArticleDraft) async -> String? {
    await refreshSiteMaintenanceSnapshot()
    return aiStore.seoSocialPublishPackageMarkdown(for: draft)
  }

  @discardableResult
  public func performAIAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await aiStore.performAIAction(kind, draft: draft, selectedText: selectedText)
  }

  @discardableResult
  public func generateAIMetadataSuggestions(
    draft: ArticleDraft
  ) async -> AIPublishingMetadataSuggestion? {
    await aiStore.generateAIMetadataSuggestions(draft: draft)
  }

  @discardableResult
  public func sendMaintenanceActionToAI(_ item: MaintenanceActionItem) async -> AIPublishingChatMessage? {
    await aiStore.sendMaintenanceActionToAI(item)
  }

  @discardableResult
  public func sendReleaseRecoveryPackageToAI(for entry: ReleaseLedgerEntry) async -> AIPublishingChatMessage? {
    await aiStore.sendReleaseRecoveryPackageToAI(for: entry)
  }

  @discardableResult
  public func sendSEOSocialPreviewToAI(for draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    await aiStore.sendSEOSocialPreviewToAI(for: draft)
  }
}
