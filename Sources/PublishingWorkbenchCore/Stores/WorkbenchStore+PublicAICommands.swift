import Foundation
import PublishingAICore
import PublishingDomainContracts

extension WorkbenchStore {
  public func prepareAIChat(for draft: ArticleDraft) {
    aiStore.prepareAIChat(for: draft)
  }

  public func refreshAIKeyAvailability() {
    aiStore.refreshAIKeyAvailability()
  }

  public func setAICredentialStorageMode(_ mode: AICredentialStorageMode) {
    aiStore.setAICredentialStorageMode(mode)
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

  public func seoReport(for draft: ArticleDraft) -> SEOAuditReport {
    aiStore.seoReport(for: draft)
  }

  public func seoInspectorPresentation(
    for draft: ArticleDraft
  ) async throws -> WorkbenchSEOInspectorPresentation {
    try await aiStore.seoInspectorPresentation(for: draft)
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

  @discardableResult
  public func selectAIChatConversation(_ conversationID: UUID) -> Bool {
    aiStore.selectAIChatConversation(conversationID)
  }

  @discardableResult
  public func renameAIChatConversation(
    _ conversationID: UUID,
    title: String?
  ) -> Bool {
    aiStore.renameAIChatConversation(conversationID, title: title)
  }

  @discardableResult
  public func archiveAIChatConversation(_ conversationID: UUID) -> Bool {
    aiStore.archiveAIChatConversation(conversationID)
  }

  @discardableResult
  public func restoreAIChatConversation(_ conversationID: UUID) -> Bool {
    aiStore.restoreAIChatConversation(conversationID)
  }

  @discardableResult
  public func deleteAIChatConversation(_ conversationID: UUID) -> Bool {
    aiStore.deleteAIChatConversation(conversationID)
  }

  @discardableResult
  public func saveAIChatCustomPrompt(title: String, prompt: String) -> AIPublishingCustomPrompt? {
    aiStore.saveAIChatCustomPrompt(title: title, prompt: prompt)
  }

  public func deleteAIChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    aiStore.deleteAIChatCustomPrompt(promptID)
  }

  @discardableResult
  public func startNewAIChatConversation(
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    aiStore.startNewAIChatConversation(draft: draft)
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    /// Seeds a runtime-only conversation for deterministic screenshot fixtures.
    public func seedTransientAIChatPreview(_ messages: [AIPublishingChatMessage]) {
      setAIChatMessages(messages)
      aiStore.cacheCurrentAIChatSessionForAIStore()
    }
  #endif

  @discardableResult
  public func branchAIChatConversation(
    after messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    aiStore.branchAIChatConversation(after: messageID, draft: draft)
  }

  @discardableResult
  public func retryLastFailedAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    draft: ArticleDraft? = nil,
    ownerToken: UUID? = nil,
    expectedContextMode: AIPublishingChatContextMode? = nil
  ) async -> AIPublishingChatMessage? {
    await aiStore.retryLastFailedAIChatReply(
      confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
      draft: draft,
      ownerToken: ownerToken,
      expectedContextMode: expectedContextMode
    )
  }

  @discardableResult
  public func sendAIChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    ownerToken: UUID? = nil,
    expectedContextMode: AIPublishingChatContextMode? = nil,
    expectedDraftConversation: AIChatDraftConversationExpectation? = nil
  ) async -> AIPublishingChatMessage? {
    await aiStore.sendAIChatMessage(
      text,
      draft: draft,
      imageAttachments: imageAttachments,
      contextReferences: contextReferences,
      ownerToken: ownerToken,
      expectedContextMode: expectedContextMode,
      expectedDraftConversation: expectedDraftConversation
    )
  }

  public func consumePendingAIQuickPrompt() -> AIPublishingQuickPrompt? {
    aiStore.consumePendingAIQuickPrompt()
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

  @discardableResult
  public func applyAIMetadataSuggestion(
    field: AIPublishingMetadataField,
    value: String,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    aiStore.applyAIMetadataSuggestion(field: field, value: value, draft: draft)
  }

  public func aiMetadataSuggestion(for draftID: UUID)
    -> AIPublishingMetadataSuggestion?
  {
    aiStore.aiMetadataSuggestion(for: draftID)
  }

  public func makeAttachment(
    from url: URL,
    draft: ArticleDraft,
    fileStore: ManagedAttachmentFileStore? = nil
  ) async throws -> DraftAttachment {
    try await imageStore.makeAttachment(
      from: url,
      draft: draft,
      fileStore: fileStore ?? managedAttachmentFileStore
    )
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
  public func performAIAction(
    _ convergence: AIPublishingActionConvergence,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await aiStore.performAIAction(convergence, draft: draft, selectedText: selectedText)
  }

  @discardableResult
  public func sendMaintenanceActionToAI(_ item: MaintenanceActionItem) async
    -> AIPublishingChatMessage?
  {
    await aiStore.sendMaintenanceActionToAI(item)
  }

  @discardableResult
  public func sendReleaseRecoveryPackageToAI(for entry: ReleaseLedgerEntry) async
    -> AIPublishingChatMessage?
  {
    await aiStore.sendReleaseRecoveryPackageToAI(for: entry)
  }
}
