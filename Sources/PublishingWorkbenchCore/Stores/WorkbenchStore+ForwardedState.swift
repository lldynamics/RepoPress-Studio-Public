import Foundation
import PublishingGitCore

extension WorkbenchStore {
  public var repositoryMergeConflictSession: RepositoryMergeConflictSession? {
    repositoryStore.repositoryMergeConflictSession(for: activeProfile, store: self)
  }

  public func resolveRepositoryMergeConflict(
    repositoryPath: String,
    finalContent: String
  ) async throws {
    try await repositoryStore.resolveRepositoryMergeConflict(
      repositoryPath: repositoryPath,
      finalContent: finalContent,
      store: self
    )
  }

  public var releaseRecords: [ReleaseRecord] { publishingStore.releaseRecords }
  public var selectedSection: WorkspaceSection { publishingStore.selectedSection }
  public var selectedDraftID: UUID? { publishingStore.selectedDraftID }
  public var draftListContentScope: DraftListContentScope { publishingStore.draftListContentScope }
  public var customMarkdownSnippets: [MarkdownSnippet] { publishingStore.customMarkdownSnippets }

  public var publishPackage: PublishPackage? { publishingStore.publishPackage }
  public var localPublishPreview: LocalPublishPreview? { publishingStore.localPublishPreview }
  public var localPublishReadiness: LocalPublishReadiness? { publishingStore.localPublishReadiness }
  public var isPublishPreviewRefreshing: Bool { publishingStore.isPublishPreviewRefreshing }
  public var remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? { publishingStore.remotePublishPreviewSnapshot }
  public var batchPublishPlan: BatchPublishPlan? { publishingStore.batchPublishPlan }
  public var isBatchPublishPlanRefreshing: Bool { publishingStore.isBatchPublishPlanRefreshing }
  public var batchRemotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? { publishingStore.batchRemotePublishPreviewSnapshot }
  public var remoteRepositoryConflictSession: RemoteRepositoryConflictSession? {
    publishingStore.remoteRepositoryConflictSession
  }
  public var localSitePreviewPlan: LocalSitePreviewPlan? { publishingStore.localSitePreviewPlan }
  public var localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus { publishingStore.localSitePreviewRuntimeStatus }
  public var remoteReviewDraft: RemoteReviewDraft? { publishingStore.remoteReviewDraft }
  public var batchRemoteReviewDraft: RemoteReviewDraft? { publishingStore.batchRemoteReviewDraft }
  public var siteStarterResult: SiteStarterResult? { publishingStore.siteStarterResult }
  public var siteStarterImportResult: SiteStarterImportResult? { publishingStore.siteStarterImportResult }
  public var siteStarterPushResult: SiteStarterPushResult? { publishingStore.siteStarterPushResult }
  public var isSiteStarterOperationRunning: Bool { publishingStore.isSiteStarterOperationRunning }
  public var preflightIssues: [PreflightIssue] { publishingStore.preflightIssues }
  public var isInspectorPresented: Bool { publishingStore.isInspectorPresented }
  public var editorFocusRequest: EditorFocusRequest? { publishingStore.editorFocusRequest }
  public var imageInspectorFocusRequest: ImageInspectorFocusRequest? {
    publishingStore.imageInspectorFocusRequest
  }
  public var activeEditorSelection: ActiveEditorSelection? { publishingStore.activeEditorSelection }
  public var automaticallyRefreshPreflightOnEdit: Bool { publishingStore.automaticallyRefreshPreflightOnEdit }
  public var lastSaveStatus: String { persistenceStore.status }
  public var hasUnsavedChanges: Bool { persistenceStore.hasUnsavedChanges }
  public var lastSaveError: String? {
    draftRecoveryJournalErrorMessage ?? persistenceStore.lastSaveError
  }
  public var persistenceRecoveryMessage: String? { persistenceStore.recoveryMessage }
  public var isPersistenceRecoveryWriteProtected: Bool { persistenceStore.isRecoveryWriteProtected }
  public var pendingDraftRecoveryCount: Int { pendingDraftRecoveries.count }
  public var publishActionFeedback: PublishActionFeedback? {
    publishingStore.publishActionFeedback
  }
  public var publishActionMessage: String? { publishingStore.publishActionMessage }
  public var isLocalRepositoryMutationRunning: Bool { publishingStore.isLocalRepositoryMutationRunning }
  public var imageActionMessage: String? { publishingStore.imageActionMessage }
  public var maintenanceOperationRecords: [MaintenanceOperationRecord] { publishingStore.maintenanceOperationRecords }
  public var siteMaintenanceSnapshot: SiteMaintenanceSnapshot? { siteMaintenanceStore.snapshot }
  public var siteMaintenanceSnapshotVersion: Int { siteMaintenanceStore.snapshotVersion }
  public var latestGeneralDraftReusePlan: GeneralDraftReusePlan? { publishingStore.latestGeneralDraftReusePlan }
}

extension WorkbenchStore {
  public var repositoryScanState: RepositoryScanState {
    repositoryStore.repositoryScanState(for: activeProfileID)
  }
  public var localGitPublishResult: LocalGitPublishResult? { repositoryStore.localGitPublishResult }
  public var localRepositoryBranches: [RepositoryBranch] {
    repositoryReport == nil ? [] : repositoryStore.localRepositoryBranches
  }
  public var localRepositoryRecentCommits: [RepositoryCommitInfo] {
    repositoryReport == nil ? [] : repositoryStore.localRepositoryRecentCommits
  }
  public var localRepositoryReleaseHistory: RepositoryReleaseHistorySnapshot {
    guard repositoryReport != nil else {
      return RepositoryReleaseHistorySnapshot(
        historyAvailability: .unavailable,
        notesAvailability: .unavailable
      )
    }
    return repositoryStore.localRepositoryReleaseHistory
  }
  public var repositoryTokenAvailability: KeychainTokenAvailability { repositoryStore.repositoryTokenAvailability }
  public var remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? { repositoryStore.remoteRepositoryAccessCheck }
  public var remoteRepositoryCreationResult: RemoteRepositoryCreationResult? { repositoryStore.remoteRepositoryCreationResult }
  public var remoteRepositoryPublishResult: RemoteRepositoryPublishResult? { repositoryStore.remoteRepositoryPublishResult }
  public var remoteRepositoryPublishProgress: RemoteRepositoryPublishProgress? { repositoryStore.remoteRepositoryPublishProgress }
  public var remoteRepositoryRollbackResult: RemoteRepositoryRollbackResult? { repositoryStore.remoteRepositoryRollbackResult }
  public var remoteRepositoryReviewWithdrawalResult: RemoteRepositoryReviewWithdrawalResult? { repositoryStore.remoteRepositoryReviewWithdrawalResult }
  public var isRemoteRepositoryChecking: Bool { repositoryStore.isRemoteRepositoryChecking }
  public var isRemoteRepositoryPublishing: Bool { repositoryStore.isRemoteRepositoryPublishing }
  public var isLocalRepositoryBranchOperationRunning: Bool {
    repositoryStore.isLocalRepositoryBranchOperationRunning
  }
  public var repositoryAutoSyncSettings: RepositoryAutoSyncSettings { repositoryStore.repositoryAutoSyncSettings }
  public var repositoryAutoSyncState: RepositoryAutoSyncState { repositoryStore.repositoryAutoSyncState }
  public func repositoryAutoSyncSettings(for profileID: UUID) -> RepositoryAutoSyncSettings {
    repositoryStore.repositoryAutoSyncSettings(for: profileID)
  }
  public func repositoryAutoSyncState(for profileID: UUID) -> RepositoryAutoSyncState {
    repositoryStore.repositoryAutoSyncState(for: profileID)
  }
}

extension WorkbenchStore {
  public var deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot] { deploymentStore.deploymentStatusSnapshots }
  public var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] { deploymentStore.deploymentStatusHistory }
  public var isDeploymentStatusChecking: Bool { deploymentStore.isDeploymentStatusChecking }
  public var deploymentStatusMessage: String? { deploymentStore.deploymentStatusMessage }
  public var deploymentPollingSettings: DeploymentPollingSettings { deploymentStore.deploymentPollingSettings }
  public var deploymentPollingState: DeploymentPollingState { deploymentStore.deploymentPollingState }
  public func deploymentPollingSettings(for profileID: UUID) -> DeploymentPollingSettings {
    deploymentStore.deploymentPollingSettings(for: profileID)
  }
  public func deploymentPollingState(for profileID: UUID) -> DeploymentPollingState {
    deploymentStore.deploymentPollingState(for: profileID)
  }
  public var deploymentTokenAvailability: KeychainTokenAvailability { deploymentStore.deploymentTokenAvailability }
}

extension WorkbenchStore {
  public var aiTokenAvailability: KeychainTokenAvailability { aiWorkspaceStore.aiTokenAvailability }
  public var aiActionResult: AIPublishingActionResult? { aiWorkspaceStore.aiActionResult }
  public var aiActionMessage: String? { aiWorkspaceStore.aiActionMessage }
  public var isAIActionRunning: Bool { aiWorkspaceStore.isAIActionRunning }
  public var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] { aiWorkspaceStore.aiMetadataApplicationRecords }
  public var automationRunRecords: [WorkbenchAutomationRunRecord] { aiWorkspaceStore.automationRunRecords }
  public var aiMetadataSuggestionDraftID: UUID? { aiWorkspaceStore.aiMetadataSuggestionDraftID }
  public var aiMetadataSuggestion: AIPublishingMetadataSuggestion? { aiWorkspaceStore.aiMetadataSuggestion }
  public var isAIMetadataSuggestionRunning: Bool { aiWorkspaceStore.isAIMetadataSuggestionRunning }
  public var aiChatDraftID: UUID? { aiWorkspaceStore.aiChatDraftID }
  public var aiChatConversationTitle: String? { aiWorkspaceStore.aiChatConversationTitle }
  public var aiChatMessages: [AIPublishingChatMessage] { aiWorkspaceStore.aiChatMessages }
  public var aiChatContextMode: AIPublishingChatContextMode { aiWorkspaceStore.aiChatContextMode }
  public var aiChatKnowledgePolicy: KnowledgeRetrievalPolicy { aiWorkspaceStore.aiChatKnowledgePolicy }
  public var aiChatModelGrade: AIChatModelGrade { aiWorkspaceStore.aiChatModelGrade }
  public var aiChatReasoningLevel: AIChatReasoningLevel { aiWorkspaceStore.aiChatReasoningLevel }
  public var aiChatSelectedModel: String { aiWorkspaceStore.aiChatSelectedModel }
  public var aiChatFocusedParagraphID: String? { aiWorkspaceStore.aiChatFocusedParagraphID }
  public var aiChatCustomPrompts: [AIPublishingCustomPrompt] { aiWorkspaceStore.aiChatCustomPrompts }
  public var aiConversations: [AIConversation] { aiWorkspaceStore.aiConversations }
  public var activeAIConversationIDsByDraftID: [UUID: UUID] {
    aiWorkspaceStore.activeAIConversationIDsByDraftID
  }
  public var activeAIConversationIDsByScope: [String: UUID] {
    aiWorkspaceStore.activeAIConversationIDsByScope
  }
  public var pendingAIQuickPrompt: AIPublishingQuickPrompt? { aiWorkspaceStore.pendingAIQuickPrompt }
  public var aiChatMessage: String? { aiWorkspaceStore.aiChatMessage }
  public var isAIChatRunning: Bool { aiWorkspaceStore.isAIChatRunning }
  public var aiChatManualRetryState: AIChatManualRetryState? { aiStore.aiChatManualRetryState }
  public var aiImageTextSuggestionDraftID: UUID? { aiWorkspaceStore.aiImageTextSuggestionDraftID }
  public var aiImageTextSuggestions: [AIPublishingImageTextSuggestion] { aiWorkspaceStore.aiImageTextSuggestions }
  public var isAIImageTextRunning: Bool { aiWorkspaceStore.isAIImageTextRunning }
  public var seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] { aiWorkspaceStore.seoSocialPreviewSnapshots }
  public var seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? { aiWorkspaceStore.seoSocialPreviewSnapshot }
  public var seoSocialPreviewMessage: String? { aiWorkspaceStore.seoSocialPreviewMessage }
  public var isAIPublishingAssistantPresented: Bool { aiWorkspaceStore.isAIPublishingAssistantPresented }
}

extension WorkbenchStore {
  public var privacySettings: PrivacyProtectionSettings { privacyProtectionStore.privacySettings }
  public var isQuickHideActive: Bool { privacyProtectionStore.isQuickHideActive }
  public var quickHideReason: String? { privacyProtectionStore.quickHideReason }
}
