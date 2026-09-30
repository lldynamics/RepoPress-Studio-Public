import Combine
import Foundation
import PublishingAICore

public struct AIChatManualRetryState: Equatable, Sendable {
  public let draftID: UUID
  public let conversationID: UUID
  public let requiresDuplicateChargeConfirmation: Bool
  public let retryAfter: Date?

  public init(
    draftID: UUID,
    conversationID: UUID,
    requiresDuplicateChargeConfirmation: Bool,
    retryAfter: Date? = nil
  ) {
    self.draftID = draftID
    self.conversationID = conversationID
    self.requiresDuplicateChargeConfirmation = requiresDuplicateChargeConfirmation
    self.retryAfter = retryAfter
  }
}

public struct AIGeneralChatManualRetryState: Equatable, Sendable {
  public let conversationID: UUID
  public let operationID: UUID
  public let requiresDuplicateChargeConfirmation: Bool
  public let retryAfter: Date?

  public init(
    conversationID: UUID,
    operationID: UUID,
    requiresDuplicateChargeConfirmation: Bool,
    retryAfter: Date? = nil
  ) {
    self.conversationID = conversationID
    self.operationID = operationID
    self.requiresDuplicateChargeConfirmation = requiresDuplicateChargeConfirmation
    self.retryAfter = retryAfter
  }
}

struct AIChatConversationIdentity: Equatable, Sendable {
  let draftID: UUID
  let conversationID: UUID
}

@MainActor
public final class WorkbenchAIStore: ObservableObject {
  private let context: WorkbenchAIContext
  /// Extensions retain their existing `store` spelling while the compiler
  /// limits every call to the AI capability contract above.
  var store: WorkbenchAIContext { context }
  let workspace: AIWorkspaceStore
  let aiPublishingAssistantService: AIPublishingAssistantService
  let aiCredentialStore: AICredentialStore
  let aiConnectionTestService: AIConnectionTestService
  let aiDataSharingConsentStore: AIDataSharingConsentStore
  let imageWorkbenchService: SiteImageWorkbenchService
  let seoAuditService: SEOAuditService
  let seoSocialPreviewService: SEOSocialPreviewService
  let aiChatOperationCoordinator = AIChatOperationCoordinator()
  var activeStreamingAuthorization: ActiveStreamingAuthorization?
  @Published public internal(set) var aiWritingStylePreview: AIWritingStyleProfilePreview? = nil
  @Published public internal(set) var isAIWritingStyleExtractionRunning = false
  /// Caps observable chat updates at about 20 FPS while network chunks are
  /// still consumed immediately and accumulated off-view. This keeps the
  /// typewriter effect smooth without scheduling a SwiftUI state publication
  /// for every SSE token.
  let aiChatStreamPublishInterval: Duration = .milliseconds(50)
  /// Test-visible instrumentation for the expensive, structure-level
  /// retention pass. Streaming replacements must not increment this counter.
  var aiConversationRetentionPassCount = 0
  /// Changes only at a durable/structural conversation write. Inspector
  /// projections use this to keep static context out of token publications.
  @Published public internal(set) var aiChatSessionLifecycleRevision: UInt64 = 0
  @Published public internal(set) var aiChatManualRetryState: AIChatManualRetryState? = nil
  @Published public internal(set) var aiGeneralChatManualRetryState:
    AIGeneralChatManualRetryState? = nil

  /// Draft-scoped transient suggestions are kept in the workbench store so
  /// an in-flight request for one article cannot replace the suggestion panel
  /// for another article. The workspace fields below remain the compatibility
  /// projection for the currently selected article.
  @Published public internal(set) var aiMetadataSuggestionRunningDraftIDs: Set<UUID> = []
  @Published public internal(set) var aiDraftSuggestionStateRevision: UInt64 = 0

  var aiMetadataSuggestionsByDraftID: [UUID: AIPublishingMetadataSuggestion] = [:]
  var aiMetadataSuggestionBaselinesByDraftID: [UUID: DraftOperationBaseline] = [:]
  var aiMetadataSuggestionProfilesByDraftID: [UUID: SiteProfile] = [:]
  var aiMetadataSuggestionGenerationsByDraftID: [UUID: UInt64] = [:]
  /// Type-erased cancellation hooks keep the suggestion request shapes
  /// (publishing action and metadata helper) on one draft-scoped lane without storing incompatible Task result types.
  /// The hooks are installed only while the matching generation is awaiting
  /// the network child task.
  var aiMetadataSuggestionCancellationHandlersByDraftID: [UUID: () -> Void] = [:]
  var aiActionOperationIDs: Set<UUID> = []
  var aiRequestGeneration: UInt64 = 0
  var aiRequestPresentationGeneration: UInt64?
  var aiRequestGenerations: [AIGenerationLane: UInt64] = [:]
  var aiRequestCancellations: [AIGenerationLane: () -> Void] = [:]
  var aiRequestActionOperations: [AIGenerationLane: UUID] = [:]
  var aiRequestBaselines: [AIGenerationLane: DraftOperationBaseline] = [:]
  var aiRequestProfiles: [AIGenerationLane: SiteProfile] = [:]
  var aiRequestContextChecks: [AIGenerationLane: () -> Bool] = [:]
  var aiRequestAuthorizationBindings: [AIGenerationLane: AINonStreamingAuthorizationBinding] = [:]
  var aiPublishingActionRequest: (lane: AIGenerationLane, generation: UInt64)?

  init(
    context: WorkbenchAIContext,
    workspace: AIWorkspaceStore,
    aiPublishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService(),
    aiCredentialStore: AICredentialStore,
    aiConnectionTestService: AIConnectionTestService = AIConnectionTestService(),
    aiDataSharingConsentStore: AIDataSharingConsentStore = AIDataSharingConsentStore(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    seoAuditService: SEOAuditService = SEOAuditService(),
    seoSocialPreviewService: SEOSocialPreviewService = SEOSocialPreviewService()
  ) {
    self.context = context
    self.workspace = workspace
    self.aiCredentialStore = aiCredentialStore
    self.aiConnectionTestService = aiConnectionTestService
    self.aiDataSharingConsentStore = aiDataSharingConsentStore
    // Bind the app-server request gate to this exact store instance. This is
    // intentionally done at the Workbench boundary so the client used by all
    // publishing/general AI flows cannot silently fall back to a second
    // default consent store.
    self.aiPublishingAssistantService = AIPublishingAssistantService(
      client: aiPublishingAssistantService.client.withCodexAppServerRequestAuthorizer(
        CodexAppServerRequestAuthorizer(
          consentStore: aiDataSharingConsentStore,
          accountStatusProvider: CodexAppServerClient.shared
        )
      )
    )
    self.imageWorkbenchService = imageWorkbenchService
    self.seoAuditService = seoAuditService
    self.seoSocialPreviewService = seoSocialPreviewService

    // Older persisted workspaces may contain one compatibility projection.
    // Seed it into the keyed transient cache so the first selection restore
    // does not discard a still-useful suggestion.
    if let draftID = workspace.aiMetadataSuggestionDraftID,
      let suggestion = workspace.aiMetadataSuggestion,
      let baseline = context.draftOperationBaseline(for: draftID)
    {
      aiMetadataSuggestionsByDraftID[draftID] = suggestion
      aiMetadataSuggestionBaselinesByDraftID[draftID] = baseline
      aiMetadataSuggestionProfilesByDraftID[draftID] = context.profile(for: baseline.draft)
    }
  }

  public var aiTokenAvailability: KeychainTokenAvailability {
    get { workspace.aiTokenAvailability }
    set { workspace.aiTokenAvailability = newValue }
  }

  public var aiActionResult: AIPublishingActionResult? {
    get { workspace.aiActionResult }
    set { workspace.aiActionResult = newValue }
  }

  public var aiActionMessage: String? {
    get { workspace.aiActionMessage }
    set { workspace.aiActionMessage = newValue }
  }

  public var isAIActionRunning: Bool {
    get { !aiActionOperationIDs.isEmpty || workspace.isAIActionRunning }
    set { workspace.isAIActionRunning = newValue }
  }

  public var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] {
    get { workspace.aiMetadataApplicationRecords }
    set { workspace.aiMetadataApplicationRecords = newValue }
  }

  public var aiMetadataSuggestionDraftID: UUID? {
    get { workspace.aiMetadataSuggestionDraftID }
    set { workspace.aiMetadataSuggestionDraftID = newValue }
  }

  public var aiMetadataSuggestion: AIPublishingMetadataSuggestion? {
    get { workspace.aiMetadataSuggestion }
    set { workspace.aiMetadataSuggestion = newValue }
  }

  public var isAIMetadataSuggestionRunning: Bool {
    get { !aiMetadataSuggestionRunningDraftIDs.isEmpty || workspace.isAIMetadataSuggestionRunning }
    set { workspace.isAIMetadataSuggestionRunning = newValue }
  }

  public var aiChatDraftID: UUID? {
    get { workspace.aiChatDraftID }
    set { workspace.aiChatDraftID = newValue }
  }

  public var aiChatConversationTitle: String? {
    get { workspace.aiChatConversationTitle }
    set { workspace.aiChatConversationTitle = newValue }
  }

  public var aiChatMessages: [AIPublishingChatMessage] {
    get { workspace.aiChatMessages }
    set { workspace.aiChatMessages = newValue }
  }

  public var aiChatContextMode: AIPublishingChatContextMode {
    get { workspace.aiChatContextMode }
    set { workspace.aiChatContextMode = newValue }
  }

  public var aiChatKnowledgePolicy: KnowledgeRetrievalPolicy {
    get { workspace.aiChatKnowledgePolicy }
    set { workspace.aiChatKnowledgePolicy = newValue }
  }

  public var aiChatModelGrade: AIChatModelGrade {
    get { workspace.aiChatModelGrade }
    set { workspace.aiChatModelGrade = newValue }
  }

  public var aiChatReasoningLevel: AIChatReasoningLevel {
    get { workspace.aiChatReasoningLevel }
    set { workspace.aiChatReasoningLevel = newValue }
  }

  public var aiChatSelectedModel: String {
    get { workspace.aiChatSelectedModel }
    set { workspace.aiChatSelectedModel = newValue }
  }

  public var aiChatFocusedParagraphID: String? {
    get { workspace.aiChatFocusedParagraphID }
    set { workspace.aiChatFocusedParagraphID = newValue }
  }

  public var aiChatCustomPrompts: [AIPublishingCustomPrompt] {
    get { workspace.aiChatCustomPrompts }
    set { workspace.aiChatCustomPrompts = newValue }
  }

  public var aiConversations: [AIConversation] {
    get { workspace.aiConversations }
    set {
      aiConversationRetentionPassCount &+= 1
      aiChatSessionLifecycleRevision &+= 1
      let pendingAgentConversationIDs = Set(
        newValue.compactMap { conversation in
          conversation.messages.contains(where: { message in
            message.agentContinuation?.phase.requiresExplicitDisposition == true
          }) ? conversation.id : nil
        }
      )
      let limitedConversations = AIConversationRetentionPolicy.limited(
        newValue,
        preserving: Set(workspace.activeAIConversationIDsByDraftID.values)
          .union(workspace.activeAIConversationIDsByScope.values)
          .union(pendingAgentConversationIDs)
      )
      workspace.aiConversations = limitedConversations
      workspace.activeAIConversationIDsByDraftID =
        AIConversationRetentionPolicy.validActiveConversationIDs(
          workspace.activeAIConversationIDsByDraftID,
          conversations: limitedConversations
        )
      workspace.activeAIConversationIDsByScope =
        AIConversationRetentionPolicy.validActiveConversationIDsByScope(
          workspace.activeAIConversationIDsByScope,
          conversations: limitedConversations
        )
    }
  }

  /// Replaces the payload of an existing conversation during a live stream.
  /// This intentionally bypasses `aiConversations` so a 20 FPS text update
  /// cannot sort, group, or image-normalise every saved conversation. Normal
  /// session writes still flow through the public property at completion,
  /// cancellation, and all structural edits.
  func replaceAIConversationStreaming(
    at index: Int,
    with state: AIPublishingChatSessionState,
    updatedAt: Date = Date()
  ) {
    guard workspace.aiConversations.indices.contains(index) else { return }
    workspace.aiConversations[index].applyStreaming(state, updatedAt: updatedAt)
  }

  public var activeAIConversationIDsByDraftID: [UUID: UUID] {
    get { workspace.activeAIConversationIDsByDraftID }
    set { workspace.activeAIConversationIDsByDraftID = newValue }
  }

  public var activeAIConversationIDsByScope: [String: UUID] {
    get { workspace.activeAIConversationIDsByScope }
    set { workspace.activeAIConversationIDsByScope = newValue }
  }

  public var pendingAIQuickPrompt: AIPublishingQuickPrompt? {
    workspace.pendingAIQuickPrompt
  }

  public internal(set) var pendingAIQuickPromptRequest: AIPublishingQuickPromptRequest? {
    get { workspace.pendingAIQuickPromptRequest }
    set { workspace.pendingAIQuickPromptRequest = newValue }
  }

  public var aiChatMessage: String? {
    get { workspace.aiChatMessage }
    set { workspace.aiChatMessage = newValue }
  }

  public var isAIChatRunning: Bool {
    get { workspace.isAIChatRunning }
    set { workspace.isAIChatRunning = newValue }
  }

  public var seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] {
    get { workspace.seoSocialPreviewSnapshots }
    set { workspace.seoSocialPreviewSnapshots = newValue }
  }

  public var seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? {
    get { workspace.seoSocialPreviewSnapshot }
    set { workspace.seoSocialPreviewSnapshot = newValue }
  }

  public var seoSocialPreviewMessage: String? {
    get { workspace.seoSocialPreviewMessage }
    set { workspace.seoSocialPreviewMessage = newValue }
  }

  public var isAIPublishingAssistantPresented: Bool {
    get { workspace.isAIPublishingAssistantPresented }
    set { workspace.isAIPublishingAssistantPresented = newValue }
  }

  public func aiActionStateChanged() {
    refreshAIKeyAvailability()
  }

  public func restoreSEOSocialPreviewSnapshotForCurrentSelection() {
    seoSocialPreviewSnapshot = store.selectedDraft.flatMap { seoSocialPreviewSnapshots[$0.id] }
    restoreDraftSuggestionProjectionForCurrentSelection()
  }

  public func prepareSEOSocialPreview(for draft: ArticleDraft) {
    if let snapshot = seoSocialPreviewSnapshots[draft.id] {
      seoSocialPreviewSnapshot = snapshot
    } else {
      refreshSEOSocialPreview(for: draft, message: nil)
    }
  }

  public func refreshSEOSocialPreview(for draft: ArticleDraft, message: String? = "SEO / 社交预览已刷新。")
  {
    let snapshot = seoSocialPreviewService.snapshot(
      draft: draft, profile: store.profile(for: draft))
    seoSocialPreviewSnapshots[draft.id] = snapshot
    seoSocialPreviewSnapshot = snapshot
    seoSocialPreviewMessage = message
    store.save()
  }

  public func isSEOSocialPreviewStale(for draft: ArticleDraft) -> Bool {
    guard let snapshot = seoSocialPreviewSnapshots[draft.id] else { return true }
    let current = seoSocialPreviewService.snapshot(draft: draft, profile: store.profile(for: draft))
    return snapshot.signature != current.signature
  }

  public func seoSocialPreviewSnapshot(for draft: ArticleDraft) -> SEOSocialPreviewSnapshot? {
    seoSocialPreviewSnapshots[draft.id]
  }

  public func seoReport(for draft: ArticleDraft) -> SEOAuditReport {
    seoAuditService.report(draft: draft, profile: store.profile(for: draft))
  }

  public var aiDataSharingConsentPresentation: AIDataSharingConsentPresentation {
    aiDataSharingConsentPresentation(for: store.aiProviderConfig(for: store.activeProfile))
  }

  public func aiDataSharingConsentPresentation(
    for config: AIProviderConfig
  ) -> AIDataSharingConsentPresentation {
    aiDataSharingConsentStore.presentation(for: config)
  }

  public func aiDataSharingConsentPresentation(
    for config: AIProviderConfig,
    codexAccountStatus: CodexAppServerAccountStatus?
  ) -> AIDataSharingConsentPresentation {
    aiDataSharingConsentStore.presentation(
      for: config,
      codexAccountStatus: codexAccountStatus
    )
  }
}
