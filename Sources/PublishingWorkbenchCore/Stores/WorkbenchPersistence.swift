import CryptoKit
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
    return AIConversationRetentionPolicy.limited(
      conversations,
      validDraftIDs: validDraftIDs,
      preserving: preferredConversationIDs
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

/// Selects how a ``WorkbenchStore`` obtains its initial persisted state.
///
/// The macOS app preloads snapshots on a utility task so JSON and file I/O do
/// not block the first window. Tests and direct library clients keep the
/// synchronous default for source compatibility.
public enum WorkbenchInitialSnapshotSource: Sendable {
  case persistence
  case preloaded(WorkbenchSnapshotLoadResult)
  case loadFailure(String)
}

public enum WorkbenchPersistenceSaveResult: Sendable, Equatable {
  case saved
  case savedWithoutBackup(String)
}

/// A fully encoded snapshot that is ready for the short, atomic disk commit.
/// Construct and commit this off the main actor. The persistence store checks
/// revisions before and after its serialized commit so newer editor state is
/// never marked as saved by an older snapshot.
public struct WorkbenchPreparedPersistenceSave: Sendable {
  fileprivate let data: Data
  fileprivate let retiredFeatureArchives: [WorkbenchRetiredFeatureArchive]
}

private struct WorkbenchRetiredFeatureArchive: Sendable {
  var fileName: String
  var data: Data
}

public enum WorkbenchPersistenceError: LocalizedError, Sendable {
  case unrecoverableSnapshot(primary: String, backup: String?)
  case retiredFeatureArchiveConflict(String)
  case recoveryFilesUnavailable
  case invalidRecoverySnapshot(String)
  case recoveryArchiveCleanupFailed(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .unrecoverableSnapshot:
      return "工作台数据无法读取，原始文件未被覆盖。"
    case .retiredFeatureArchiveConflict(let fileName):
      return "退役功能数据归档冲突：\(fileName)。原始文件未被覆盖。"
    case .recoveryFilesUnavailable:
      return "没有可归档或导出的工作台故障文件。"
    case .invalidRecoverySnapshot(let message):
      return "所选恢复文件不是有效的工作台快照：\(message)"
    case .recoveryArchiveCleanupFailed(let path, let reason):
      return "归档工作台故障文件失败：\(reason)。临时归档目录保留在 \(path)。"
    }
  }
}

public struct WorkbenchPersistence: Sendable {
  public var fileURL: URL

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let supportURL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      self.fileURL =
        supportURL
        .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
        .appendingPathComponent("workbench.json")
    }
  }

  public func load() throws -> WorkbenchSnapshot? {
    try loadWithRecovery().snapshot
  }

  public func loadWithRecovery() throws -> WorkbenchSnapshotLoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      guard FileManager.default.fileExists(atPath: lastKnownGoodURL.path) else {
        return WorkbenchSnapshotLoadResult(snapshot: nil)
      }

      do {
        let snapshot = try decodeValidatedSnapshot(at: lastKnownGoodURL)
        return WorkbenchSnapshotLoadResult(
          snapshot: snapshot,
          recoveryMessage: "工作台数据文件缺失，已从上次有效备份恢复。"
        )
      } catch {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(
          primary: "主工作台数据文件不存在。",
          backup: error.localizedDescription
        )
      }
    }

    do {
      return WorkbenchSnapshotLoadResult(snapshot: try decodeValidatedSnapshot(at: fileURL))
    } catch {
      let primaryError = error.localizedDescription
      guard FileManager.default.fileExists(atPath: lastKnownGoodURL.path) else {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(primary: primaryError, backup: nil)
      }

      do {
        let snapshot = try decodeValidatedSnapshot(at: lastKnownGoodURL)
        return WorkbenchSnapshotLoadResult(
          snapshot: snapshot,
          recoveryMessage: "工作台数据文件损坏，已从上次有效备份恢复。原始文件保留在原处。"
        )
      } catch {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(
          primary: primaryError,
          backup: error.localizedDescription
        )
      }
    }
  }

  public func prepareSave(
    _ snapshot: WorkbenchSnapshot,
    reclaimUnreferencedAttachments _: Bool = true
  ) throws -> WorkbenchPreparedPersistenceSave {
    return WorkbenchPreparedPersistenceSave(
      data: try JSONEncoder.workbench.encode(snapshot),
      retiredFeatureArchives: try retiredFeatureArchivesFromPersistedSnapshots()
    )
  }

  public func commit(_ preparedSave: WorkbenchPreparedPersistenceSave) throws
    -> WorkbenchPersistenceSaveResult
  {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = preparedSave.data
    try validateSnapshotData(data)

    let previousPrimaryExisted = fileManager.fileExists(atPath: fileURL.path)
    let previousPrimaryData: Data?
    let previousPrimaryWarning: String?
    if previousPrimaryExisted {
      do {
        let previousData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try validateSnapshotData(previousData)
        previousPrimaryData = previousData
        previousPrimaryWarning = nil
      } catch {
        previousPrimaryData = nil
        previousPrimaryWarning = "保存前的主快照无法验证：\(error.localizedDescription)"
      }
    } else {
      previousPrimaryData = nil
      previousPrimaryWarning = nil
    }

    try persistRetiredFeatureArchives(preparedSave.retiredFeatureArchives)
    try data.write(to: fileURL, options: [.atomic])

    do {
      if let previousPrimaryData {
        try previousPrimaryData.write(to: lastKnownGoodURL, options: [.atomic])
      } else if !previousPrimaryExisted
        || !fileManager.fileExists(atPath: lastKnownGoodURL.path)
      {
        try data.write(to: lastKnownGoodURL, options: [.atomic])
      }
      if let previousPrimaryWarning {
        return .savedWithoutBackup(
          "\(previousPrimaryWarning)；新主快照已保存，已有恢复点未被覆盖。"
        )
      }
      return .saved
    } catch {
      // The primary write succeeded. Surface the degraded recovery guarantee
      // instead of incorrectly reporting an unsaved document.
      return .savedWithoutBackup(error.localizedDescription)
    }
  }

  private func decodeValidatedSnapshot(at url: URL) throws -> WorkbenchSnapshot {
    let data = try BoundedFileReader.data(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
    )
    return try decodeValidatedSnapshot(from: data)
  }

  @discardableResult
  private func decodeValidatedSnapshot(from data: Data) throws -> WorkbenchSnapshot {
    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
    try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    return snapshot
  }

  private func validateSnapshotData(_ data: Data) throws {
    try decodeValidatedSnapshot(from: data)
  }

  public func save(_ snapshot: WorkbenchSnapshot) throws -> WorkbenchPersistenceSaveResult {
    try commit(prepareSave(snapshot))
  }

  public var lastKnownGoodURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("last-known-good.json")
  }

  /// A small independent journal for editor buffers that have not reached the
  /// main workbench snapshot yet. It is intentionally separate so a damaged
  /// snapshot cannot also erase the latest unsaved writing buffer.
  public var draftRecoveryJournalURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("draft-recovery.json")
  }

  public var recoveryArchiveDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("RecoveryArchives", isDirectory: true)
  }

  /// Copies the current primary and last-known-good files into a user-selected
  /// directory without mutating either source file.
  @discardableResult
  public func exportRecoveryFiles(to directoryURL: URL) throws -> URL {
    let didStartAccessing = directoryURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        directoryURL.stopAccessingSecurityScopedResource()
      }
    }
    return try archiveRecoveryFiles(
      in: directoryURL,
      folderPrefix: "PersonalSitePublisher-Recovery"
    )
  }

  /// Validates a chosen snapshot before archiving the unreadable files and
  /// replacing both persistence copies. The live store should restart before it
  /// uses this file so no state from the temporary blank workbench is merged in.
  @discardableResult
  public func installRecoverySnapshot(from sourceURL: URL) throws -> URL {
    try installRecoverySnapshot(
      from: sourceURL,
      fileOperations: WorkbenchRecoveryFileOperations(
        writeAtomically: { data, destinationURL in
          try data.write(to: destinationURL, options: .atomic)
        },
        archiveExistingSnapshots: {
          try archiveUnrecoverableSnapshotFiles()
        }
      )
    )
  }

  @discardableResult
  func installRecoverySnapshot(
    from sourceURL: URL,
    fileOperations: WorkbenchRecoveryFileOperations
  ) throws -> URL {
    let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let data: Data
    do {
      data = try BoundedFileReader.data(
        at: sourceURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
      )
    } catch {
      throw WorkbenchPersistenceError.invalidRecoverySnapshot(error.localizedDescription)
    }
    do {
      try validateSnapshotData(data)
    } catch {
      throw WorkbenchPersistenceError.invalidRecoverySnapshot(error.localizedDescription)
    }

    let fileManager = FileManager.default
    let parentDirectoryURL = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parentDirectoryURL,
      withIntermediateDirectories: true
    )

    let stagingDirectoryURL = parentDirectoryURL.appendingPathComponent(
      ".workbench-recovery-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: stagingDirectoryURL,
      withIntermediateDirectories: false
    )
    defer {
      try? fileManager.removeItem(at: stagingDirectoryURL)
    }

    let stagedPrimaryURL = stagingDirectoryURL.appendingPathComponent(fileURL.lastPathComponent)
    let stagedLastKnownGoodURL = stagingDirectoryURL.appendingPathComponent(
      lastKnownGoodURL.lastPathComponent
    )
    do {
      try fileOperations.writeAtomically(data, stagedPrimaryURL)
      try fileOperations.writeAtomically(data, stagedLastKnownGoodURL)
      try validateStagedRecoverySnapshot(at: stagedPrimaryURL, expectedData: data)
      try validateStagedRecoverySnapshot(at: stagedLastKnownGoodURL, expectedData: data)
    } catch let error as WorkbenchRecoveryTransactionError {
      throw error
    } catch {
      throw WorkbenchRecoveryTransactionError.stagingFailed(error.localizedDescription)
    }

    let archiveURL: URL
    do {
      archiveURL = try fileOperations.archiveExistingSnapshots()
    } catch {
      throw WorkbenchRecoveryTransactionError.archiveFailed(error.localizedDescription)
    }
    do {
      try fileOperations.writeAtomically(data, lastKnownGoodURL)
    } catch {
      throw WorkbenchRecoveryTransactionError.backupInstallFailed(error.localizedDescription)
    }
    do {
      try fileOperations.writeAtomically(data, fileURL)
    } catch {
      throw WorkbenchRecoveryTransactionError.primaryInstallFailed(error.localizedDescription)
    }
    return archiveURL
  }

  private func validateStagedRecoverySnapshot(at url: URL, expectedData: Data) throws {
    let stagedData = try BoundedFileReader.data(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
    )
    guard stagedData == expectedData else {
      throw WorkbenchRecoveryTransactionError.stagedDataMismatch(url.lastPathComponent)
    }
    try validateSnapshotData(stagedData)
  }

  /// Preserves both unreadable persistence copies before an explicit reset.
  @discardableResult
  public func archiveUnrecoverableSnapshotFiles() throws -> URL {
    try archiveRecoveryFiles(
      in: recoveryArchiveDirectoryURL,
      folderPrefix: "UnrecoverableWorkbench"
    )
  }

  public var retiredFeatureArchiveDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("RetiredFeatureArchives", isDirectory: true)
  }

  public var imageOptimizationDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("OptimizedImages", isDirectory: true)
  }

  /// Removes successful batch folders that are no longer referenced by any
  /// attachment. Non-batch files are deliberately left untouched.
  @discardableResult
  func pruneUnreferencedImageOptimizationBatches(
    referencedSourceFilePaths: [String]
  ) -> Int {
    let fileManager = FileManager.default
    let rootURL = imageOptimizationDirectoryURL.standardizedFileURL
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
    else {
      return 0
    }

    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let referencedBatchNames = Set(
      referencedSourceFilePaths.compactMap { path -> String? in
        let sourcePath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(sourcePath.dropFirst(rootPrefix.count))
        guard let firstComponent = relativePath.split(separator: "/").first else { return nil }
        let name = String(firstComponent)
        return name.hasPrefix(".image-batch-") ? name : nil
      })

    var removedCount = 0
    for child in children where child.lastPathComponent.hasPrefix(".image-batch-") {
      let standardizedChild = child.standardizedFileURL
      guard standardizedChild.deletingLastPathComponent() == rootURL,
        !referencedBatchNames.contains(standardizedChild.lastPathComponent)
      else {
        continue
      }
      do {
        try fileManager.removeItem(at: standardizedChild)
        removedCount += 1
      } catch {
        continue
      }
    }
    return removedCount
  }

  private func archiveRecoveryFiles(in parentDirectoryURL: URL, folderPrefix: String) throws -> URL
  {
    let fileManager = FileManager.default
    let sourceURLs = [fileURL, lastKnownGoodURL].filter { fileManager.fileExists(atPath: $0.path) }
    guard !sourceURLs.isEmpty else {
      throw WorkbenchPersistenceError.recoveryFilesUnavailable
    }

    try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
    let archiveURL = parentDirectoryURL.appendingPathComponent(
      "\(folderPrefix)-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: archiveURL, withIntermediateDirectories: false)
    do {
      for sourceURL in sourceURLs {
        try fileManager.copyItem(
          at: sourceURL,
          to: archiveURL.appendingPathComponent(sourceURL.lastPathComponent)
        )
      }
    } catch {
      do {
        try fileManager.removeItem(at: archiveURL)
      } catch let cleanupError {
        throw WorkbenchPersistenceError.recoveryArchiveCleanupFailed(
          path: archiveURL.path,
          reason: "复制失败：\(error.localizedDescription)；清理失败：\(cleanupError.localizedDescription)"
        )
      }
      throw error
    }
    return archiveURL
  }

  private func retiredFeatureArchivesFromPersistedSnapshots() throws
    -> [WorkbenchRetiredFeatureArchive]
  {
    let sourceURLs = [fileURL, lastKnownGoodURL]
    var archivesByFileName: [String: WorkbenchRetiredFeatureArchive] = [:]

    for sourceURL in sourceURLs where FileManager.default.fileExists(atPath: sourceURL.path) {
      let sourceData = try Data(contentsOf: sourceURL)
      guard let archive = retiredFeatureArchive(from: sourceData) else { continue }
      archivesByFileName[archive.fileName] = archive
    }

    return archivesByFileName.values.sorted { $0.fileName < $1.fileName }
  }

  private func retiredFeatureArchive(from sourceData: Data) -> WorkbenchRetiredFeatureArchive? {
    guard var source = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
      return nil
    }

    let retiredKeys = [
      "contentPerformanceSnapshots",
      "externalVerificationEvidenceRecords",
      "scheduledPublishJobs",
    ]
    let retiredFields = Dictionary(
      uniqueKeysWithValues: retiredKeys.compactMap { key -> (String, Any)? in
        guard let value = source.removeValue(forKey: key), retiredFieldContainsData(value) else {
          return nil
        }
        return (key, value)
      })
    guard !retiredFields.isEmpty else { return nil }

    let sourceFormatVersion = source["formatVersion"] as? Int ?? 1
    let archiveObject: [String: Any] = [
      "archiveFormatVersion": 1,
      "sourceFormatVersion": sourceFormatVersion,
      "retiredFields": retiredFields,
    ]
    guard
      let archiveData = try? JSONSerialization.data(
        withJSONObject: archiveObject,
        options: [.prettyPrinted, .sortedKeys]
      )
    else {
      return nil
    }
    let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
    return WorkbenchRetiredFeatureArchive(
      fileName: "workbench-v\(sourceFormatVersion)-\(digest).json",
      data: archiveData
    )
  }

  private func retiredFieldContainsData(_ value: Any) -> Bool {
    if let array = value as? [Any] {
      return !array.isEmpty
    }
    if let dictionary = value as? [String: Any] {
      return !dictionary.isEmpty
    }
    return !(value is NSNull)
  }

  private func persistRetiredFeatureArchives(_ archives: [WorkbenchRetiredFeatureArchive]) throws {
    guard !archives.isEmpty else { return }
    try FileManager.default.createDirectory(
      at: retiredFeatureArchiveDirectoryURL,
      withIntermediateDirectories: true
    )

    for archive in archives {
      let archiveURL = retiredFeatureArchiveDirectoryURL.appendingPathComponent(archive.fileName)
      if FileManager.default.fileExists(atPath: archiveURL.path) {
        guard try Data(contentsOf: archiveURL) == archive.data else {
          throw WorkbenchPersistenceError.retiredFeatureArchiveConflict(archive.fileName)
        }
        continue
      }
      let temporaryURL = retiredFeatureArchiveDirectoryURL.appendingPathComponent(
        ".\(archive.fileName).\(UUID().uuidString).tmp"
      )
      do {
        try archive.data.write(to: temporaryURL, options: .atomic)
        do {
          try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
        } catch {
          if FileManager.default.fileExists(atPath: archiveURL.path),
            try Data(contentsOf: archiveURL) == archive.data
          {
            try? FileManager.default.removeItem(at: temporaryURL)
            continue
          }
          throw error
        }
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    }
  }
}

/// A frozen, value-semantic copy of the store state used by persistence.
///
/// Capturing this on MainActor is intentionally limited to COW array/dictionary
/// reads. `WorkbenchSnapshot` construction (including retention, sorting and
/// validation) happens after the value crosses to the persistence worker.
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
