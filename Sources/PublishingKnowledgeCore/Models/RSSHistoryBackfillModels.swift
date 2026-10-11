import Foundation
import PublishingCoreSupport

public enum RSSHistoryBackfillStatus: String, Codable, Sendable {
  case discovering, fetching, paused, completed, unavailable
}

public struct RSSHistoryBackfillCandidate: Codable, Equatable, Sendable {
  public let url: URL
  public let title: String
}

/// Position within one bounded public index. A changed index must be
/// rediscovered explicitly rather than silently skipping a different prefix.
public struct RSSHistoryDiscoveryCursor: Codable, Equatable, Sendable {
  public let url: URL
  public let articleOffset: Int
  public let fingerprint: String
}

/// Bounded, durable work queue. A completed item and these counters commit in
/// the same SQLite transaction, so a restart cannot count an item twice.
public struct RSSHistoryBackfillProgress: Codable, Equatable, Sendable {
  public let id: UUID
  public let feedID: UUID
  public let feedURL: URL
  public let directoryURL: URL
  public var status: RSSHistoryBackfillStatus = .discovering
  public var candidates: [RSSHistoryBackfillCandidate] = []
  public var pendingPages: [URL]
  public var visitedPages: [URL] = []
  public var nextIndex = 0
  public var addedCount = 0
  public var duplicateCount = 0
  public var fullTextSuccessCount = 0
  public var fullTextFailureCount = 0
  public var failedIndices: [Int] = []
  public var retryAt: Date?
  public var message = ""
  public var reachedDiscoveryLimit = false

  // Optional fields preserve checkpoints written by the first implementation.
  public var discoveryCursor: RSSHistoryDiscoveryCursor?
  public var completedDiscoveryCount: Int?
  public var sitemapsLoaded: Bool?
  public var retryingFailures: Bool?
  public var failureLedgerInitialized: Bool? = true
  public var failureRetryAfterURLKey: String?

  public var discoveredCount: Int {
    (completedDiscoveryCount ?? 0) + (retryingFailures == true ? 0 : candidates.count)
  }
  public var hasMoreDiscovery: Bool { discoveryCursor != nil || !pendingPages.isEmpty }
  public var canRetryFailures: Bool {
    !isRunning && nextIndex == candidates.count && fullTextFailureCount > 0
  }
  public var canResume: Bool { status == .paused }
  public var isRunning: Bool { status == .discovering || status == .fetching }

  public init(feedID: UUID, feedURL: URL, directoryURL: URL) {
    self.id = UUID()
    self.feedID = feedID
    self.feedURL = feedURL
    self.directoryURL = directoryURL
    self.pendingPages = [directoryURL]
  }
}

public struct RSSHistoryBackfillLimits: Sendable {
  public let maximumPages: Int
  public let maximumURLs: Int
  public let batchSize: Int
  public let requestDelay: TimeInterval

  public init(
    maximumPages: Int = 10, maximumURLs: Int = 500,
    batchSize: Int = 20, requestDelay: TimeInterval = 1
  ) {
    self.maximumPages = min(10, max(1, maximumPages))
    self.maximumURLs = min(500, max(1, maximumURLs))
    self.batchSize = min(50, max(1, batchSize))
    self.requestDelay = min(30, max(0, requestDelay))
  }
}

public enum RSSHistoryBackfillError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case sourceChanged

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): message
    case .sourceChanged: CoreL10n.text("订阅已删除或地址已改变，历史补齐已停止。")
    }
  }
}

enum RSSHistoryURLIdentity {
  /// Query strings, path case, slash multiplicity and trailing slashes remain
  /// significant. Only explicit redirect/canonical evidence can add aliases.
  static func key(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
    components?.fragment = nil
    let host = components?.host?.lowercased()
    components?.host = host
    return components?.url?.absoluteString ?? url.absoluteString
  }

  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && lhs.port == rhs.port
  }

  /// This is only a reason to VERIFY an old URL. It is never a dedup key.
  static func mayBeSlashAlias(_ lhs: URL, _ rhs: URL) -> Bool {
    guard sameOrigin(lhs, rhs), lhs.query == rhs.query else { return false }
    return lhs.path.split(separator: "/") == rhs.path.split(separator: "/")
  }
}
