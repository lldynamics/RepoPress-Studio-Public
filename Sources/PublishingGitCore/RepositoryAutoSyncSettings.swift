import Foundation

public struct RepositoryAutoSyncSettings: Codable, Hashable, Sendable {
  public var isEnabled: Bool
  public var intervalMinutes: Int
  public var fetchBeforeScan: Bool
  public var autoImportRemoteArticles: Bool

  public init(
    isEnabled: Bool = false,
    intervalMinutes: Int = 15,
    fetchBeforeScan: Bool = true,
    autoImportRemoteArticles: Bool = false
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = max(RepositoryAutoSyncSettings.minimumIntervalMinutes, intervalMinutes)
    self.fetchBeforeScan = fetchBeforeScan
    self.autoImportRemoteArticles = autoImportRemoteArticles
  }

  public static let minimumIntervalMinutes = 5
  public static let maximumIntervalMinutes = 120

  public static var `default`: RepositoryAutoSyncSettings {
    RepositoryAutoSyncSettings()
  }

  public var normalizedIntervalMinutes: Int {
    min(Self.maximumIntervalMinutes, max(Self.minimumIntervalMinutes, intervalMinutes))
  }

  public var interval: TimeInterval {
    TimeInterval(normalizedIntervalMinutes * 60)
  }

  public func nextRunDate(after date: Date) -> Date {
    date.addingTimeInterval(interval)
  }

  public func isDue(lastRunAt: Date?, now: Date) -> Bool {
    guard isEnabled else {
      return false
    }
    guard let lastRunAt else {
      return true
    }
    return now.timeIntervalSince(lastRunAt) >= interval
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled
    case intervalMinutes
    case fetchBeforeScan
    case autoImportRemoteArticles
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    intervalMinutes = max(
      RepositoryAutoSyncSettings.minimumIntervalMinutes,
      try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
    )
    fetchBeforeScan = try container.decodeIfPresent(Bool.self, forKey: .fetchBeforeScan) ?? true
    autoImportRemoteArticles = try container.decodeIfPresent(Bool.self, forKey: .autoImportRemoteArticles) ?? false
  }
}
