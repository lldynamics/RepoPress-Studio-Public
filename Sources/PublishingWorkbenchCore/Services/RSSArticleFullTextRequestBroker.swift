import Foundation

/// Shares in-flight extraction work across the interactive reader and offline
/// prefetch, while keeping origin traffic deliberately conservative.
public actor RSSArticleFullTextRequestBroker {
  public static let shared = RSSArticleFullTextRequestBroker()

  private struct RequestKey: Hashable, Sendable {
    let articleID: String
    let sourceURL: String
    let forceRefresh: Bool
    let allowsPrivateNetworkAccess: Bool
  }

  private struct InFlightRequest {
    let token: UUID
    let task: Task<RSSArticleFullTextRecord, Error>
  }

  private let limiter: RSSArticleFullTextRequestLimiter
  private var inFlightByRequestKey: [RequestKey: InFlightRequest] = [:]

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
    return try await perform(
      articleID: article.id,
      host: host,
      sourceURL: article.link,
      forceRefresh: forceRefresh,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    ) {
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
    sourceURL: URL? = nil,
    forceRefresh: Bool = false,
    allowsPrivateNetworkAccess: Bool = false,
    operation: @escaping @Sendable () async throws -> RSSArticleFullTextRecord
  ) async throws -> RSSArticleFullTextRecord {
    let requestKey = RequestKey(
      articleID: articleID,
      // Older internal callers do not have a source URL. Keep their previous
      // per-article de-duplication contract without allowing production RSS
      // fetches (which always pass a URL) to share that compatibility key.
      sourceURL: sourceURL?.absoluteString ?? "",
      forceRefresh: forceRefresh,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )
    if let existing = inFlightByRequestKey[requestKey] {
      return try await existing.task.value
    }

    let token = UUID()
    let normalizedHost = host.lowercased()
    let limiter = self.limiter
    let task = Task<RSSArticleFullTextRecord, Error> {
      try await limiter.perform(host: normalizedHost, operation: operation)
    }
    inFlightByRequestKey[requestKey] = InFlightRequest(token: token, task: task)

    do {
      let result = try await task.value
      removeInFlightRequest(requestKey: requestKey, token: token)
      return result
    } catch {
      removeInFlightRequest(requestKey: requestKey, token: token)
      throw error
    }
  }

  private func removeInFlightRequest(requestKey: RequestKey, token: UUID) {
    guard inFlightByRequestKey[requestKey]?.token == token else { return }
    inFlightByRequestKey.removeValue(forKey: requestKey)
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
