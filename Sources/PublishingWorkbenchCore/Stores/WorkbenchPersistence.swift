import Foundation

public struct WorkbenchSnapshot: Codable, Sendable {
  /// Bump this only together with a backwards-compatible decode migration.
  public static let currentFormatVersion = 2

  public var formatVersion: Int
  public var profiles: [SiteProfile]
  public var activeProfileID: UUID
  public var drafts: [ArticleDraft]
  public var releaseRecords: [ReleaseRecord]
  public var maintenanceOperationRecords: [MaintenanceOperationRecord]
  public var contentPerformanceSnapshots: [ContentPerformanceSnapshot]
  public var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord]
  public var aiChatSessionsByDraftID: [UUID: AIPublishingChatSessionState]
  public var aiChatCustomPrompts: [AIPublishingCustomPrompt]
  public var seoSocialPreviewSnapshots: [SEOSocialPreviewSnapshot]
  public var privacySettings: PrivacyProtectionSettings
  public var privacyProtectionEvents: [PrivacyProtectionEvent]
  public var monetizationState: MonetizationState
  public var repositoryAutoSyncSettings: RepositoryAutoSyncSettings
  public var repositoryAutoSyncState: RepositoryAutoSyncState
  public var remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  public var deploymentPollingSettings: DeploymentPollingSettings
  public var deploymentPollingState: DeploymentPollingState
  public var deploymentStatusSnapshots: [DeploymentStatusSnapshot]
  public var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]
  public var externalVerificationEvidenceRecords: [ReleaseExternalVerificationEvidenceRecord]

  public init(
    profiles: [SiteProfile],
    activeProfileID: UUID,
    drafts: [ArticleDraft],
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    contentPerformanceSnapshots: [ContentPerformanceSnapshot] = [],
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] = [],
    aiChatSessionsByDraftID: [UUID: AIPublishingChatSessionState] = [:],
    aiChatCustomPrompts: [AIPublishingCustomPrompt] = [],
    seoSocialPreviewSnapshots: [SEOSocialPreviewSnapshot] = [],
    privacySettings: PrivacyProtectionSettings = .default,
    privacyProtectionEvents: [PrivacyProtectionEvent] = [],
    monetizationState: MonetizationState = .default,
    repositoryAutoSyncSettings: RepositoryAutoSyncSettings = .default,
    repositoryAutoSyncState: RepositoryAutoSyncState = .idle,
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? = nil,
    deploymentPollingSettings: DeploymentPollingSettings = .default,
    deploymentPollingState: DeploymentPollingState = .idle,
    deploymentStatusSnapshots: [DeploymentStatusSnapshot] = [],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] = [:],
    externalVerificationEvidenceRecords: [ReleaseExternalVerificationEvidenceRecord] = []
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.profiles = profiles
    self.activeProfileID = activeProfileID
    self.drafts = drafts
    self.releaseRecords = releaseRecords
    self.maintenanceOperationRecords = Self.limitedMaintenanceOperationRecords(maintenanceOperationRecords)
    self.contentPerformanceSnapshots = Self.limitedContentPerformanceSnapshots(contentPerformanceSnapshots)
    self.aiMetadataApplicationRecords = Self.limitedMetadataApplicationRecords(aiMetadataApplicationRecords)
    self.aiChatSessionsByDraftID = aiChatSessionsByDraftID
    self.aiChatCustomPrompts = Self.limitedCustomPrompts(aiChatCustomPrompts)
    self.seoSocialPreviewSnapshots = seoSocialPreviewSnapshots
    self.privacySettings = privacySettings
    self.privacyProtectionEvents = Self.limitedPrivacyProtectionEvents(privacyProtectionEvents)
    self.monetizationState = monetizationState
    self.repositoryAutoSyncSettings = repositoryAutoSyncSettings
    self.repositoryAutoSyncState = repositoryAutoSyncState
    self.remoteRepositoryAccessCheck = remoteRepositoryAccessCheck
    self.deploymentPollingSettings = deploymentPollingSettings
    self.deploymentPollingState = deploymentPollingState
    self.deploymentStatusSnapshots = Self.limitedDeploymentStatusSnapshots(deploymentStatusSnapshots)
    self.deploymentStatusHistory = Self.limitedDeploymentStatusHistory(deploymentStatusHistory)
    self.externalVerificationEvidenceRecords = Self.limitedExternalVerificationEvidenceRecords(
      externalVerificationEvidenceRecords
    )
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case profiles
    case activeProfileID
    case drafts
    case releaseRecords
    case maintenanceOperationRecords
    case contentPerformanceSnapshots
    case aiMetadataApplicationRecords
    case aiChatSessionsByDraftID
    case aiChatCustomPrompts
    case seoSocialPreviewSnapshots
    case privacySettings
    case privacyProtectionEvents
    case monetizationState
    case repositoryAutoSyncSettings
    case repositoryAutoSyncState
    case remoteRepositoryAccessCheck
    case deploymentPollingSettings
    case deploymentPollingState
    case deploymentStatusSnapshots
    case deploymentStatusHistory
    case externalVerificationEvidenceRecords
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

    // Version 1 had no explicit format marker. Its optional fields are migrated
    // below through stable defaults; all newly persisted snapshots use v2.
    formatVersion = Self.currentFormatVersion
    profiles = try container.decode([SiteProfile].self, forKey: .profiles)
    activeProfileID = try container.decode(UUID.self, forKey: .activeProfileID)
    drafts = try container.decode([ArticleDraft].self, forKey: .drafts)
    releaseRecords = try container.decode([ReleaseRecord].self, forKey: .releaseRecords)
    maintenanceOperationRecords = Self.limitedMaintenanceOperationRecords(
      try container.decodeIfPresent(
        [MaintenanceOperationRecord].self,
        forKey: .maintenanceOperationRecords
      ) ?? []
    )
    contentPerformanceSnapshots = Self.limitedContentPerformanceSnapshots(
      try container.decodeIfPresent(
        [ContentPerformanceSnapshot].self,
        forKey: .contentPerformanceSnapshots
      ) ?? []
    )
    aiMetadataApplicationRecords = Self.limitedMetadataApplicationRecords(
      try container.decodeIfPresent(
        [AIPublishingMetadataApplicationRecord].self,
        forKey: .aiMetadataApplicationRecords
      ) ?? []
    )
    aiChatSessionsByDraftID = try container.decodeIfPresent(
      [UUID: AIPublishingChatSessionState].self,
      forKey: .aiChatSessionsByDraftID
    ) ?? [:]
    aiChatCustomPrompts = Self.limitedCustomPrompts(
      try container.decodeIfPresent(
        [AIPublishingCustomPrompt].self,
        forKey: .aiChatCustomPrompts
      ) ?? []
    )
    seoSocialPreviewSnapshots = try container.decodeIfPresent(
      [SEOSocialPreviewSnapshot].self,
      forKey: .seoSocialPreviewSnapshots
    ) ?? []
    privacySettings = try container.decodeIfPresent(PrivacyProtectionSettings.self, forKey: .privacySettings) ?? .default
    privacyProtectionEvents = Self.limitedPrivacyProtectionEvents(
      try container.decodeIfPresent(
        [PrivacyProtectionEvent].self,
        forKey: .privacyProtectionEvents
      ) ?? []
    )
    monetizationState = try container.decodeIfPresent(MonetizationState.self, forKey: .monetizationState) ?? .default
    repositoryAutoSyncSettings = try container.decodeIfPresent(
      RepositoryAutoSyncSettings.self,
      forKey: .repositoryAutoSyncSettings
    ) ?? .default
    repositoryAutoSyncState = try container.decodeIfPresent(
      RepositoryAutoSyncState.self,
      forKey: .repositoryAutoSyncState
    ) ?? .idle
    remoteRepositoryAccessCheck = try container.decodeIfPresent(
      RemoteRepositoryAccessCheck.self,
      forKey: .remoteRepositoryAccessCheck
    )
    deploymentPollingSettings = try container.decodeIfPresent(
      DeploymentPollingSettings.self,
      forKey: .deploymentPollingSettings
    ) ?? .default
    deploymentPollingState = try container.decodeIfPresent(
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
    externalVerificationEvidenceRecords = Self.limitedExternalVerificationEvidenceRecords(
      try container.decodeIfPresent(
        [ReleaseExternalVerificationEvidenceRecord].self,
        forKey: .externalVerificationEvidenceRecords
      ) ?? []
    )
  }

  private static func limitedMetadataApplicationRecords(
    _ records: [AIPublishingMetadataApplicationRecord]
  ) -> [AIPublishingMetadataApplicationRecord] {
    Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(120))
  }

  private static func limitedMaintenanceOperationRecords(
    _ records: [MaintenanceOperationRecord]
  ) -> [MaintenanceOperationRecord] {
    Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(120))
  }

  private static func limitedContentPerformanceSnapshots(
    _ snapshots: [ContentPerformanceSnapshot]
  ) -> [ContentPerformanceSnapshot] {
    Array(snapshots.sorted { $0.capturedAt > $1.capturedAt }.prefix(500))
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

  private static func limitedExternalVerificationEvidenceRecords(
    _ records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> [ReleaseExternalVerificationEvidenceRecord] {
    Array(records.sorted { $0.recordedAt > $1.recordedAt }.prefix(120))
  }

  private static func limitedPrivacyProtectionEvents(
    _ events: [PrivacyProtectionEvent]
  ) -> [PrivacyProtectionEvent] {
    Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(50))
  }

  private static func limitedDeploymentStatusSnapshots(
    _ snapshots: [DeploymentStatusSnapshot]
  ) -> [DeploymentStatusSnapshot] {
    Array(snapshots.sorted { $0.checkedAt > $1.checkedAt }.prefix(300))
  }

  private static func limitedDeploymentStatusHistory(
    _ history: [UUID: [DeploymentStatusSnapshot]]
  ) -> [UUID: [DeploymentStatusSnapshot]] {
    Dictionary(uniqueKeysWithValues: history.map { recordID, snapshots in
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

public enum WorkbenchPersistenceSaveResult: Sendable, Equatable {
  case saved
  case savedWithoutBackup(String)
}

/// A fully encoded snapshot that is ready for the short, atomic disk commit.
/// Construct this off the main actor; commit it on the main actor after checking
/// that no newer editor state superseded it.
public struct WorkbenchPreparedPersistenceSave: Sendable {
  fileprivate let data: Data
}

public enum WorkbenchPersistenceError: LocalizedError, Sendable {
  case unrecoverableSnapshot(primary: String, backup: String?)

  public var errorDescription: String? {
    "工作台数据无法读取，原始文件未被覆盖。"
  }
}

public struct WorkbenchPersistence: Sendable {
  public var fileURL: URL

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      self.fileURL = supportURL
        .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
        .appendingPathComponent("workbench.json")
    }
  }

  public func load() throws -> WorkbenchSnapshot? {
    try loadWithRecovery().snapshot
  }

  public func loadWithRecovery() throws -> WorkbenchSnapshotLoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return WorkbenchSnapshotLoadResult(snapshot: nil)
    }

    do {
      let data = try Data(contentsOf: fileURL)
      return WorkbenchSnapshotLoadResult(snapshot: try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data))
    } catch {
      let primaryError = error.localizedDescription
      guard FileManager.default.fileExists(atPath: lastKnownGoodURL.path) else {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(primary: primaryError, backup: nil)
      }

      do {
        let backupData = try Data(contentsOf: lastKnownGoodURL)
        let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: backupData)
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
    reclaimUnreferencedAttachments: Bool = true
  ) throws -> WorkbenchPreparedPersistenceSave {
    var persistedSnapshot = snapshot
    persistedSnapshot.aiChatSessionsByDraftID = try persistedAIChatSessions(
      snapshot.aiChatSessionsByDraftID,
      reclaimUnreferencedFiles: reclaimUnreferencedAttachments
    )
    return WorkbenchPreparedPersistenceSave(data: try JSONEncoder.workbench.encode(persistedSnapshot))
  }

  public func commit(_ preparedSave: WorkbenchPreparedPersistenceSave) throws -> WorkbenchPersistenceSaveResult {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = preparedSave.data
    try data.write(to: fileURL, options: [.atomic])

    do {
      try data.write(to: lastKnownGoodURL, options: [.atomic])
      return .saved
    } catch {
      // The primary write succeeded. Surface the degraded recovery guarantee
      // instead of incorrectly reporting an unsaved document.
      return .savedWithoutBackup(error.localizedDescription)
    }
  }

  public func save(_ snapshot: WorkbenchSnapshot) throws -> WorkbenchPersistenceSaveResult {
    try commit(prepareSave(snapshot))
  }

  public var lastKnownGoodURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("last-known-good.json")
  }

  public var imageOptimizationDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("OptimizedImages", isDirectory: true)
  }

  var aiChatAttachmentDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("AIChatAttachments", isDirectory: true)
  }

  func persistedAIChatSessions(
    _ sessions: [UUID: AIPublishingChatSessionState],
    reclaimUnreferencedFiles: Bool = true
  ) throws -> [UUID: AIPublishingChatSessionState] {
    try AIChatAttachmentStore(directoryURL: aiChatAttachmentDirectoryURL).persistedSessions(
      sessions,
      shouldReclaimUnreferencedFiles: reclaimUnreferencedFiles
    )
  }

  func hydratedAIChatSessions(
    _ sessions: [UUID: AIPublishingChatSessionState]
  ) -> [UUID: AIPublishingChatSessionState] {
    AIChatAttachmentStore(directoryURL: aiChatAttachmentDirectoryURL).hydratedSessions(sessions)
  }
}

@MainActor
extension WorkbenchPersistence {
  func snapshot(from store: WorkbenchStore) -> WorkbenchSnapshot {
    WorkbenchSnapshot(
      profiles: store.profiles,
      activeProfileID: store.activeProfileID,
      drafts: store.drafts,
      releaseRecords: store.releaseRecords,
      maintenanceOperationRecords: store.maintenanceOperationRecords,
      contentPerformanceSnapshots: store.contentPerformanceSnapshots,
      aiMetadataApplicationRecords: store.aiMetadataApplicationRecords,
      aiChatSessionsByDraftID: store.aiChatSessionsForPersistence(),
      aiChatCustomPrompts: store.aiChatCustomPrompts,
      seoSocialPreviewSnapshots: Array(store.seoSocialPreviewSnapshots.values),
      privacySettings: store.privacySettings,
      privacyProtectionEvents: store.privacyProtectionEvents,
      monetizationState: store.monetizationState,
      repositoryAutoSyncSettings: store.repositoryAutoSyncSettings,
      repositoryAutoSyncState: store.repositoryAutoSyncState,
      remoteRepositoryAccessCheck: store.remoteRepositoryAccessCheck,
      deploymentPollingSettings: store.deploymentPollingSettings,
      deploymentPollingState: store.deploymentPollingState,
      deploymentStatusSnapshots: Array(store.deploymentStatusSnapshots.values),
      deploymentStatusHistory: store.deploymentStatusHistory,
      externalVerificationEvidenceRecords: store.externalVerificationEvidenceRecords
    )
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
