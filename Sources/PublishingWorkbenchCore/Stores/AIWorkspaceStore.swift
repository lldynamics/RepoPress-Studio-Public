import Combine
import Foundation
import Observation

/// Shared AI workspace state. Views that read these properties are tracked
/// by Observation per property; Combine-based facades bridge through
/// `publisher(for:)` until they are migrated as well.
@MainActor
@Observable
public final class AIWorkspaceStore {
  @ObservationIgnored private let propertyChanges = PassthroughSubject<AnyKeyPath, Never>()

  public internal(set) var aiTokenAvailability: KeychainTokenAvailability {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiTokenAvailability) }
  }
  public internal(set) var aiActionResult: AIPublishingActionResult? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiActionResult) }
  }
  public internal(set) var aiActionMessage: String? {
    didSet {
      propertyChanges.send(\AIWorkspaceStore.aiActionMessage)
      if aiActionMessageIsFailure {
        aiActionMessageIsFailure = false
      }
    }
  }
  public internal(set) var aiActionMessageIsFailure = false {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiActionMessageIsFailure) }
  }
  public internal(set) var isAIActionRunning: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.isAIActionRunning) }
  }
  public internal(set) var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiMetadataApplicationRecords) }
  }
  public internal(set) var automationRunRecords: [WorkbenchAutomationRunRecord] {
    didSet { propertyChanges.send(\AIWorkspaceStore.automationRunRecords) }
  }
  public internal(set) var aiMetadataSuggestionDraftID: UUID? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiMetadataSuggestionDraftID) }
  }
  public internal(set) var aiMetadataSuggestion: AIPublishingMetadataSuggestion? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiMetadataSuggestion) }
  }
  public internal(set) var isAIMetadataSuggestionRunning: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.isAIMetadataSuggestionRunning) }
  }
  public internal(set) var aiChatDraftID: UUID? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatDraftID) }
  }
  public internal(set) var aiChatConversationTitle: String? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatConversationTitle) }
  }
  public internal(set) var aiChatMessages: [AIPublishingChatMessage] {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatMessages) }
  }
  public internal(set) var aiChatContextMode: AIPublishingChatContextMode {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatContextMode) }
  }
  public internal(set) var aiChatKnowledgePolicy: KnowledgeRetrievalPolicy {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatKnowledgePolicy) }
  }
  public internal(set) var aiChatModelGrade: AIChatModelGrade {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatModelGrade) }
  }
  public internal(set) var aiChatReasoningLevel: AIChatReasoningLevel {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatReasoningLevel) }
  }
  public internal(set) var aiChatSelectedModel: String {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatSelectedModel) }
  }
  public internal(set) var aiChatFocusedParagraphID: String? {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatFocusedParagraphID) }
  }
  public internal(set) var aiChatCustomPrompts: [AIPublishingCustomPrompt] {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatCustomPrompts) }
  }
  public internal(set) var aiConversations: [AIConversation] {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiConversations) }
  }
  public internal(set) var activeAIConversationIDsByDraftID: [UUID: UUID] {
    didSet { propertyChanges.send(\AIWorkspaceStore.activeAIConversationIDsByDraftID) }
  }
  public internal(set) var activeAIConversationIDsByScope: [String: UUID] {
    didSet { propertyChanges.send(\AIWorkspaceStore.activeAIConversationIDsByScope) }
  }
  public internal(set) var pendingAIQuickPromptRequest: AIPublishingQuickPromptRequest? {
    didSet { propertyChanges.send(\AIWorkspaceStore.pendingAIQuickPromptRequest) }
  }
  public var pendingAIQuickPrompt: AIPublishingQuickPrompt? {
    pendingAIQuickPromptRequest?.prompt
  }
  public internal(set) var aiChatMessage: String? {
    didSet {
      propertyChanges.send(\AIWorkspaceStore.aiChatMessage)
      if aiChatMessageIsFailure {
        aiChatMessageIsFailure = false
      }
    }
  }
  public internal(set) var aiChatMessageIsFailure = false {
    didSet { propertyChanges.send(\AIWorkspaceStore.aiChatMessageIsFailure) }
  }
  public internal(set) var isAIChatRunning: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.isAIChatRunning) }
  }
  public internal(set) var isAutomationRunning: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.isAutomationRunning) }
  }
  public internal(set) var activeAutomationPlanID: UUID? {
    didSet { propertyChanges.send(\AIWorkspaceStore.activeAutomationPlanID) }
  }
  public internal(set) var automationCancellationRequested: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.automationCancellationRequested) }
  }
  public internal(set) var seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] {
    didSet { propertyChanges.send(\AIWorkspaceStore.seoSocialPreviewSnapshots) }
  }
  public internal(set) var seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? {
    didSet { propertyChanges.send(\AIWorkspaceStore.seoSocialPreviewSnapshot) }
  }
  public internal(set) var seoSocialPreviewMessage: String? {
    didSet { propertyChanges.send(\AIWorkspaceStore.seoSocialPreviewMessage) }
  }
  public internal(set) var isAIPublishingAssistantPresented: Bool {
    didSet { propertyChanges.send(\AIWorkspaceStore.isAIPublishingAssistantPresented) }
  }

  init(
    aiTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(hasToken: false),
    aiActionResult: AIPublishingActionResult? = nil,
    aiActionMessage: String? = nil,
    isAIActionRunning: Bool = false,
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] = [],
    automationRunRecords: [WorkbenchAutomationRunRecord] = [],
    aiMetadataSuggestionDraftID: UUID? = nil,
    aiMetadataSuggestion: AIPublishingMetadataSuggestion? = nil,
    isAIMetadataSuggestionRunning: Bool = false,
    aiChatDraftID: UUID? = nil,
    aiChatConversationTitle: String? = nil,
    aiChatMessages: [AIPublishingChatMessage] = [],
    aiChatContextMode: AIPublishingChatContextMode = .site,
    aiChatKnowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    aiChatModelGrade: AIChatModelGrade = .standard,
    aiChatReasoningLevel: AIChatReasoningLevel = .deep,
    aiChatSelectedModel: String = "",
    aiChatFocusedParagraphID: String? = nil,
    aiChatCustomPrompts: [AIPublishingCustomPrompt] = [],
    aiConversations: [AIConversation] = [],
    activeAIConversationIDsByDraftID: [UUID: UUID] = [:],
    activeAIConversationIDsByScope: [String: UUID] = [:],
    pendingAIQuickPromptRequest: AIPublishingQuickPromptRequest? = nil,
    aiChatMessage: String? = nil,
    isAIChatRunning: Bool = false,
    isAutomationRunning: Bool = false,
    activeAutomationPlanID: UUID? = nil,
    automationCancellationRequested: Bool = false,
    seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] = [:],
    seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? = nil,
    seoSocialPreviewMessage: String? = nil,
    isAIPublishingAssistantPresented: Bool = false
  ) {
    self.aiTokenAvailability = aiTokenAvailability
    self.aiActionResult = aiActionResult
    self.aiActionMessage = aiActionMessage
    self.isAIActionRunning = isAIActionRunning
    self.aiMetadataApplicationRecords = aiMetadataApplicationRecords
    self.automationRunRecords = automationRunRecords
    self.aiMetadataSuggestionDraftID = aiMetadataSuggestionDraftID
    self.aiMetadataSuggestion = aiMetadataSuggestion
    self.isAIMetadataSuggestionRunning = isAIMetadataSuggestionRunning
    self.aiChatDraftID = aiChatDraftID
    self.aiChatConversationTitle = aiChatConversationTitle
    self.aiChatMessages = aiChatMessages
    self.aiChatContextMode = aiChatContextMode
    self.aiChatKnowledgePolicy = aiChatKnowledgePolicy
    self.aiChatModelGrade = aiChatModelGrade
    self.aiChatReasoningLevel = aiChatReasoningLevel
    self.aiChatSelectedModel = aiChatSelectedModel
    self.aiChatFocusedParagraphID = aiChatFocusedParagraphID
    self.aiChatCustomPrompts = aiChatCustomPrompts
    self.aiConversations = aiConversations
    self.activeAIConversationIDsByDraftID = activeAIConversationIDsByDraftID
    self.activeAIConversationIDsByScope = activeAIConversationIDsByScope
    self.pendingAIQuickPromptRequest = pendingAIQuickPromptRequest
    self.aiChatMessage = aiChatMessage
    self.isAIChatRunning = isAIChatRunning
    self.isAutomationRunning = isAutomationRunning
    self.activeAutomationPlanID = activeAutomationPlanID
    self.automationCancellationRequested = automationCancellationRequested
    self.seoSocialPreviewSnapshots = seoSocialPreviewSnapshots
    self.seoSocialPreviewSnapshot = seoSocialPreviewSnapshot
    self.seoSocialPreviewMessage = seoSocialPreviewMessage
    self.isAIPublishingAssistantPresented = isAIPublishingAssistantPresented
  }
}

extension AIWorkspaceStore {
  /// Combine bridge with `@Published` projection semantics: the current
  /// value on subscription, then each assigned value synchronously.
  func publisher<Value>(
    for keyPath: KeyPath<AIWorkspaceStore, Value>
  ) -> AnyPublisher<Value, Never> {
    Deferred { [weak self] in
      Just(self?[keyPath: keyPath]).compactMap { $0 }
    }
    .append(
      propertyChanges
        .filter { $0 == keyPath }
        .compactMap { [weak self] _ in self?[keyPath: keyPath] }
    )
    .eraseToAnyPublisher()
  }

  /// Emits after any tracked property changes.
  var anyPropertyChange: AnyPublisher<Void, Never> {
    propertyChanges.map { _ in () }.eraseToAnyPublisher()
  }
}
