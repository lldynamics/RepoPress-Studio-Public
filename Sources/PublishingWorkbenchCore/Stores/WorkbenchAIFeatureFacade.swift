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

  public var chatKnowledgePolicy: KnowledgeRetrievalPolicy {
    store.aiChatKnowledgePolicy
  }

  public var chatModelGrade: AIChatModelGrade {
    store.aiChatModelGrade
  }

  public var chatReasoningLevel: AIChatReasoningLevel {
    store.aiChatReasoningLevel
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
    store.aiRefreshKeyAvailability()
  }

  @discardableResult
  public func saveAPIKey(_ token: String) -> Bool {
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

  public func hideAssistant() {
    store.hideAIPublishingAssistant()
  }

  public func closeAssistantPanel() {
    store.hideAIPublishingAssistant()
    store.setInspectorPresented(false)
  }

  public func prepareChat(for draft: ArticleDraft) {
    store.aiPrepareChat(for: draft)
  }

  public func setChatModelGrade(_ grade: AIChatModelGrade) {
    store.aiSetChatModelGrade(grade)
  }

  public func setChatReasoningLevel(_ level: AIChatReasoningLevel) {
    store.aiSetChatReasoningLevel(level)
  }

  public func setChatCustomModel(_ model: String) {
    store.aiSetChatCustomModel(model)
  }

  public func resetChatModelToProfileDefault() {
    store.aiResetChatModelToProfileDefault()
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
    store.aiSaveChatCustomPrompt(title: title, prompt: prompt)
  }

  public func deleteChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    store.aiDeleteChatCustomPrompt(promptID)
  }

  public func startNewChatConversation(draft: ArticleDraft? = nil) {
    store.aiStartNewChatConversation(draft: draft)
  }

  public func cancelChatReply() {
    store.aiCancelChatReply()
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

}
