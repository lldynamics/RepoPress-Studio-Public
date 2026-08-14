
import Foundation
struct WorkbenchPersistenceSnapshotInput: Sendable {
  let profiles: [SiteProfile]
  let aiConnectionProfiles: [AIConnectionProfile]
  let activeProfileID: UUID
  let drafts: [ArticleDraft]
  let softwareGuideSeedVersion: Int
  let customMarkdownSnippets: [MarkdownSnippet]
  let markdownEditorSessionStates: [UUID: MarkdownEditorSessionState]
  let draftVersions: [DraftVersionSnapshot]
  let recycledDrafts: [RecycledDraft]
  let draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest]
  let releaseRecords: [ReleaseRecord]
  let maintenanceOperationRecords: [MaintenanceOperationRecord]
  let aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord]
  let automationRunRecords: [WorkbenchAutomationRunRecord]
  let aiChatCustomPrompts: [AIPublishingCustomPrompt]
  let aiConversations: [AIConversation]
  let activeAIConversationIDsByDraftID: [UUID: UUID]
  let activeAIConversationIDsByScope: [String: UUID]
  let seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot]
  let privacySettings: PrivacyProtectionSettings
  let repositoryAutoSyncSettings: RepositoryAutoSyncSettings
  let repositoryAutoSyncState: RepositoryAutoSyncState
  let remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  let deploymentPollingSettings: DeploymentPollingSettings
  let deploymentPollingState: DeploymentPollingState
  let deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot]
  let deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]

  init(
    profiles: [SiteProfile],
    aiConnectionProfiles: [AIConnectionProfile],
    activeProfileID: UUID,
    drafts: [ArticleDraft],
    softwareGuideSeedVersion: Int,
    customMarkdownSnippets: [MarkdownSnippet],
    markdownEditorSessionStates: [UUID: MarkdownEditorSessionState],
    draftVersions: [DraftVersionSnapshot],
    recycledDrafts: [RecycledDraft],
    draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest],
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord],
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord],
    automationRunRecords: [WorkbenchAutomationRunRecord],
    aiChatCustomPrompts: [AIPublishingCustomPrompt],
    aiConversations: [AIConversation],
    activeAIConversationIDsByDraftID: [UUID: UUID],
    activeAIConversationIDsByScope: [String: UUID],
    seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot],
    privacySettings: PrivacyProtectionSettings,
    repositoryAutoSyncSettings: RepositoryAutoSyncSettings,
    repositoryAutoSyncState: RepositoryAutoSyncState,
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?,
    deploymentPollingSettings: DeploymentPollingSettings,
    deploymentPollingState: DeploymentPollingState,
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]
  ) {
    self.profiles = profiles
    self.aiConnectionProfiles = aiConnectionProfiles
    self.activeProfileID = activeProfileID
    self.drafts = drafts
    self.softwareGuideSeedVersion = softwareGuideSeedVersion
    self.customMarkdownSnippets = customMarkdownSnippets
    self.markdownEditorSessionStates = markdownEditorSessionStates
    self.draftVersions = draftVersions
    self.recycledDrafts = recycledDrafts
    self.draftRepositoryCleanupRequests = draftRepositoryCleanupRequests
    self.releaseRecords = releaseRecords
    self.maintenanceOperationRecords = maintenanceOperationRecords
    self.aiMetadataApplicationRecords = aiMetadataApplicationRecords
    self.automationRunRecords = automationRunRecords
    self.aiChatCustomPrompts = aiChatCustomPrompts
    self.aiConversations = aiConversations
    self.activeAIConversationIDsByDraftID = activeAIConversationIDsByDraftID
    self.activeAIConversationIDsByScope = activeAIConversationIDsByScope
    self.seoSocialPreviewSnapshots = seoSocialPreviewSnapshots
    self.privacySettings = privacySettings
    self.repositoryAutoSyncSettings = repositoryAutoSyncSettings
    self.repositoryAutoSyncState = repositoryAutoSyncState
    self.remoteRepositoryAccessCheck = remoteRepositoryAccessCheck
    self.deploymentPollingSettings = deploymentPollingSettings
    self.deploymentPollingState = deploymentPollingState
    self.deploymentStatusSnapshots = deploymentStatusSnapshots
    self.deploymentStatusHistory = deploymentStatusHistory
  }
}

extension WorkbenchPersistence {
  /// Performs all existing snapshot normalization away from MainActor.
  func snapshot(from input: WorkbenchPersistenceSnapshotInput) -> WorkbenchSnapshot {
    WorkbenchSnapshot(
      profiles: input.profiles,
      aiConnectionProfiles: input.aiConnectionProfiles,
      activeProfileID: input.activeProfileID,
      drafts: input.drafts,
      softwareGuideSeedVersion: input.softwareGuideSeedVersion,
      customMarkdownSnippets: input.customMarkdownSnippets,
      markdownEditorSessionStates: input.markdownEditorSessionStates,
      draftVersions: input.draftVersions,
      recycledDrafts: input.recycledDrafts,
      draftRepositoryCleanupRequests: input.draftRepositoryCleanupRequests,
      releaseRecords: input.releaseRecords,
      maintenanceOperationRecords: input.maintenanceOperationRecords,
      aiMetadataApplicationRecords: input.aiMetadataApplicationRecords,
      automationRunRecords: input.automationRunRecords,
      aiChatCustomPrompts: input.aiChatCustomPrompts,
      aiConversations: input.aiConversations,
      activeAIConversationIDsByDraftID: input.activeAIConversationIDsByDraftID,
      activeAIConversationIDsByScope: input.activeAIConversationIDsByScope,
      seoSocialPreviewSnapshots: Array(input.seoSocialPreviewSnapshots.values),
      privacySettings: input.privacySettings,
      privacyProtectionEvents: [],
      repositoryAutoSyncSettings: input.repositoryAutoSyncSettings,
      repositoryAutoSyncState: input.repositoryAutoSyncState,
      remoteRepositoryAccessCheck: input.remoteRepositoryAccessCheck,
      deploymentPollingSettings: input.deploymentPollingSettings,
      deploymentPollingState: input.deploymentPollingState,
      deploymentStatusSnapshots: Array(input.deploymentStatusSnapshots.values),
      deploymentStatusHistory: input.deploymentStatusHistory
    )
  }
}

@MainActor
extension WorkbenchPersistence {
  /// Freezes store state on MainActor without constructing a normalized snapshot.
  func snapshotInput(from store: WorkbenchStore) -> WorkbenchPersistenceSnapshotInput {
    WorkbenchPersistenceSnapshotInput(
      profiles: store.profiles,
      aiConnectionProfiles: store.aiConnectionProfiles,
      activeProfileID: store.activeProfileID,
      drafts: store.drafts,
      softwareGuideSeedVersion: store.softwareGuideSeedVersion,
      customMarkdownSnippets: store.customMarkdownSnippets,
      markdownEditorSessionStates: store.markdownEditorSessionStates,
      draftVersions: store.draftVersions,
      recycledDrafts: store.recycledDrafts,
      draftRepositoryCleanupRequests: store.draftRepositoryCleanupRequests,
      releaseRecords: store.releaseRecords,
      maintenanceOperationRecords: store.maintenanceOperationRecords,
      aiMetadataApplicationRecords: store.aiMetadataApplicationRecords,
      automationRunRecords: store.automationRunRecords,
      aiChatCustomPrompts: store.aiChatCustomPrompts,
      aiConversations: store.aiConversations,
      activeAIConversationIDsByDraftID: store.activeAIConversationIDsByDraftID,
      activeAIConversationIDsByScope: store.activeAIConversationIDsByScope,
      seoSocialPreviewSnapshots: store.seoSocialPreviewSnapshots,
      privacySettings: store.privacySettings,
      repositoryAutoSyncSettings: store.repositoryAutoSyncSettings,
      repositoryAutoSyncState: store.repositoryAutoSyncState,
      remoteRepositoryAccessCheck: store.remoteRepositoryAccessCheck,
      deploymentPollingSettings: store.deploymentPollingSettings,
      deploymentPollingState: store.deploymentPollingState,
      deploymentStatusSnapshots: store.deploymentStatusSnapshots,
      deploymentStatusHistory: store.deploymentStatusHistory
    )
  }

  /// Compatibility for synchronous library callers that already hold a store.
  /// Autosave and exit-flush paths use `snapshotInput(from:)` instead.
  func snapshot(from store: WorkbenchStore) -> WorkbenchSnapshot {
    snapshot(from: snapshotInput(from: store))
  }

  public func save(store: WorkbenchStore) {
    do {
      switch try save(snapshot(from: store)) {
      case .saved:
        store.recordPersistenceSaveSucceeded()
      case .savedWithoutBackup(let message):
        store.recordPersistenceSaveSucceeded(backupWarning: message)
      }
    } catch {
      store.recordPersistenceSaveFailed(error)
    }
  }
}

extension JSONEncoder {
  static var workbench: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  static var workbench: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
