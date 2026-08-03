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
  public var destinationBookmarkData: Data?
  public var lastBackupAt: Date?
  public var lastValidationAt: Date?
  public var lastBackupPath: String?
  public var lastError: String?

  public init(
    frequency: WorkspaceBackupFrequency = .off,
    destinationPath: String? = nil,
    destinationBookmarkData: Data? = nil,
    lastBackupAt: Date? = nil,
    lastValidationAt: Date? = nil,
    lastBackupPath: String? = nil,
    lastError: String? = nil
  ) {
    self.frequency = frequency
    self.destinationPath = destinationPath
    self.destinationBookmarkData = destinationBookmarkData
    self.lastBackupAt = lastBackupAt
    self.lastValidationAt = lastValidationAt
    self.lastBackupPath = lastBackupPath
    self.lastError = lastError
  }
}
