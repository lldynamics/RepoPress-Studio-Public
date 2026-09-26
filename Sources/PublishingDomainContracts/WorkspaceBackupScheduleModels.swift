import Foundation

public enum WorkspaceBackupFrequency: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case daily
  case weekly

  public var displayName: String {
    switch self {
    case .off:
      return "关闭"
    case .daily:
      return "每天"
    case .weekly:
      return "每周"
    }
  }

  public var interval: TimeInterval? {
    switch self {
    case .off:
      return nil
    case .daily:
      return 24 * 60 * 60
    case .weekly:
      return 7 * 24 * 60 * 60
    }
  }
}

public struct WorkspaceBackupScheduleSettings: Codable, Hashable, Sendable {
  public var frequency: WorkspaceBackupFrequency
  public var destinationPath: String?
  public var lastBackupAt: Date?
  public var lastValidationAt: Date?
  public var lastBackupPath: String?
  public var lastError: String?
  /// Raw workspace-backup category IDs, kept as strings to avoid coupling the
  /// domain contracts module to the backup implementation module.
  public var selectedCategoryIDs: [String]?
  public var lastContentFingerprint: String?
  /// Keeps automatic snapshots on a user-selected destination without applying
  /// the bounded automatic-history cleanup policy.
  public var preserveAutomaticBackupHistoryOnSelectedDisk: Bool
  public var destinationIsICloud: Bool
  public var destinationVolumeUUID: String?
  /// Avoids pruning an existing destination until the next successful backup
  /// after the user switches back to the bounded retention policy.
  public var deferAutomaticBackupPruningUntilNextBackup: Bool

  public init(
    frequency: WorkspaceBackupFrequency = .off,
    destinationPath: String? = nil,
    lastBackupAt: Date? = nil,
    lastValidationAt: Date? = nil,
    lastBackupPath: String? = nil,
    lastError: String? = nil,
    selectedCategoryIDs: [String]? = nil,
    lastContentFingerprint: String? = nil,
    preserveAutomaticBackupHistoryOnSelectedDisk: Bool = false,
    destinationIsICloud: Bool = false,
    destinationVolumeUUID: String? = nil,
    deferAutomaticBackupPruningUntilNextBackup: Bool = false
  ) {
    self.frequency = frequency
    self.destinationPath = destinationPath
    self.lastBackupAt = lastBackupAt
    self.lastValidationAt = lastValidationAt
    self.lastBackupPath = lastBackupPath
    self.lastError = lastError
    self.selectedCategoryIDs = selectedCategoryIDs
    self.lastContentFingerprint = lastContentFingerprint
    self.preserveAutomaticBackupHistoryOnSelectedDisk = preserveAutomaticBackupHistoryOnSelectedDisk
    self.destinationIsICloud = destinationIsICloud
    self.destinationVolumeUUID = destinationVolumeUUID
    self.deferAutomaticBackupPruningUntilNextBackup = deferAutomaticBackupPruningUntilNextBackup
  }

  private enum CodingKeys: String, CodingKey {
    case frequency, destinationPath, lastBackupAt, lastValidationAt, lastBackupPath, lastError
    case selectedCategoryIDs, lastContentFingerprint, preserveAutomaticBackupHistoryOnSelectedDisk,
      destinationIsICloud, destinationVolumeUUID, deferAutomaticBackupPruningUntilNextBackup
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    frequency =
      try container.decodeIfPresent(WorkspaceBackupFrequency.self, forKey: .frequency) ?? .off
    destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)
    lastBackupAt = try container.decodeIfPresent(Date.self, forKey: .lastBackupAt)
    lastValidationAt = try container.decodeIfPresent(Date.self, forKey: .lastValidationAt)
    lastBackupPath = try container.decodeIfPresent(String.self, forKey: .lastBackupPath)
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    selectedCategoryIDs = try container.decodeIfPresent([String].self, forKey: .selectedCategoryIDs)
    lastContentFingerprint = try container.decodeIfPresent(
      String.self, forKey: .lastContentFingerprint)
    preserveAutomaticBackupHistoryOnSelectedDisk =
      try container.decodeIfPresent(
        Bool.self, forKey: .preserveAutomaticBackupHistoryOnSelectedDisk) ?? false
    destinationIsICloud =
      try container.decodeIfPresent(Bool.self, forKey: .destinationIsICloud) ?? false
    destinationVolumeUUID = try container.decodeIfPresent(
      String.self, forKey: .destinationVolumeUUID)
    deferAutomaticBackupPruningUntilNextBackup =
      try container.decodeIfPresent(Bool.self, forKey: .deferAutomaticBackupPruningUntilNextBackup)
      ?? false
  }
}
