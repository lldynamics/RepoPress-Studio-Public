import Foundation

/// Shares in-flight extraction work across the interactive reader and offline
/// prefetch, while keeping origin traffic deliberately conservative.
public actor RSSArticleFullTextRequestBroker {
  public static let shared = RSSArticleFullTextRequestBroker()

  private struct InFlightRequest {
    let token: UUID
    let task: Task<RSSArticleFullTextRecord, Error>
  }

  private let limiter: RSSArticleFullTextRequestLimiter
  private var inFlightByArticleID: [String: InFlightRequest] = [:]

  public init(
    maximumConcurrentRequests: Int = 2,
    maximumConcurrentRequestsPerHost: Int = 1
  ) {
    self.limiter = RSSArticleFullTextRequestLimiter(
      maximumConcurrentRequests: maximumConcurrentRequests,
      maximumConcurrentRequestsPerHost: maximumConcurrentRequestsPerHost
    )
  }

  public func fetch(
    article: RSSArticle,
    cachedRecord: RSSArticleFullTextRecord?,
    allowsPrivateNetworkAccess: Bool,
    forceRefresh: Bool = false,
    service: RSSArticleFullTextService = RSSArticleFullTextService()
  ) async throws -> RSSArticleFullTextRecord {
    guard let host = article.link?.host?.lowercased(), !host.isEmpty else {
      throw RSSReaderError.persistence("该文章没有有效的原文网页链接。")
    }
    return try await perform(articleID: article.id, host: host) {
      try await service.fetchFullTextRecord(
        for: article,
        cachedRecord: cachedRecord,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess,
        forceRefresh: forceRefresh
      )
    }
  }

  /// Internal seam used by deterministic concurrency tests.
  func perform(
    articleID: String,
    host: String,
    operation: @escaping @Sendable () async throws -> RSSArticleFullTextRecord
  ) async throws -> RSSArticleFullTextRecord {
    if let existing = inFlightByArticleID[articleID] {
      return try await existing.task.value
    }

    let token = UUID()
    let normalizedHost = host.lowercased()
    let limiter = self.limiter
    let task = Task<RSSArticleFullTextRecord, Error> {
      try await limiter.perform(host: normalizedHost, operation: operation)
    }
    inFlightByArticleID[articleID] = InFlightRequest(token: token, task: task)

    do {
      let result = try await task.value
      removeInFlightRequest(articleID: articleID, token: token)
      return result
    } catch {
      removeInFlightRequest(articleID: articleID, token: token)
      throw error
    }
  }

  private func removeInFlightRequest(articleID: String, token: UUID) {
    guard inFlightByArticleID[articleID]?.token == token else { return }
    inFlightByArticleID.removeValue(forKey: articleID)
  }
}

private actor RSSArticleFullTextRequestLimiter {
  private struct Waiter {
    let host: String
    let continuation: CheckedContinuation<Void, Never>
  }

  private let maximumConcurrentRequests: Int
  private let maximumConcurrentRequestsPerHost: Int
  private var activeRequestCount = 0
  private var activeRequestCountByHost: [String: Int] = [:]
  private var waiters: [Waiter] = []

  init(maximumConcurrentRequests: Int, maximumConcurrentRequestsPerHost: Int) {
    self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    self.maximumConcurrentRequestsPerHost = max(1, maximumConcurrentRequestsPerHost)
  }

  func perform<T: Sendable>(
    host: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    await acquire(host: host)
    do {
      let value = try await operation()
      release(host: host)
      return value
    } catch {
      release(host: host)
      throw error
    }
  }

  private func acquire(host: String) async {
    if canStart(host: host) {
      markStarted(host: host)
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(Waiter(host: host, continuation: continuation))
    }
  }

  private func release(host: String) {
    activeRequestCount = max(0, activeRequestCount - 1)
    let remainingForHost = max(0, (activeRequestCountByHost[host] ?? 1) - 1)
    if remainingForHost == 0 {
      activeRequestCountByHost.removeValue(forKey: host)
    } else {
      activeRequestCountByHost[host] = remainingForHost
    }
    resumeEligibleWaiters()
  }

  private func resumeEligibleWaiters() {
    while activeRequestCount < maximumConcurrentRequests,
          let index = waiters.firstIndex(where: { canStart(host: $0.host) }) {
      let waiter = waiters.remove(at: index)
      markStarted(host: waiter.host)
      waiter.continuation.resume()
    }
  }

  private func canStart(host: String) -> Bool {
    activeRequestCount < maximumConcurrentRequests
      && (activeRequestCountByHost[host] ?? 0) < maximumConcurrentRequestsPerHost
  }

  private func markStarted(host: String) {
    activeRequestCount += 1
    activeRequestCountByHost[host, default: 0] += 1
  }
}
