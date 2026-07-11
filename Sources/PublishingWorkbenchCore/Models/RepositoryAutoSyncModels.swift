import Foundation

public struct RepositoryAutoSyncSettings: Codable, Hashable, Sendable {
  public var isEnabled: Bool
  public var intervalMinutes: Int
  public var fetchBeforeScan: Bool

  public init(
    isEnabled: Bool = false,
    intervalMinutes: Int = 15,
    fetchBeforeScan: Bool = true
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = max(RepositoryAutoSyncSettings.minimumIntervalMinutes, intervalMinutes)
    self.fetchBeforeScan = fetchBeforeScan
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
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    intervalMinutes = max(
      RepositoryAutoSyncSettings.minimumIntervalMinutes,
      try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
    )
    fetchBeforeScan = try container.decodeIfPresent(Bool.self, forKey: .fetchBeforeScan) ?? true
  }
}

public enum RepositoryAutoSyncStatus: String, Codable, Hashable, Sendable {
  case idle
  case disabled
  case waitingForRepository
  case fetchFailed
  case scanned

  public var displayName: String {
    switch self {
    case .idle:
      return "未运行"
    case .disabled:
      return "已关闭"
    case .waitingForRepository:
      return "等待仓库"
    case .fetchFailed:
      return "Fetch 失败"
    case .scanned:
      return "已扫描"
    }
  }

  public var systemImage: String {
    switch self {
    case .idle:
      return "clock"
    case .disabled:
      return "pause.circle"
    case .waitingForRepository:
      return "externaldrive.badge.questionmark"
    case .fetchFailed:
      return "exclamationmark.arrow.triangle.2.circlepath"
    case .scanned:
      return "arrow.triangle.2.circlepath.circle"
    }
  }
}

public struct RepositoryAutoSyncState: Codable, Hashable, Sendable {
  public var status: RepositoryAutoSyncStatus
  public var lastRunAt: Date?
  public var nextRunAt: Date?
  public var remoteChangedFileCount: Int
  public var remoteChangedPaths: [String]
  public var importableRemoteArticleCount: Int
  public var nonArticleRemoteChangedFileCount: Int
  public var lastFetchAt: Date?
  public var fetchSucceeded: Bool?
  public var fetchMessage: String?
  public var lastRemotePublishAt: Date?
  public var lastRemotePublishProvider: RepositoryProvider?
  public var lastRemotePublishMode: RemoteRepositoryPublishMode?
  public var lastRemotePublishPaths: [String]
  public var message: String

  public init(
    status: RepositoryAutoSyncStatus = .idle,
    lastRunAt: Date? = nil,
    nextRunAt: Date? = nil,
    remoteChangedFileCount: Int = 0,
    remoteChangedPaths: [String] = [],
    importableRemoteArticleCount: Int = 0,
    nonArticleRemoteChangedFileCount: Int = 0,
    lastFetchAt: Date? = nil,
    fetchSucceeded: Bool? = nil,
    fetchMessage: String? = nil,
    lastRemotePublishAt: Date? = nil,
    lastRemotePublishProvider: RepositoryProvider? = nil,
    lastRemotePublishMode: RemoteRepositoryPublishMode? = nil,
    lastRemotePublishPaths: [String] = [],
    message: String = "自动同步尚未运行。"
  ) {
    self.status = status
    self.lastRunAt = lastRunAt
    self.nextRunAt = nextRunAt
    self.remoteChangedFileCount = remoteChangedFileCount
    self.remoteChangedPaths = remoteChangedPaths
    self.importableRemoteArticleCount = importableRemoteArticleCount
    self.nonArticleRemoteChangedFileCount = nonArticleRemoteChangedFileCount
    self.lastFetchAt = lastFetchAt
    self.fetchSucceeded = fetchSucceeded
    self.fetchMessage = fetchMessage
    self.lastRemotePublishAt = lastRemotePublishAt
    self.lastRemotePublishProvider = lastRemotePublishProvider
    self.lastRemotePublishMode = lastRemotePublishMode
    self.lastRemotePublishPaths = Self.limitedRemotePublishPaths(lastRemotePublishPaths)
    self.message = message
  }

  public static var idle: RepositoryAutoSyncState {
    RepositoryAutoSyncState()
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case lastRunAt
    case nextRunAt
    case remoteChangedFileCount
    case remoteChangedPaths
    case importableRemoteArticleCount
    case nonArticleRemoteChangedFileCount
    case lastFetchAt
    case fetchSucceeded
    case fetchMessage
    case lastRemotePublishAt
    case lastRemotePublishProvider
    case lastRemotePublishMode
    case lastRemotePublishPaths
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(RepositoryAutoSyncStatus.self, forKey: .status)
    lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
    nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
    remoteChangedFileCount = try container.decodeIfPresent(Int.self, forKey: .remoteChangedFileCount) ?? 0
    remoteChangedPaths = try container.decodeIfPresent([String].self, forKey: .remoteChangedPaths) ?? []
    importableRemoteArticleCount = try container.decodeIfPresent(Int.self, forKey: .importableRemoteArticleCount) ?? 0
    nonArticleRemoteChangedFileCount = try container.decodeIfPresent(Int.self, forKey: .nonArticleRemoteChangedFileCount) ?? 0
    lastFetchAt = try container.decodeIfPresent(Date.self, forKey: .lastFetchAt)
    fetchSucceeded = try container.decodeIfPresent(Bool.self, forKey: .fetchSucceeded)
    fetchMessage = try container.decodeIfPresent(String.self, forKey: .fetchMessage)
    lastRemotePublishAt = try container.decodeIfPresent(Date.self, forKey: .lastRemotePublishAt)
    lastRemotePublishProvider = try container.decodeIfPresent(RepositoryProvider.self, forKey: .lastRemotePublishProvider)
    lastRemotePublishMode = try container.decodeIfPresent(RemoteRepositoryPublishMode.self, forKey: .lastRemotePublishMode)
    lastRemotePublishPaths = Self.limitedRemotePublishPaths(
      try container.decodeIfPresent([String].self, forKey: .lastRemotePublishPaths) ?? []
    )
    message = try container.decodeIfPresent(String.self, forKey: .message) ?? "自动同步尚未运行。"
  }

  public static func limitedRemotePublishPaths(_ paths: [String], limit: Int = 20) -> [String] {
    Array(paths.filter { !$0.trimmedForPublishing.isEmpty }.prefix(limit))
  }
}
