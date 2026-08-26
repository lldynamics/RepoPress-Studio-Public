import Foundation

public struct RemoteArticleAutoImportSummary: Codable, Hashable, Sendable {
  public var insertedCount: Int
  public var updatedCount: Int
  public var unchangedCount: Int
  public var conflictPaths: [String]
  public var deletionPaths: [String]
  public var failedPaths: [String]
  public var resolvedPaths: [String]

  public init(
    insertedCount: Int = 0,
    updatedCount: Int = 0,
    unchangedCount: Int = 0,
    conflictPaths: [String] = [],
    deletionPaths: [String] = [],
    failedPaths: [String] = [],
    resolvedPaths: [String] = []
  ) {
    self.insertedCount = insertedCount
    self.updatedCount = updatedCount
    self.unchangedCount = unchangedCount
    self.conflictPaths = conflictPaths
    self.deletionPaths = deletionPaths
    self.failedPaths = failedPaths
    self.resolvedPaths = resolvedPaths
  }

  public var importedCount: Int {
    insertedCount + updatedCount
  }

  public var pendingReviewCount: Int {
    conflictPaths.count + deletionPaths.count + failedPaths.count
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
  public var lastAutoImportAt: Date?
  public var lastAutoImportedArticleCount: Int
  public var lastAutoImportConflictCount: Int
  public var lastAutoImportDeletionCount: Int
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
    lastAutoImportAt: Date? = nil,
    lastAutoImportedArticleCount: Int = 0,
    lastAutoImportConflictCount: Int = 0,
    lastAutoImportDeletionCount: Int = 0,
    lastRemotePublishAt: Date? = nil,
    lastRemotePublishProvider: RepositoryProvider? = nil,
    lastRemotePublishMode: RemoteRepositoryPublishMode? = nil,
    lastRemotePublishPaths: [String] = [],
    message: String? = nil
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
    self.lastAutoImportAt = lastAutoImportAt
    self.lastAutoImportedArticleCount = lastAutoImportedArticleCount
    self.lastAutoImportConflictCount = lastAutoImportConflictCount
    self.lastAutoImportDeletionCount = lastAutoImportDeletionCount
    self.lastRemotePublishAt = lastRemotePublishAt
    self.lastRemotePublishProvider = lastRemotePublishProvider
    self.lastRemotePublishMode = lastRemotePublishMode
    self.lastRemotePublishPaths = Self.limitedRemotePublishPaths(lastRemotePublishPaths)
    self.message = message ?? CoreL10n.text("自动检查远端尚未运行。")
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
    case lastAutoImportAt
    case lastAutoImportedArticleCount
    case lastAutoImportConflictCount
    case lastAutoImportDeletionCount
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
    lastAutoImportAt = try container.decodeIfPresent(Date.self, forKey: .lastAutoImportAt)
    lastAutoImportedArticleCount = try container.decodeIfPresent(Int.self, forKey: .lastAutoImportedArticleCount) ?? 0
    lastAutoImportConflictCount = try container.decodeIfPresent(Int.self, forKey: .lastAutoImportConflictCount) ?? 0
    lastAutoImportDeletionCount = try container.decodeIfPresent(Int.self, forKey: .lastAutoImportDeletionCount) ?? 0
    lastRemotePublishAt = try container.decodeIfPresent(Date.self, forKey: .lastRemotePublishAt)
    lastRemotePublishProvider = try container.decodeIfPresent(RepositoryProvider.self, forKey: .lastRemotePublishProvider)
    lastRemotePublishMode = try container.decodeIfPresent(RemoteRepositoryPublishMode.self, forKey: .lastRemotePublishMode)
    lastRemotePublishPaths = Self.limitedRemotePublishPaths(
      try container.decodeIfPresent([String].self, forKey: .lastRemotePublishPaths) ?? []
    )
    let decodedMessage = try container.decodeIfPresent(String.self, forKey: .message)
      ?? CoreL10n.text("自动检查远端尚未运行。")
    message = decodedMessage.replacingOccurrences(of: "自动同步", with: "自动检查远端")
  }

  public static func limitedRemotePublishPaths(_ paths: [String], limit: Int = 20) -> [String] {
    Array(paths.filter { !$0.trimmedForPublishing.isEmpty }.prefix(limit))
  }
}
