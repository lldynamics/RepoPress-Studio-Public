import Foundation

/// Document reads and mutations that AI features need. This is intentionally
/// narrower than `WorkbenchStore`: it exposes article operations, never the
/// root store or its child stores.
@MainActor
protocol WorkbenchAIDocumentCapability: AnyObject {
  var activeProfile: SiteProfile { get }
  var activeProfileID: UUID { get }
  var profiles: [SiteProfile] { get }
  var drafts: [ArticleDraft] { get }
  var visibleDrafts: [ArticleDraft] { get }
  var selectedDraft: ArticleDraft? { get }
  var selectedDraftID: UUID? { get }
  var activeEditorSelection: ActiveEditorSelection? { get }

  func draft(for draftID: UUID) -> ArticleDraft?
  func profile(for draft: ArticleDraft) -> SiteProfile
  func draftOperationBaseline(for draftID: UUID) -> DraftOperationBaseline?
  func draftBodyEditorBuffer(for draftID: UUID) -> DraftBodyEditorBuffer
  func flushDraftBodyEditorBuffer(for draftID: UUID)
  func flushDraftBodyEditorBufferAndWaitForWordCount(for draftID: UUID) async
  func flushDraftBodyEditorBuffers()
  func updateDraft(_ draft: ArticleDraft)
  func ensureEditableDraftSelected() -> ArticleDraft?
}

/// Knowledge reads and authorization-bound operations available to AI prompts.
/// The protocol returns prompt-safe value snapshots instead of the mutable
/// knowledge store.
@MainActor
protocol WorkbenchAIKnowledgeCapability: AnyObject {
  var knowledgeDocuments: [KnowledgeDocument] { get }

  func knowledgeContext(query: String, policy: KnowledgeRetrievalPolicy) async
    -> KnowledgeContextSnapshot?
  func explicitKnowledgeContextSnapshot(documentID: UUID) async
    -> KnowledgeExplicitContextSnapshot?
  func validateKnowledgeAuthorizationBindings(
    _ bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy
  ) async -> Bool
  func recordKnowledgeBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) async
  func aiPublishingRequestArtifacts(for draft: ArticleDraft) async
    -> AIPublishingRequestArtifacts
  func preflightIssues(for draft: ArticleDraft) -> [PreflightIssue]
  func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport
  func relatedArticleSuggestions(for draft: ArticleDraft, limit: Int) -> [SiteRelationSuggestion]
  func refreshSiteMaintenanceSnapshot(force: Bool) async
}

extension WorkbenchAIKnowledgeCapability {
  func relatedArticleSuggestions(for draft: ArticleDraft) -> [SiteRelationSuggestion] {
    relatedArticleSuggestions(for: draft, limit: 5)
  }

  func refreshSiteMaintenanceSnapshot() async {
    await refreshSiteMaintenanceSnapshot(force: false)
  }
}

/// AI provider selection, protected-workbench gate, and private-content
/// presentation inputs. Credentials themselves remain in their dedicated
/// credential store and are never exposed by this context.
@MainActor
protocol WorkbenchAIPreferencesCapability: AnyObject {
  var canUseProtectedWorkbench: Bool { get }
  var quickHideOperationMessage: String { get }
  var activeAIConnectionProfile: AIConnectionProfile { get }
  var aiChatContextMode: AIPublishingChatContextMode { get }
  var aiChatDraftID: UUID? { get }
  var aiChatMessages: [AIPublishingChatMessage] { get }

  func aiConnectionProfile(for id: UUID) -> AIConnectionProfile?
  func aiConnectionProfile(for profile: SiteProfile) -> AIConnectionProfile
  func aiProviderConfig(for profile: SiteProfile) -> AIProviderConfig
  func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay
  func updateAIConnectionProfile(_ connection: AIConnectionProfile) -> Bool
  func commitActiveProfileSynchronously(_ profile: SiteProfile) -> Bool
}

/// Persistence, operation attribution, and UI state feedback. These intent
/// methods prevent AI code from reaching into the root persistence or
/// publishing stores directly.
@MainActor
protocol WorkbenchAIStateCapability: AnyObject {
  var isRecoveryWriteProtected: Bool { get }

  func save()
  func scheduleAutosave()
  func flushPendingChanges() -> Bool
  func recordAutomationRun(_ record: WorkbenchAutomationRunRecord)
  func setAIChatMessage(_ message: String?)
  func setAIChatFailureMessage(_ message: String)
  func setAIActionFailureMessage(_ message: String)
  func setAIChatMessages(_ messages: [AIPublishingChatMessage])
  func setAIChatRunning(_ isRunning: Bool)
  func setImageActionMessage(_ message: String?)
  func focusDraft(_ id: UUID, section: WorkspaceSection?) -> Bool
  func selectSection(_ section: WorkspaceSection)
  func setInspectorPresented(_ isPresented: Bool)
  func executeAutomationPlan(
    _ plan: WorkbenchAutomationPlan,
    onlyStepID: UUID?,
    shouldCancel: @escaping () -> Bool
  ) async -> WorkbenchAutomationExecutionResult
}

/// The complete but intentionally scoped capability surface used by
/// `WorkbenchAIStore`. Test doubles can implement this protocol without
/// constructing a full workbench root.
@MainActor
protocol WorkbenchAIContext:
  WorkbenchAIDocumentCapability,
  WorkbenchAIKnowledgeCapability,
  WorkbenchAIPreferencesCapability,
  WorkbenchAIStateCapability
{}

/// Composition-layer adapter. It is the sole AI-side object allowed to retain
/// the root store and it never returns that root to callers.
@MainActor
final class WorkbenchAIContextAdapter: WorkbenchAIContext {
  private unowned let root: WorkbenchStore

  init(root: WorkbenchStore) {
    self.root = root
  }

  var activeProfile: SiteProfile { root.activeProfile }
  var activeProfileID: UUID { root.activeProfileID }
  var profiles: [SiteProfile] { root.profiles }
  var drafts: [ArticleDraft] { root.drafts }
  var visibleDrafts: [ArticleDraft] { root.visibleDrafts }
  var selectedDraft: ArticleDraft? { root.selectedDraft }
  var selectedDraftID: UUID? { root.selectedDraftID }
  var activeEditorSelection: ActiveEditorSelection? { root.activeEditorSelection }
  func draft(for draftID: UUID) -> ArticleDraft? { root.draft(for: draftID) }
  func profile(for draft: ArticleDraft) -> SiteProfile { root.profile(for: draft) }
  func draftOperationBaseline(for draftID: UUID) -> DraftOperationBaseline? {
    root.draftOperationBaseline(for: draftID)
  }
  func draftBodyEditorBuffer(for draftID: UUID) -> DraftBodyEditorBuffer {
    root.draftBodyEditorBuffer(for: draftID)
  }
  func flushDraftBodyEditorBuffer(for draftID: UUID) {
    root.flushDraftBodyEditorBuffer(for: draftID)
  }
  func flushDraftBodyEditorBufferAndWaitForWordCount(for draftID: UUID) async {
    root.flushDraftBodyEditorBuffer(for: draftID)
    while let task = root.draftWordCountRefreshTasks[draftID] {
      await task.value
      await Task.yield()
    }
  }
  func flushDraftBodyEditorBuffers() { root.flushDraftBodyEditorBuffers() }
  func updateDraft(_ draft: ArticleDraft) { root.updateDraft(draft) }
  func ensureEditableDraftSelected() -> ArticleDraft? { root.ensureEditableDraftSelected() }

  var knowledgeDocuments: [KnowledgeDocument] { root.knowledge.documents }
  func knowledgeContext(query: String, policy: KnowledgeRetrievalPolicy) async
    -> KnowledgeContextSnapshot?
  {
    await root.knowledge.context(query: query, policy: policy)
  }
  func explicitKnowledgeContextSnapshot(documentID: UUID) async
    -> KnowledgeExplicitContextSnapshot?
  {
    await root.knowledge.explicitAIContextSnapshot(documentID: documentID)
  }
  func validateKnowledgeAuthorizationBindings(
    _ bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy
  ) async -> Bool {
    await root.knowledge.validateKnowledgeAuthorizationBindings(bindings, policy: policy)
  }
  func recordKnowledgeBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) async {
    _ = await root.knowledge.recordBacklinks(citations: citations, target: target)
  }
  func aiPublishingRequestArtifacts(for draft: ArticleDraft) async
    -> AIPublishingRequestArtifacts
  {
    await root.aiPublishingRequestArtifacts(for: draft)
  }
  func preflightIssues(for draft: ArticleDraft) -> [PreflightIssue] {
    root.preflightIssues(for: draft)
  }
  func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    root.imageWorkbenchReport(for: draft)
  }
  func relatedArticleSuggestions(for draft: ArticleDraft, limit: Int) -> [SiteRelationSuggestion] {
    root.relatedArticleSuggestions(for: draft, limit: limit)
  }
  func refreshSiteMaintenanceSnapshot(force: Bool) async {
    await root.refreshSiteMaintenanceSnapshot(force: force)
  }

  var canUseProtectedWorkbench: Bool { root.canUseProtectedWorkbench }
  var quickHideOperationMessage: String { root.quickHideOperationMessage }
  var activeAIConnectionProfile: AIConnectionProfile { root.activeAIConnectionProfile }
  var aiChatContextMode: AIPublishingChatContextMode { root.aiChatContextMode }
  var aiChatDraftID: UUID? { root.aiChatDraftID }
  var aiChatMessages: [AIPublishingChatMessage] { root.aiChatMessages }
  func aiConnectionProfile(for id: UUID) -> AIConnectionProfile? {
    root.aiConnectionProfile(for: id)
  }
  func aiConnectionProfile(for profile: SiteProfile) -> AIConnectionProfile {
    root.aiConnectionProfile(for: profile)
  }
  func aiProviderConfig(for profile: SiteProfile) -> AIProviderConfig {
    root.aiProviderConfig(for: profile)
  }
  func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    root.privateContentDisplay(for: draft)
  }
  func updateAIConnectionProfile(_ connection: AIConnectionProfile) -> Bool {
    root.updateAIConnectionProfile(connection)
  }
  func commitActiveProfileSynchronously(_ profile: SiteProfile) -> Bool {
    root.commitActiveProfileSynchronously(profile)
  }

  var isRecoveryWriteProtected: Bool { root.isPersistenceRecoveryWriteProtected }
  func save() { root.save() }
  func scheduleAutosave() { root.scheduleAutosave() }
  func flushPendingChanges() -> Bool { root.flushPendingChanges() }
  func recordAutomationRun(_ record: WorkbenchAutomationRunRecord) {
    root.recordAutomationRun(record)
  }
  func setAIChatMessage(_ message: String?) { root.setAIChatMessage(message) }
  func setAIChatFailureMessage(_ message: String) { root.setAIChatFailureMessage(message) }
  func setAIActionFailureMessage(_ message: String) { root.setAIActionFailureMessage(message) }
  func setAIChatMessages(_ messages: [AIPublishingChatMessage]) {
    root.setAIChatMessages(messages)
  }
  func setAIChatRunning(_ isRunning: Bool) { root.setAIChatRunning(isRunning) }
  func setImageActionMessage(_ message: String?) { root.setImageActionMessage(message) }
  func focusDraft(_ id: UUID, section: WorkspaceSection?) -> Bool {
    root.focusDraft(id, section: section)
  }
  func selectSection(_ section: WorkspaceSection) { root.selectSection(section) }
  func setInspectorPresented(_ isPresented: Bool) { root.setInspectorPresented(isPresented) }
  func executeAutomationPlan(
    _ plan: WorkbenchAutomationPlan,
    onlyStepID: UUID?,
    shouldCancel: @escaping () -> Bool
  ) async -> WorkbenchAutomationExecutionResult {
    await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: root,
      onlyStepID: onlyStepID,
      shouldCancel: shouldCancel
    )
  }
}
