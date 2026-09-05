import Foundation

/// Semantic event kinds that are not already represented by a canonical
/// release, maintenance, automation, AI, or deployment record.
///
/// The ledger deliberately stores no free-form messages, paths, URLs, or
/// document contents. Display strings are produced only when the safe
/// operation-log projection is built.
public enum WorkbenchOperationEventKind: String, CaseIterable, Codable, Hashable, Sendable {
  case localContentImport
  case remoteContentImport
  case contentMigration
  case siteImport
  case knowledgeImport
  case imagePrivacySanitization
  case imageJPEGOptimization
  case imageWebPConversion
  case imageSVGOptimization
  case imageResize
  case imageCoverCrop
  case workspaceBackupCreated
  case workspaceRestorePrepared
  case workspaceRestoreCompleted

  public var category: WorkbenchOperationLogCategory {
    switch self {
    case .localContentImport, .remoteContentImport, .contentMigration, .siteImport,
      .knowledgeImport:
      return .importing
    case .imagePrivacySanitization, .imageJPEGOptimization, .imageWebPConversion,
      .imageSVGOptimization, .imageResize, .imageCoverCrop:
      return .images
    case .workspaceBackupCreated, .workspaceRestorePrepared, .workspaceRestoreCompleted:
      return .backup
    }
  }
}

/// A privacy-bounded, locale-independent record persisted in the operation
/// ledger sidecar. Every metric is optional so a failed or cancelled operation
/// can be recorded without inventing counts.
public struct WorkbenchOperationEventRecord: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let kind: WorkbenchOperationEventKind
  public let outcome: WorkbenchOperationLogOutcome
  public let actor: WorkbenchOperationLogActor
  public let profileID: UUID?
  public let draftID: UUID?
  public let occurredAt: Date
  public let processedItemCount: Int?
  public let createdItemCount: Int?
  public let updatedItemCount: Int?
  public let skippedItemCount: Int?
  public let savedByteCount: Int64?
  public let draftCount: Int?
  public let draftVersionCount: Int?

  public init(
    id: UUID = UUID(),
    kind: WorkbenchOperationEventKind,
    outcome: WorkbenchOperationLogOutcome,
    actor: WorkbenchOperationLogActor = .user,
    profileID: UUID? = nil,
    draftID: UUID? = nil,
    occurredAt: Date = Date(),
    processedItemCount: Int? = nil,
    createdItemCount: Int? = nil,
    updatedItemCount: Int? = nil,
    skippedItemCount: Int? = nil,
    savedByteCount: Int64? = nil,
    draftCount: Int? = nil,
    draftVersionCount: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.outcome = outcome
    self.actor = actor
    self.profileID = profileID
    self.draftID = draftID
    self.occurredAt = occurredAt
    self.processedItemCount = processedItemCount.map { max(0, $0) }
    self.createdItemCount = createdItemCount.map { max(0, $0) }
    self.updatedItemCount = updatedItemCount.map { max(0, $0) }
    self.skippedItemCount = skippedItemCount.map { max(0, $0) }
    self.savedByteCount = savedByteCount.map { max(0, $0) }
    self.draftCount = draftCount.map { max(0, $0) }
    self.draftVersionCount = draftVersionCount.map { max(0, $0) }
  }
}

public enum WorkbenchOperationLogRetentionPolicy: String, CaseIterable, Codable, Hashable,
  Identifiable, Sendable
{
  case thirtyDays
  case ninetyDays
  case oneYear
  case forever

  public var id: String { rawValue }

  public static let `default`: Self = .ninetyDays

  public func cutoffDate(relativeTo now: Date) -> Date? {
    let dayCount: Int
    switch self {
    case .thirtyDays:
      dayCount = 30
    case .ninetyDays:
      dayCount = 90
    case .oneYear:
      dayCount = 365
    case .forever:
      return nil
    }
    return now.addingTimeInterval(-Double(dayCount) * 24 * 60 * 60)
  }
}

public struct WorkbenchOperationLedgerDocument: Codable, Hashable, Sendable {
  public static let currentFormatVersion = 1
  public static let maximumRecordCount = 2_000

  public var formatVersion: Int
  public var retentionPolicy: WorkbenchOperationLogRetentionPolicy
  public var visibleSince: Date?
  public var records: [WorkbenchOperationEventRecord]

  public init(
    retentionPolicy: WorkbenchOperationLogRetentionPolicy = .default,
    visibleSince: Date? = nil,
    records: [WorkbenchOperationEventRecord] = []
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.retentionPolicy = retentionPolicy
    self.visibleSince = visibleSince
    self.records = records
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case retentionPolicy
    case visibleSince
    case records
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
    guard version == Self.currentFormatVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .formatVersion,
        in: container,
        debugDescription: "Unsupported operation-ledger format version: \(version)"
      )
    }
    formatVersion = Self.currentFormatVersion
    retentionPolicy =
      try container.decodeIfPresent(
        WorkbenchOperationLogRetentionPolicy.self,
        forKey: .retentionPolicy
      ) ?? .default
    visibleSince = try container.decodeIfPresent(Date.self, forKey: .visibleSince)
    records =
      try container.decodeIfPresent(
        [WorkbenchOperationEventRecord].self,
        forKey: .records
      ) ?? []
  }

  public func normalized(now: Date = Date()) -> Self {
    let retentionCutoff = retentionPolicy.cutoffDate(relativeTo: now)
    var seenIDs = Set<UUID>()
    let normalizedRecords =
      records
      .filter { record in
        guard visibleSince.map({ record.occurredAt > $0 }) ?? true else { return false }
        return retentionCutoff.map({ record.occurredAt >= $0 }) ?? true
      }
      .sorted {
        if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
        return $0.id.uuidString < $1.id.uuidString
      }
      .filter { seenIDs.insert($0.id).inserted }
      .prefix(Self.maximumRecordCount)

    return Self(
      retentionPolicy: retentionPolicy,
      visibleSince: visibleSince,
      records: Array(normalizedRecords)
    )
  }
}
