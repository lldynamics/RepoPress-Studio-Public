import Combine
import Foundation

@MainActor
public final class WorkbenchAIFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    store.publishingStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.aiWorkspaceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.aiStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.imageStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.siteMaintenanceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  public var tokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var credentialStorageMode: AICredentialStorageMode {
    store.aiStore.aiCredentialStorageMode
  }

  public func keyAvailability(
    forConnectionProfileID connectionProfileID: UUID
  ) -> KeychainTokenAvailability {
    store.aiStore.aiKeyAvailability(
      forConnectionProfileID: connectionProfileID
    )
  }

  public var canUseProtectedWorkbench: Bool {
    store.canUseProtectedWorkbench
  }

  public var isQuickHideActive: Bool {
    store.isQuickHideActive
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

  public var dataSharingConsent: AIDataSharingConsentPresentation {
    store.aiStore.aiDataSharingConsentPresentation
  }

  public func dataSharingConsent(
    for config: AIProviderConfig
  ) -> AIDataSharingConsentPresentation {
    store.aiStore.aiDataSharingConsentPresentation(for: config)
  }

  public var isRemoteAIEnabled: Bool {
    store.aiStore.isRemoteAIEnabled
  }

  public var metadataSuggestion: AIPublishingMetadataSuggestion? {
    store.aiMetadataSuggestion
  }

  public var chatDraftID: UUID? {
    store.aiChatDraftID
  }

  public var chatConversationTitle: String? {
    if store.aiChatContextMode == .general {
      return store.aiStore.activeGeneralAIChatConversation?.title
    }
    return store.aiChatConversationTitle
  }

  public var chatMessages: [AIPublishingChatMessage] {
    if store.aiChatContextMode == .general {
      return store.aiStore.activeGeneralAIChatConversation?.messages ?? []
    }
    return store.aiChatMessages
  }

  public var chatContextMode: AIPublishingChatContextMode {
    store.aiChatContextMode
  }

  public var chatKnowledgePolicy: KnowledgeRetrievalPolicy {
    store.aiChatKnowledgePolicy
  }

  public var generalChatKnowledgePolicy: KnowledgeRetrievalPolicy {
    store.aiStore.activeGeneralAIChatKnowledgePolicy
  }

  public var chatModelGrade: AIChatModelGrade {
    store.aiChatModelGrade
  }

  public var chatReasoningLevel: AIChatReasoningLevel {
    store.aiChatReasoningLevel
  }

  public var generalChatReasoningLevel: AIChatReasoningLevel {
    store.aiStore.activeGeneralAIChatReasoningLevel
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

  public var activeChatConversationID: UUID? {
    guard let draftID = store.aiChatDraftID else { return nil }
    return store.aiStore.activeAIChatConversationID(for: draftID)
  }

  public var activeChatConversation: AIConversation? {
    store.aiStore.activeAIChatConversation()
  }

  public var generalChatConversations: [AIConversation] {
    store.aiStore.generalAIChatConversations(includingArchived: false)
  }

  public var generalChatConversationsIncludingArchived: [AIConversation] {
    store.aiStore.generalAIChatConversations(includingArchived: true)
  }

  public var activeGeneralChatConversationID: UUID? {
    store.aiStore.activeGeneralAIChatConversationID
  }

  public var activeGeneralChatConversation: AIConversation? {
    store.aiStore.activeGeneralAIChatConversation
  }

  public func generalChatConversation(
    withID conversationID: UUID,
    includingArchived: Bool = true
  ) -> AIConversation? {
    store.aiStore.generalAIChatConversation(
      withID: conversationID,
      includingArchived: includingArchived
    )
  }

  public var activeGeneralChatConnectionProfile: AIConnectionProfile {
    store.aiStore.activeGeneralAIChatConversation?.connectionProfileID
      .flatMap(store.aiConnectionProfile(for:))
      ?? store.activeAIConnectionProfile
  }

  public var activeGeneralChatConnectionProfileID: UUID? {
    store.aiStore.activeGeneralAIChatConversation?.connectionProfileID
  }

  public var activeGeneralChatProviderConfig: AIProviderConfig? {
    activeGeneralChatConnectionProfileID
      .flatMap(store.aiConnectionProfile(for:))?
      .config
  }

  public var generalChatManualRetryState: AIGeneralChatManualRetryState? {
    store.aiStore.aiGeneralChatManualRetryState
  }

  public func startNewGeneralChatConversation(
    connectionProfileID: UUID? = nil
  ) -> AIConversation? {
    store.aiStore.startNewGeneralAIChatConversation(
      connectionProfileID: connectionProfileID
    )
  }

  @discardableResult
  public func selectGeneralChatConversation(_ conversationID: UUID) -> Bool {
    store.aiStore.selectGeneralAIChatConversation(conversationID)
  }

  @discardableResult
  public func setGeneralChatConnectionProfile(
    _ connectionProfileID: UUID,
    conversationID: UUID? = nil
  ) -> Bool {
    store.aiStore.setGeneralAIChatConnectionProfile(
      connectionProfileID,
      conversationID: conversationID
    )
  }

  @discardableResult
  public func setGeneralChatModelGrade(
    _ modelGrade: AIChatModelGrade,
    conversationID: UUID? = nil
  ) -> Bool {
    store.aiStore.setGeneralAIChatModelGrade(
      modelGrade,
      conversationID: conversationID
    )
  }

  @discardableResult
  public func setGeneralChatKnowledgePolicy(
    _ policy: KnowledgeRetrievalPolicy,
    conversationID: UUID? = nil
  ) -> Bool {
    store.aiStore.setGeneralAIChatKnowledgePolicy(
      policy,
      conversationID: conversationID
    )
  }

  public func availableGeneralChatContextReferences() -> [AIContextReference] {
    store.aiStore.availableGeneralAIChatContextReferences()
  }

  @discardableResult
  public func sendGeneralChatMessage(
    _ text: String,
    conversationID: UUID? = nil,
    connectionProfileID: UUID? = nil,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    await store.aiStore.sendGeneralAIChatMessage(
      text,
      conversationID: conversationID,
      connectionProfileID: connectionProfileID,
      imageAttachments: imageAttachments,
      contextReferences: contextReferences,
      ownerToken: ownerToken
    )
  }

  @discardableResult
  public func retryLastFailedGeneralChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    conversationID: UUID? = nil,
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    await store.aiStore.retryLastFailedGeneralAIChatReply(
      confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
      conversationID: conversationID,
      ownerToken: ownerToken
    )
  }

  public func activeChatConversationID(for draftID: UUID) -> UUID? {
    store.aiStore.activeAIChatConversationID(for: draftID)
  }

  public func chatConversations(
    for draftID: UUID,
    includingArchived: Bool = false
  ) -> [AIConversation] {
    store.aiStore.aiChatConversations(
      for: draftID,
      includingArchived: includingArchived
    )
  }

  public var pendingQuickPrompt: AIPublishingQuickPrompt? {
    store.pendingAIQuickPrompt
  }

  public var isAssistantPresented: Bool {
    store.isAIPublishingAssistantPresented
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

  public var isAutomationRunning: Bool {
    store.aiWorkspaceStore.isAutomationRunning
  }

  public var automationRunRecords: [WorkbenchAutomationRunRecord] {
    store.automationRunRecords
  }

  public var chatManualRetryState: AIChatManualRetryState? {
    store.aiChatManualRetryState
  }

  public var isImageTextRunning: Bool {
    store.isAIImageTextRunning
  }

  public func recordKnowledgeBacklinks(
    _ citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) {
    store.knowledge.recordBacklinks(citations: citations, target: target)
  }

  @discardableResult
  public func openKnowledgeCitation(_ citation: KnowledgeCitation) -> Bool {
    guard store.knowledge.selectCitation(citation) else { return false }
    store.hideAIPublishingAssistant()
    store.selectSection(.library)
    return true
  }

  public func refreshKeyAvailability() {
    store.refreshAIKeyAvailability()
  }

  public func setCredentialStorageMode(_ mode: AICredentialStorageMode) {
    store.setAICredentialStorageMode(mode)
  }

  @discardableResult
  public func saveAPIKey(_ token: String) -> Bool {
    store.saveAIAPIKey(token)
  }

  public func deleteAPIKey() {
    store.deleteAIAPIKey()
  }

  public func testConnection(
    probeCapabilities: Set<AIProviderCapabilityProbeKind> = []
  ) async -> AIConnectionTestReport? {
    await store.testAIConnection(probeCapabilities: probeCapabilities)
  }

  public func grantDataSharingConsent() {
    store.aiStore.grantAIDataSharingConsent()
  }

  public func grantDataSharingConsent(
    for config: AIProviderConfig,
    enablingRemoteAI: Bool
  ) {
    store.aiStore.grantAIDataSharingConsent(
      for: config,
      enablingRemoteAI: enablingRemoteAI
    )
  }

  public func revokeDataSharingConsent() {
    store.aiStore.revokeAIDataSharingConsent()
  }

  public func setRemoteAIEnabled(_ enabled: Bool) {
    store.aiStore.setRemoteAIEnabled(enabled)
  }

  @discardableResult
  public func openChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    store.openAIChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  public func hideAssistant() {
    store.hideAIPublishingAssistant()
  }

  public func closeAssistantPanel() {
    store.hideAIPublishingAssistant()
    store.setInspectorPresented(false)
  }

  public func prepareChat(for draft: ArticleDraft) {
    store.prepareAIChat(for: draft)
  }

  public func setChatModelGrade(_ grade: AIChatModelGrade) {
    store.setAIChatModelGrade(grade)
  }

  public func setChatReasoningLevel(_ level: AIChatReasoningLevel) {
    store.setAIChatReasoningLevel(level)
  }

  @discardableResult
  public func setGeneralChatReasoningLevel(
    _ level: AIChatReasoningLevel,
    conversationID: UUID? = nil
  ) -> Bool {
    store.aiStore.setGeneralAIChatReasoningLevel(
      level,
      conversationID: conversationID
    )
  }

  public func setChatCustomModel(_ model: String) {
    store.setAIChatCustomModel(model)
  }

  public func resetChatModelToProfileDefault() {
    store.resetAIChatModelToProfileDefault()
  }

  public func updateChatDraft(_ draft: ArticleDraft) {
    store.updateDraft(draft)
  }

  public func selectChatDraft(_ id: UUID?) {
    store.selectDraft(id)
    if let draft = store.selectedDraft {
      store.prepareAIChat(for: draft)
    }
  }

  public func saveChatDraftChanges() {
    store.save()
  }

  public func chatProfile(for draft: ArticleDraft) -> SiteProfile {
    store.profile(for: draft)
  }

  public func chatProviderConfig(for draft: ArticleDraft) -> AIProviderConfig {
    store.aiProviderConfig(for: store.profile(for: draft))
  }

  /// The reusable profiles are exposed to the chat shortcut sheet so changing
  /// an endpoint does not require leaving the writing workspace.
  public var chatConnectionProfiles: [AIConnectionProfile] {
    store.aiConnectionProfiles
  }

  public var activeChatConnectionProfile: AIConnectionProfile {
    store.activeAIConnectionProfile
  }

  public func selectChatConnectionProfile(_ connectionID: UUID) {
    store.selectAIConnectionProfile(connectionID)
  }

  /// Applies a fenced code/Markdown block through the same revisioned body
  /// buffer used by the live editor. The editor is focused only after the
  /// staged write succeeds, so a stale concurrent edit cannot be overwritten.
  @discardableResult
  public func applyChatMarkdown(
    _ markdown: String,
    to draft: ArticleDraft,
    mode: AIChatMarkdownInsertionMode
  ) -> Bool {
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = store.drafts.first(where: { $0.id == draft.id }) else {
      store.setPublishActionMessage(
        CoreL10n.text("当前文章已变化，请重新选择后再应用。"),
        status: .warning
      )
      return false
    }

    let insertion = AIChatMarkdownInsertionService.inserting(
      markdown,
      into: currentDraft.bodyMarkdown,
      selection: store.activeEditorSelectionRange(for: currentDraft),
      mode: mode
    )
    guard let insertion else {
      store.setPublishActionMessage(
        CoreL10n.text("代码块内容为空或当前编辑位置已失效。"),
        status: .warning
      )
      return false
    }

    let buffer = store.draftBodyEditorBuffer(for: currentDraft.id)
    guard
      let staged = store.replaceDraftBody(
        insertion.updatedBodyMarkdown,
        for: currentDraft.id,
        expectedRevision: buffer.revision
      ), staged.wasAccepted
    else {
      store.setPublishActionMessage(
        CoreL10n.text("当前文章在应用前已被其他窗口修改，请重新尝试。"),
        status: .warning
      )
      return false
    }

    store.save()
    store.selectSection(.writing)
    store.requestEditorFocus(
      draftID: currentDraft.id,
      field: "body",
      selectedRange: insertion.insertedRange
    )
    switch mode {
    case .applyToCurrentEditor:
      store.setPublishActionMessage(
        CoreL10n.text("已将代码块应用到当前编辑器。"),
        status: .success
      )
    case .insertAtCursor:
      store.setPublishActionMessage(
        CoreL10n.text("已将代码块插入到光标处。"),
        status: .success
      )
    }
    return true
  }

  public func chatPublishingPackage(for draft: ArticleDraft) -> PublishPackage {
    store.publishingPackage(for: draft)
  }

  public func chatPreflightIssues(for draft: ArticleDraft) -> [PreflightIssue] {
    store.preflightIssues(for: draft)
  }

  public func cachedChatImageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport? {
    store.cachedImageWorkbenchReport(for: draft)
  }

  public func refreshChatImageWorkbenchReportInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    await store.refreshImageWorkbenchReportInBackground(for: draft, force: force)
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

  public func setChatKnowledgePolicy(_ policy: KnowledgeRetrievalPolicy) {
    store.setAIChatKnowledgePolicy(policy)
  }

  public func setChatMessage(_ message: String?) {
    store.setAIChatMessage(message)
  }

  @discardableResult
  public func saveChatCustomPrompt(title: String, prompt: String) -> AIPublishingCustomPrompt? {
    store.saveAIChatCustomPrompt(title: title, prompt: prompt)
  }

  public func deleteChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    store.deleteAIChatCustomPrompt(promptID)
  }

  public func setChatConversationTitle(
    _ title: String?,
    draft: ArticleDraft? = nil
  ) {
    store.setAIChatConversationTitle(title, draft: draft)
  }

  @discardableResult
  public func selectChatConversation(_ conversationID: UUID) -> Bool {
    store.selectAIChatConversation(conversationID)
  }

  @discardableResult
  public func startNewChatConversation(
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    store.startNewAIChatConversation(draft: draft)
  }

  @discardableResult
  public func renameChatConversation(
    _ conversationID: UUID,
    title: String?
  ) -> Bool {
    store.renameAIChatConversation(conversationID, title: title)
  }

  @discardableResult
  public func archiveChatConversation(_ conversationID: UUID) -> Bool {
    store.archiveAIChatConversation(conversationID)
  }

  @discardableResult
  public func restoreChatConversation(_ conversationID: UUID) -> Bool {
    store.restoreAIChatConversation(conversationID)
  }

  @discardableResult
  public func deleteChatConversation(_ conversationID: UUID) -> Bool {
    store.deleteAIChatConversation(conversationID)
  }

  @discardableResult
  public func branchChatConversation(
    after messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) -> AIConversation? {
    store.branchAIChatConversation(after: messageID, draft: draft)
  }

  public func cancelChatReply() {
    store.cancelAIChatReply()
  }

  public func cancelChatReply(expectedOwnerToken: UUID) {
    store.aiStore.cancelAIChatReply(expectedOwnerToken: expectedOwnerToken)
  }

  @discardableResult
  public func executeAutomationPlan(
    messageID: AIPublishingChatMessage.ID,
    onlyStepID: UUID? = nil,
    confirmedStepIDs: Set<UUID> = []
  ) async -> WorkbenchAutomationExecutionResult? {
    await store.executeAutomationPlan(
      messageID: messageID,
      onlyStepID: onlyStepID,
      confirmedStepIDs: confirmedStepIDs
    )
  }

  public func automationDraftPreview(
    messageID: AIPublishingChatMessage.ID,
    stepID: UUID
  ) -> WorkbenchAutomationDraftPreview? {
    store.automationDraftPreview(messageID: messageID, stepID: stepID)
  }

  public func cancelAutomationPlan(messageID: AIPublishingChatMessage.ID) {
    store.cancelAutomationPlan(messageID: messageID)
  }

  @discardableResult
  public func rollbackAutomationRun(_ recordID: UUID) -> Int {
    store.rollbackAutomationRun(recordID)
  }

  @discardableResult
  public func retryLastFailedChatReply(
    confirmingPossibleDuplicateCharge: Bool,
    draft: ArticleDraft? = nil,
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    await store.retryLastFailedAIChatReply(
      confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
      draft: draft,
      ownerToken: ownerToken
    )
  }

  @discardableResult
  public func sendChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    ownerToken: UUID? = nil
  ) async -> AIPublishingChatMessage? {
    await store.sendAIChatMessage(
      text,
      draft: draft,
      imageAttachments: imageAttachments,
      contextReferences: contextReferences,
      ownerToken: ownerToken
    )
  }

  public func chatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> [AIChatImageAttachment] {
    await store.aiChatImageAttachments(
      for: draft,
      attachmentIDs: attachmentIDs
    )
  }

  public func availableChatContextReferences(
    for draft: ArticleDraft
  ) -> [AIContextReference] {
    store.aiStore.availableAIChatContextReferences(for: draft)
  }

  public func reviewedStructuredEditDraft(
    message: AIPublishingChatMessage,
    review: AIStructuredEditReview
  ) -> ArticleDraft? {
    guard
      let payload = message.structuredEditPayload,
      payload.document == review.document,
      let current = store.drafts.first(where: { $0.id == payload.sourceDraftID })
    else {
      store.setAIChatMessage("找不到这份结构化修改对应的原稿。")
      return nil
    }
    guard current.repositoryContentFingerprint == payload.sourceContentFingerprint else {
      store.setAIChatMessage("文章已变化，结构化修改未应用；请重新校对。")
      return nil
    }

    do {
      let result = try AIStructuredEditReviewService.apply(
        review,
        to: current.bodyMarkdown
      )
      guard result.hasAppliedChanges else {
        store.setAIChatMessage("尚未接受任何修改。")
        return nil
      }
      var updated = current
      updated.bodyMarkdown = result.finalBody
      store.setAIChatMessage("已生成结构化修改差异，确认后才会写入文章。")
      return updated
    } catch {
      store.setAIChatMessage("结构化修改未通过陈旧检查：\(error.localizedDescription)")
      return nil
    }
  }

  @discardableResult
  public func createLinkedTranslationDraft(
    from plan: AITranslationDraftPlan
  ) -> ArticleDraft? {
    guard let source = store.drafts.first(where: { $0.id == plan.sourceDraftID }) else {
      store.setAIChatMessage("找不到翻译计划对应的原稿。")
      return nil
    }
    if let existing = store.drafts.first(where: { $0.id == plan.translatedDraft.id }) {
      store.selectDraft(existing.id)
      store.setAIChatMessage("这份关联翻译草稿已经创建，已为你打开。")
      return existing
    }

    do {
      let translated = try AITranslationDraftPlanningService.materialize(
        plan,
        currentSource: source
      )
      store.updateDraft(translated)
      store.selectDraft(translated.id)
      store.save()
      store.setAIChatMessage("已创建关联翻译草稿；原稿保持不变。")
      return translated
    } catch {
      store.setAIChatMessage("关联翻译草稿未创建：\(error.localizedDescription)")
      return nil
    }
  }

  public func localFeedbackDecision(
    for message: AIPublishingChatMessage
  ) -> AILocalEditFeedbackDecision? {
    let actionIdentifier = feedbackActionIdentifier(for: message)
    return localFeedbackRecords()
      .filter {
        $0.actionIdentifier == actionIdentifier
          && $0.modelIdentifier == feedbackModelIdentifier(for: message)
      }
      .max(by: { $0.recordedAt < $1.recordedAt })?
      .decision
  }

  public func recordLocalFeedback(
    _ decision: AILocalEditFeedbackDecision,
    for message: AIPublishingChatMessage
  ) {
    let actionIdentifier = feedbackActionIdentifier(for: message)
    let modelIdentifier = feedbackModelIdentifier(for: message)
    var records = localFeedbackRecords().filter {
      !($0.actionIdentifier == actionIdentifier && $0.modelIdentifier == modelIdentifier)
    }
    records.append(
      AILocalEditFeedbackRecord(
        decision: decision,
        actionIdentifier: actionIdentifier,
        modelIdentifier: modelIdentifier
      )
    )
    persistLocalFeedbackRecords(records)
  }

  public func recordStructuredEditFeedback(
    _ decision: AILocalEditFeedbackDecision,
    proposal: AIStructuredEditProposal,
    model: String?
  ) {
    var records = localFeedbackRecords()
    records.append(
      AILocalEditFeedbackRecord(
        decision: decision,
        actionIdentifier: "structured.edit.\(proposal.category.rawValue)",
        modelIdentifier: model?.nilIfEmpty ?? "unknown",
        category: proposal.category
      )
    )
    persistLocalFeedbackRecords(records)
  }

  public func consumePendingQuickPrompt() -> AIPublishingQuickPrompt? {
    store.consumePendingAIQuickPrompt()
  }

  public func focusedChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    store.focusedAIChatParagraph(for: draft)
  }

  @discardableResult
  public func performAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await store.performAIAction(kind, draft: draft, selectedText: selectedText)
  }

  @discardableResult
  public func performAction(
    _ convergence: AIPublishingActionConvergence,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await store.performAIAction(convergence, draft: draft, selectedText: selectedText)
  }

  public func translateRSSArticle(
    _ article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) async throws -> RSSArticleTranslationResult {
    try await store.aiStore.translateRSSArticle(article, target: target)
  }

  private func feedbackActionIdentifier(
    for message: AIPublishingChatMessage
  ) -> String {
    "chat.reply.\(message.id.uuidString)"
  }

  private func feedbackModelIdentifier(
    for message: AIPublishingChatMessage
  ) -> String {
    message.model?.nilIfEmpty ?? "unknown"
  }

  private func localFeedbackRecords() -> [AILocalEditFeedbackRecord] {
    guard
      let data = UserDefaults.standard.data(
        forKey: "aiLocalContentFreeFeedbackRecords"
      ),
      let records = try? JSONDecoder().decode(
        [AILocalEditFeedbackRecord].self,
        from: data
      )
    else {
      return []
    }
    return AILocalEditFeedbackService().boundedRecords(records)
  }

  private func persistLocalFeedbackRecords(
    _ records: [AILocalEditFeedbackRecord]
  ) {
    let bounded = AILocalEditFeedbackService().boundedRecords(records)
    guard let data = try? JSONEncoder().encode(bounded) else { return }
    UserDefaults.standard.set(data, forKey: "aiLocalContentFreeFeedbackRecords")
  }

}
