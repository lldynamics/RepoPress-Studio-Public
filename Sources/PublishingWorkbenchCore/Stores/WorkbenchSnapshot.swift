import Foundation

public struct WorkbenchSnapshot: Codable, Sendable {
  /// Bump this only together with a backwards-compatible decode migration.
  public static let currentFormatVersion = 12
  public static let maximumAIConversationsPerDraft =
    AIConversationRetentionPolicy.maximumConversationsPerDraft
  public static let maximumAIConversationCount =
    AIConversationRetentionPolicy.maximumConversationCount

  public var formatVersion: Int
  public var profiles: [SiteProfile]
  public var aiConnectionProfiles: [AIConnectionProfile]
  public var activeProfileID: UUID
  public var drafts: [ArticleDraft]
  public var softwareGuideSeedVersion: Int
  public var customMarkdownSnippets: [MarkdownSnippet]
  public var markdownEditorSessionStates: [UUID: MarkdownEditorSessionState]
  public var draftVersions: [DraftVersionSnapshot]
  public var recycledDrafts: [RecycledDraft]
  public var draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest]
  public var releaseRecords: [ReleaseRecord]
  public var maintenanceOperationRecords: [MaintenanceOperationRecord]
  public var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord]
  public var automationRunRecords: [WorkbenchAutomationRunRecord]
  public var aiChatCustomPrompts: [AIPublishingCustomPrompt]
  public var aiConversations: [AIConversation]
  public var activeAIConversationIDsByDraftID: [UUID: UUID]
  public var activeAIConversationIDsByScope: [String: UUID]
  public var seoSocialPreviewSnapshots: [SEOSocialPreviewSnapshot]
  public var privacySettings: PrivacyProtectionSettings
  public var privacyProtectionEvents: [PrivacyProtectionEvent]
  public var repositoryAutoSyncSettings: RepositoryAutoSyncSettings
  public var repositoryAutoSyncState: RepositoryAutoSyncState
  public var remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  public var deploymentPollingSettings: DeploymentPollingSettings
  public var deploymentPollingState: DeploymentPollingState
  public var deploymentStatusSnapshots: [DeploymentStatusSnapshot]
  public var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]

  public init(
    profiles: [SiteProfile],
    aiConnectionProfiles: [AIConnectionProfile] = [],
    activeProfileID: UUID,
    drafts: [ArticleDraft],
    softwareGuideSeedVersion: Int = 0,
    customMarkdownSnippets: [MarkdownSnippet] = [],
    markdownEditorSessionStates: [UUID: MarkdownEditorSessionState] = [:],
    draftVersions: [DraftVersionSnapshot] = [],
    recycledDrafts: [RecycledDraft] = [],
    draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest] = [],
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] = [],
    automationRunRecords: [WorkbenchAutomationRunRecord] = [],
    aiChatCustomPrompts: [AIPublishingCustomPrompt] = [],
    aiConversations: [AIConversation] = [],
    activeAIConversationIDsByDraftID: [UUID: UUID] = [:],
    activeAIConversationIDsByScope: [String: UUID] = [:],
    seoSocialPreviewSnapshots: [SEOSocialPreviewSnapshot] = [],
    privacySettings: PrivacyProtectionSettings = .default,
    privacyProtectionEvents: [PrivacyProtectionEvent] = [],
    repositoryAutoSyncSettings: RepositoryAutoSyncSettings = .default,
    repositoryAutoSyncState: RepositoryAutoSyncState = .idle,
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? = nil,
    deploymentPollingSettings: DeploymentPollingSettings = .default,
    deploymentPollingState: DeploymentPollingState = .idle,
    deploymentStatusSnapshots: [DeploymentStatusSnapshot] = [],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] = [:]
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.profiles = profiles
    self.aiConnectionProfiles = Array(aiConnectionProfiles.prefix(64))
    self.activeProfileID = activeProfileID
    self.drafts = drafts
    self.softwareGuideSeedVersion = max(0, softwareGuideSeedVersion)
    self.customMarkdownSnippets = Array(
      customMarkdownSnippets.prefix(MarkdownSnippetLibraryService.maximumCustomSnippetCount)
    )
    let limitedRecycledDrafts = Array(
      recycledDrafts.sorted { $0.deletedAt > $1.deletedAt }.prefix(
        DraftLifecycleService.maximumRecycledDrafts)
    )
    self.markdownEditorSessionStates = Self.validEditorSessionStates(
      markdownEditorSessionStates,
      drafts: drafts,
      recycledDrafts: limitedRecycledDrafts
    )
    self.draftVersions = Self.limitedDraftVersions(draftVersions)
    self.recycledDrafts = limitedRecycledDrafts
    self.draftRepositoryCleanupRequests = Array(
      draftRepositoryCleanupRequests
        .sorted { $0.requestedAt > $1.requestedAt }
        .prefix(DraftLifecycleService.maximumRepositoryCleanupRequests)
    )
    self.releaseRecords = ReleaseRecord.limitedHistory(releaseRecords)
    self.maintenanceOperationRecords = Self.limitedMaintenanceOperationRecords(
      maintenanceOperationRecords)
    self.aiMetadataApplicationRecords = Self.limitedMetadataApplicationRecords(
      aiMetadataApplicationRecords)
    self.automationRunRecords = Self.limitedAutomationRunRecords(automationRunRecords)
    self.aiChatCustomPrompts = Self.limitedCustomPrompts(aiChatCustomPrompts)
    let limitedAIConversations = Self.limitedAIConversations(
      aiConversations,
      drafts: drafts,
      recycledDrafts: limitedRecycledDrafts,
      preferredConversationIDs: Set(activeAIConversationIDsByDraftID.values)
        .union(activeAIConversationIDsByScope.values)
    )
    self.aiConversations = limitedAIConversations
    self.activeAIConversationIDsByDraftID = Self.validActiveAIConversationIDs(
      activeAIConversationIDsByDraftID,
      conversations: limitedAIConversations
    )
    self.activeAIConversationIDsByScope = Self.validActiveAIConversationIDsByScope(
      activeAIConversationIDsByScope,
      legacyDraftIDs: activeAIConversationIDsByDraftID,
      conversations: limitedAIConversations
    )
    self.seoSocialPreviewSnapshots = Self.latestSEOSocialPreviewSnapshots(seoSocialPreviewSnapshots)
    self.privacySettings = privacySettings
    self.privacyProtectionEvents = Self.limitedPrivacyProtectionEvents(privacyProtectionEvents)
    self.repositoryAutoSyncSettings = repositoryAutoSyncSettings
    self.repositoryAutoSyncState = repositoryAutoSyncState
    self.remoteRepositoryAccessCheck = remoteRepositoryAccessCheck
    self.deploymentPollingSettings = deploymentPollingSettings
    self.deploymentPollingState = deploymentPollingState
    self.deploymentStatusSnapshots = Self.limitedDeploymentStatusSnapshots(
      deploymentStatusSnapshots)
    self.deploymentStatusHistory = Self.limitedDeploymentStatusHistory(deploymentStatusHistory)
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case profiles
    case aiConnectionProfiles
    case activeProfileID
    case drafts
    case softwareGuideSeedVersion
    case customMarkdownSnippets
    case markdownEditorSessionStates
    case draftVersions
    case recycledDrafts
    case draftRepositoryCleanupRequests
    case releaseRecords
    case maintenanceOperationRecords
    case aiMetadataApplicationRecords
    case automationRunRecords
    case aiChatCustomPrompts
    case aiConversations
    case activeAIConversationIDsByDraftID
    case activeAIConversationIDsByScope
    case seoSocialPreviewSnapshots
    case privacySettings
    case privacyProtectionEvents
    case repositoryAutoSyncSettings
    case repositoryAutoSyncState
    case remoteRepositoryAccessCheck
    case deploymentPollingSettings
    case deploymentPollingState
    case deploymentStatusSnapshots
    case deploymentStatusHistory
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedFormatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
    guard (1...Self.currentFormatVersion).contains(storedFormatVersion) else {
      throw DecodingError.dataCorruptedError(
        forKey: .formatVersion,
        in: container,
        debugDescription: "不支持的工作台数据格式版本：\(storedFormatVersion)"
      )
    }

    // Version 1 had no explicit format marker. Optional fields migrate through
    // stable defaults; retired feature data is archived before the next save.
    formatVersion = Self.currentFormatVersion
    profiles = try container.decode([SiteProfile].self, forKey: .profiles)
    aiConnectionProfiles = Array(
      (try container.decodeIfPresent([AIConnectionProfile].self, forKey: .aiConnectionProfiles)
        ?? [])
        .prefix(64)
    )
    activeProfileID = try container.decode(UUID.self, forKey: .activeProfileID)
    drafts = try container.decode([ArticleDraft].self, forKey: .drafts)
    softwareGuideSeedVersion = max(
      0,
      try container.decodeIfPresent(Int.self, forKey: .softwareGuideSeedVersion) ?? 0
    )
    customMarkdownSnippets = Array(
      (try container.decodeIfPresent([MarkdownSnippet].self, forKey: .customMarkdownSnippets) ?? [])
        .prefix(MarkdownSnippetLibraryService.maximumCustomSnippetCount)
    )
    draftVersions = Self.limitedDraftVersions(
      try container.decodeIfPresent([DraftVersionSnapshot].self, forKey: .draftVersions) ?? []
    )
    recycledDrafts = Array(
      (try container.decodeIfPresent([RecycledDraft].self, forKey: .recycledDrafts) ?? [])
        .sorted { $0.deletedAt > $1.deletedAt }
        .prefix(DraftLifecycleService.maximumRecycledDrafts)
    )
    markdownEditorSessionStates = Self.validEditorSessionStates(
      try container.decodeIfPresent(
        [UUID: MarkdownEditorSessionState].self,
        forKey: .markdownEditorSessionStates
      ) ?? [:],
      drafts: drafts,
      recycledDrafts: recycledDrafts
    )
    draftRepositoryCleanupRequests = Array(
      (try container.decodeIfPresent(
        [DraftRepositoryCleanupRequest].self,
        forKey: .draftRepositoryCleanupRequests
      ) ?? [])
      .sorted { $0.requestedAt > $1.requestedAt }
      .prefix(DraftLifecycleService.maximumRepositoryCleanupRequests)
    )
    releaseRecords = ReleaseRecord.limitedHistory(
      try container.decode([ReleaseRecord].self, forKey: .releaseRecords)
    )
    maintenanceOperationRecords = Self.limitedMaintenanceOperationRecords(
      try container.decodeIfPresent(
        [MaintenanceOperationRecord].self,
        forKey: .maintenanceOperationRecords
      ) ?? []
    )
    aiMetadataApplicationRecords = Self.limitedMetadataApplicationRecords(
      try container.decodeIfPresent(
        [AIPublishingMetadataApplicationRecord].self,
        forKey: .aiMetadataApplicationRecords
      ) ?? []
    )
    automationRunRecords = Self.limitedAutomationRunRecords(
      try container.decodeIfPresent(
        [WorkbenchAutomationRunRecord].self,
        forKey: .automationRunRecords
      ) ?? []
    )
    aiChatCustomPrompts = Self.limitedCustomPrompts(
      try container.decodeIfPresent(
        [AIPublishingCustomPrompt].self,
        forKey: .aiChatCustomPrompts
      ) ?? []
    )
    let decodedActiveAIConversationIDs =
      try container.decodeIfPresent(
        [UUID: UUID].self,
        forKey: .activeAIConversationIDsByDraftID
      ) ?? [:]
    let decodedActiveAIConversationIDsByScope =
      try container.decodeIfPresent(
        [String: UUID].self,
        forKey: .activeAIConversationIDsByScope
      ) ?? [:]
    let decodedAIConversations = Self.limitedAIConversations(
      try container.decodeIfPresent(
        [AIConversation].self,
        forKey: .aiConversations
      ) ?? [],
      drafts: drafts,
      recycledDrafts: recycledDrafts,
      preferredConversationIDs: Set(decodedActiveAIConversationIDs.values)
        .union(decodedActiveAIConversationIDsByScope.values)
    )
    aiConversations = decodedAIConversations
    activeAIConversationIDsByDraftID = Self.validActiveAIConversationIDs(
      decodedActiveAIConversationIDs,
      conversations: decodedAIConversations
    )
    activeAIConversationIDsByScope = Self.validActiveAIConversationIDsByScope(
      decodedActiveAIConversationIDsByScope,
      legacyDraftIDs: decodedActiveAIConversationIDs,
      conversations: decodedAIConversations
    )
    seoSocialPreviewSnapshots = Self.latestSEOSocialPreviewSnapshots(
      try container.decodeIfPresent(
        [SEOSocialPreviewSnapshot].self,
        forKey: .seoSocialPreviewSnapshots
      ) ?? []
    )
    privacySettings =
      try container.decodeIfPresent(PrivacyProtectionSettings.self, forKey: .privacySettings)
      ?? .default
    privacyProtectionEvents = Self.limitedPrivacyProtectionEvents(
      try container.decodeIfPresent(
        [PrivacyProtectionEvent].self,
        forKey: .privacyProtectionEvents
      ) ?? []
    )
    repositoryAutoSyncSettings =
      try container.decodeIfPresent(
        RepositoryAutoSyncSettings.self,
        forKey: .repositoryAutoSyncSettings
      ) ?? .default
    repositoryAutoSyncState =
      try container.decodeIfPresent(
        RepositoryAutoSyncState.self,
        forKey: .repositoryAutoSyncState
      ) ?? .idle
    remoteRepositoryAccessCheck = try container.decodeIfPresent(
      RemoteRepositoryAccessCheck.self,
      forKey: .remoteRepositoryAccessCheck
    )
    deploymentPollingSettings =
      try container.decodeIfPresent(
        DeploymentPollingSettings.self,
        forKey: .deploymentPollingSettings
      ) ?? .default
    deploymentPollingState =
      try container.decodeIfPresent(
        DeploymentPollingState.self,
        forKey: .deploymentPollingState
      ) ?? .idle
    deploymentStatusSnapshots = Self.limitedDeploymentStatusSnapshots(
      try container.decodeIfPresent(
        [DeploymentStatusSnapshot].self,
        forKey: .deploymentStatusSnapshots
      ) ?? []
    )
    deploymentStatusHistory = Self.limitedDeploymentStatusHistory(
      try container.decodeIfPresent(
        [UUID: [DeploymentStatusSnapshot]].self,
        forKey: .deploymentStatusHistory
      ) ?? [:]
    )
  }

  private static func limitedMetadataApplicationRecords(
    _ records: [AIPublishingMetadataApplicationRecord]
  ) -> [AIPublishingMetadataApplicationRecord] {
    Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(120))
  }

  private static func limitedAutomationRunRecords(
    _ records: [WorkbenchAutomationRunRecord]
  ) -> [WorkbenchAutomationRunRecord] {
    Array(
      records
        .sorted { $0.completedAt > $1.completedAt }
        .prefix(WorkbenchAutomationRunRecord.maximumHistoryCount)
    )
  }

  private static func validEditorSessionStates(
    _ states: [UUID: MarkdownEditorSessionState],
    drafts: [ArticleDraft],
    recycledDrafts: [RecycledDraft]
  ) -> [UUID: MarkdownEditorSessionState] {
    let validDraftIDs = Set(drafts.map(\.id) + recycledDrafts.map(\.id))
    return states.filter { validDraftIDs.contains($0.key) }
  }

  private static func limitedDraftVersions(
    _ versions: [DraftVersionSnapshot]
  ) -> [DraftVersionSnapshot] {
    let grouped = Dictionary(grouping: versions, by: \.draftID)
    return Array(
      grouped.values
        .flatMap { entries in
          entries.sorted { $0.capturedAt > $1.capturedAt }
            .prefix(DraftLifecycleService.maximumVersionsPerDraft)
        }
        .sorted { $0.capturedAt > $1.capturedAt }
        .prefix(DraftLifecycleService.maximumTotalVersions)
    )
  }

  private static func limitedMaintenanceOperationRecords(
    _ records: [MaintenanceOperationRecord]
  ) -> [MaintenanceOperationRecord] {
    Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(120))
  }

  private static func limitedCustomPrompts(
    _ prompts: [AIPublishingCustomPrompt]
  ) -> [AIPublishingCustomPrompt] {
    Array(
      prompts
        .filter { !$0.prompt.trimmedForPublishing.isEmpty }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(80)
    )
  }

  private static func limitedAIConversations(
    _ conversations: [AIConversation],
    drafts: [ArticleDraft],
    recycledDrafts: [RecycledDraft],
    preferredConversationIDs: Set<UUID>
  ) -> [AIConversation] {
    let validDraftIDs = Set(drafts.map(\.id) + recycledDrafts.map(\.id))
    let pendingAgentConversationIDs = Set(
      conversations.compactMap { conversation in
        conversation.messages.contains(where: { message in
          message.agentContinuation?.phase.requiresExplicitDisposition == true
        }) ? conversation.id : nil
      }
    )
    return AIConversationRetentionPolicy.limited(
      conversations,
      validDraftIDs: validDraftIDs,
      preserving: preferredConversationIDs.union(pendingAgentConversationIDs)
    )
  }

  private static func validActiveAIConversationIDs(
    _ activeIDs: [UUID: UUID],
    conversations: [AIConversation]
  ) -> [UUID: UUID] {
    AIConversationRetentionPolicy.validActiveConversationIDs(
      activeIDs,
      conversations: conversations
    )
  }

  private static func validActiveAIConversationIDsByScope(
    _ activeIDs: [String: UUID],
    legacyDraftIDs: [UUID: UUID],
    conversations: [AIConversation]
  ) -> [String: UUID] {
    var migrated = activeIDs
    for (draftID, conversationID) in legacyDraftIDs {
      let key = AIConversationScope.draft(draftID).storageKey
      migrated[key] = migrated[key] ?? conversationID
    }
    return AIConversationRetentionPolicy.validActiveConversationIDsByScope(
      migrated,
      conversations: conversations
    )
  }

  private static func limitedPrivacyProtectionEvents(
    _ events: [PrivacyProtectionEvent]
  ) -> [PrivacyProtectionEvent] {
    Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(50))
  }

  private static func latestSEOSocialPreviewSnapshots(
    _ snapshots: [SEOSocialPreviewSnapshot]
  ) -> [SEOSocialPreviewSnapshot] {
    Dictionary(
      snapshots.map { ($0.draftID, $0) },
      uniquingKeysWith: { current, candidate in
        candidate.generatedAt > current.generatedAt ? candidate : current
      }
    )
    .values
    .sorted { $0.generatedAt > $1.generatedAt }
  }

  private static func limitedDeploymentStatusSnapshots(
    _ snapshots: [DeploymentStatusSnapshot]
  ) -> [DeploymentStatusSnapshot] {
    var seenReleaseRecordIDs: Set<UUID> = []
    let uniqueSnapshots =
      snapshots
      .sorted { $0.checkedAt > $1.checkedAt }
      .filter { snapshot in
        guard let releaseRecordID = snapshot.releaseRecordID else { return true }
        return seenReleaseRecordIDs.insert(releaseRecordID).inserted
      }
    return Array(uniqueSnapshots.prefix(300))
  }

  private static func limitedDeploymentStatusHistory(
    _ history: [UUID: [DeploymentStatusSnapshot]]
  ) -> [UUID: [DeploymentStatusSnapshot]] {
    Dictionary(
      uniqueKeysWithValues: history.map { recordID, snapshots in
        (recordID, Array(snapshots.sorted { $0.checkedAt > $1.checkedAt }.prefix(6)))
      })
  }
}

public struct WorkbenchSnapshotLoadResult: Sendable {
  public var snapshot: WorkbenchSnapshot?
  public var recoveryMessage: String?

  public init(snapshot: WorkbenchSnapshot?, recoveryMessage: String? = nil) {
    self.snapshot = snapshot
    self.recoveryMessage = recoveryMessage
  }
}
