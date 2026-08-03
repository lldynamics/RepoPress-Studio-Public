import Foundation

public enum RSSFeedIssueStage: String, Codable, CaseIterable, Hashable, Sendable {
  case validation
  case discovery
  case transport
  case response
  case parsing
  case persistence
}

public enum RSSFeedIssueCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case invalidAddress
  case unsupportedAddress
  case offline
  case dnsFailure
  case timeout
  case tlsFailure
  case cancelled
  case responseTooLarge
  case invalidResponse
  case authenticationRequired
  case permissionDenied
  case notFound
  case gone
  case rateLimited
  case serverUnavailable
  case httpFailure
  case invalidContent
  case emptyFeed
  case storage
  case unknown
}

public enum RSSFeedRetryStrategy: String, Codable, CaseIterable, Hashable, Sendable {
  case automatic
  case afterDate
  case manual
  case requiresAction
  case none
}

public struct RSSFeedIssue: Codable, Hashable, Sendable {
  public var stage: RSSFeedIssueStage
  public var category: RSSFeedIssueCategory
  public var retryStrategy: RSSFeedRetryStrategy
  public var retryAt: Date?
  public var userMessage: String
  public var technicalDetail: String?
  public var occurredAt: Date

  public init(
    stage: RSSFeedIssueStage,
    category: RSSFeedIssueCategory,
    retryStrategy: RSSFeedRetryStrategy,
    retryAt: Date? = nil,
    userMessage: String,
    technicalDetail: String? = nil,
    occurredAt: Date = Date()
  ) {
    self.stage = stage
    self.category = category
    self.retryStrategy = retryAt == nil && retryStrategy == .afterDate ? .automatic : retryStrategy
    self.retryAt = retryAt
    self.userMessage = Self.bounded(userMessage, maximumLength: 1_000)
    self.technicalDetail = technicalDetail.map {
      Self.bounded($0, maximumLength: 4_000)
    }
    self.occurredAt = occurredAt
  }

  public var shouldRetryAutomatically: Bool {
    retryStrategy == .automatic || retryStrategy == .afterDate
  }

  public static func from(
    error: Error,
    stage: RSSFeedIssueStage = .transport,
    occurredAt: Date = Date()
  ) -> RSSFeedIssue {
    if let issue = error as? RSSFeedIssueError {
      return issue.issue
    }
    if let readerError = error as? RSSReaderError {
      return readerError.asFeedIssue(occurredAt: occurredAt)
    }
    if error is CancellationError {
      return cancelled(technicalDetail: error.localizedDescription, occurredAt: occurredAt)
    }
    if let urlError = error as? URLError {
      return from(urlError: urlError, occurredAt: occurredAt)
    }
    return RSSFeedIssue(
      stage: stage,
      category: .unknown,
      retryStrategy: .automatic,
      userMessage: "订阅读取暂时失败，请稍后重试。",
      technicalDetail: error.localizedDescription,
      occurredAt: occurredAt
    )
  }

  public static func from(
    urlError: URLError,
    occurredAt: Date = Date()
  ) -> RSSFeedIssue {
    let detail = urlError.localizedDescription
    switch urlError.code {
    case .badURL, .unsupportedURL:
      return RSSFeedIssue(
        stage: .validation,
        category: .invalidAddress,
        retryStrategy: .requiresAction,
        userMessage: "订阅地址无效，请检查后重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
      .dataNotAllowed, .callIsActive:
      return RSSFeedIssue(
        stage: .transport,
        category: .offline,
        retryStrategy: .automatic,
        userMessage: "当前无法连接网络；网络恢复后会自动重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
      return RSSFeedIssue(
        stage: .transport,
        category: .dnsFailure,
        retryStrategy: .automatic,
        userMessage: "暂时无法连接订阅服务器，请稍后重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case .timedOut:
      return RSSFeedIssue(
        stage: .transport,
        category: .timeout,
        retryStrategy: .automatic,
        userMessage: "订阅服务器响应超时，请稍后重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case .secureConnectionFailed, .serverCertificateHasBadDate,
      .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid, .clientCertificateRejected,
      .clientCertificateRequired:
      return RSSFeedIssue(
        stage: .transport,
        category: .tlsFailure,
        retryStrategy: .requiresAction,
        userMessage: "无法建立安全连接，请检查订阅网站的证书或地址。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case .cancelled:
      return cancelled(technicalDetail: detail, occurredAt: occurredAt)
    default:
      return RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: "订阅读取暂时失败，请稍后重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    }
  }

  public static func http(
    statusCode: Int,
    retryAt: Date? = nil,
    technicalDetail: String? = nil,
    occurredAt: Date = Date()
  ) -> RSSFeedIssue {
    let detail = technicalDetail ?? "HTTP \(statusCode)"
    switch statusCode {
    case 408:
      return RSSFeedIssue(
        stage: .response,
        category: .timeout,
        retryStrategy: retryAt == nil ? .automatic : .afterDate,
        retryAt: retryAt,
        userMessage: retryAt == nil
          ? "订阅服务器处理超时，稍后会自动重试。"
          : "订阅服务器处理超时，将在服务器允许的时间后自动重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 401:
      return RSSFeedIssue(
        stage: .response,
        category: .authenticationRequired,
        retryStrategy: .requiresAction,
        userMessage: "该订阅需要登录或访问凭证。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 403:
      return RSSFeedIssue(
        stage: .response,
        category: .permissionDenied,
        retryStrategy: .requiresAction,
        userMessage: "订阅服务器拒绝了访问，请检查地址或权限。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 404:
      return RSSFeedIssue(
        stage: .response,
        category: .notFound,
        retryStrategy: .requiresAction,
        userMessage: "没有找到该订阅，请检查地址是否已经变更。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 410:
      return RSSFeedIssue(
        stage: .response,
        category: .gone,
        retryStrategy: .requiresAction,
        userMessage: "该订阅已经停止提供，请查找新的订阅地址。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 429:
      return RSSFeedIssue(
        stage: .response,
        category: .rateLimited,
        retryStrategy: retryAt == nil ? .automatic : .afterDate,
        retryAt: retryAt,
        userMessage: retryAt == nil
          ? "请求过于频繁，稍后会自动重试。"
          : "请求过于频繁，将在服务器允许的时间后自动重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    case 500...599:
      return RSSFeedIssue(
        stage: .response,
        category: .serverUnavailable,
        retryStrategy: retryAt == nil ? .automatic : .afterDate,
        retryAt: retryAt,
        userMessage: retryAt == nil
          ? "订阅服务器暂时不可用，稍后会自动重试。"
          : "订阅服务器暂时不可用，将在服务器允许的时间后自动重试。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    default:
      return RSSFeedIssue(
        stage: .response,
        category: .httpFailure,
        retryStrategy: .manual,
        userMessage: "订阅服务器返回异常状态（HTTP \(statusCode)）。",
        technicalDetail: detail,
        occurredAt: occurredAt
      )
    }
  }

  public static func cancelled(
    technicalDetail: String? = nil,
    occurredAt: Date = Date()
  ) -> RSSFeedIssue {
    RSSFeedIssue(
      stage: .transport,
      category: .cancelled,
      retryStrategy: .none,
      userMessage: "订阅读取已取消。",
      technicalDetail: technicalDetail,
      occurredAt: occurredAt
    )
  }

  private static func bounded(_ value: String, maximumLength: Int) -> String {
    String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
  }
}

public struct RSSFeedIssueError: Error, Equatable, LocalizedError, Sendable {
  public let issue: RSSFeedIssue

  public init(_ issue: RSSFeedIssue) {
    self.issue = issue
  }

  public var errorDescription: String? { issue.userMessage }
}

public enum RSSFeedHealthStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case never
  case healthy
  case failing
  case backingOff

  public var id: String { rawValue }
}

public struct RSSFeed: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var url: URL
  public var siteURL: URL?
  public var iconURL: URL?
  public let addedAt: Date
  public var lastUpdatedAt: Date?
  public var etag: String?
  public var lastModified: String?
  public var lastError: String?
  public var lastIssue: RSSFeedIssue?
  public var lastRefreshAttemptAt: Date?
  public var refreshFailureCount: Int
  public var nextRetryAt: Date?
  public var lastRefreshDuration: TimeInterval?

  public init(
    id: UUID = UUID(),
    title: String,
    url: URL,
    siteURL: URL? = nil,
    iconURL: URL? = nil,
    addedAt: Date = Date(),
    lastUpdatedAt: Date? = nil,
    etag: String? = nil,
    lastModified: String? = nil,
    lastError: String? = nil,
    lastIssue: RSSFeedIssue? = nil,
    lastRefreshAttemptAt: Date? = nil,
    refreshFailureCount: Int = 0,
    nextRetryAt: Date? = nil,
    lastRefreshDuration: TimeInterval? = nil
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.siteURL = siteURL
    self.iconURL = iconURL
    self.addedAt = addedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.etag = etag
    self.lastModified = lastModified
    self.lastError = lastError ?? lastIssue?.userMessage
    self.lastIssue = lastIssue
    self.lastRefreshAttemptAt = lastRefreshAttemptAt
    self.refreshFailureCount = max(0, refreshFailureCount)
    self.nextRetryAt = nextRetryAt ?? lastIssue?.retryAt
    self.lastRefreshDuration = lastRefreshDuration
  }

  public var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed
  }

  public var hostName: String {
    url.host ?? url.absoluteString
  }

  public func healthStatus(now: Date = Date()) -> RSSFeedHealthStatus {
    if let retryAt = nextRetryAt ?? lastIssue?.retryAt, retryAt > now {
      return .backingOff
    }
    if lastIssue != nil || lastError != nil { return .failing }
    if lastUpdatedAt != nil { return .healthy }
    return .never
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case url
    case siteURL
    case iconURL
    case addedAt
    case lastUpdatedAt
    case etag
    case lastModified
    case lastError
    case lastIssue
    case lastRefreshAttemptAt
    case refreshFailureCount
    case nextRetryAt
    case lastRefreshDuration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    let decodedLastIssue = try container.decodeIfPresent(RSSFeedIssue.self, forKey: .lastIssue)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      title: try container.decode(String.self, forKey: .title),
      url: try container.decode(URL.self, forKey: .url),
      siteURL: try container.decodeIfPresent(URL.self, forKey: .siteURL),
      iconURL: try container.decodeIfPresent(URL.self, forKey: .iconURL),
      addedAt: try container.decode(Date.self, forKey: .addedAt),
      lastUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt),
      etag: try container.decodeIfPresent(String.self, forKey: .etag),
      lastModified: try container.decodeIfPresent(String.self, forKey: .lastModified),
      lastError: decodedLastError,
      lastIssue: decodedLastIssue ?? decodedLastError.map {
        RSSFeedIssue(
          stage: .transport,
          category: .unknown,
          retryStrategy: .automatic,
          userMessage: $0,
          technicalDetail: "由旧版 RSS 错误状态迁移",
          occurredAt: (try? container.decodeIfPresent(Date.self, forKey: .lastRefreshAttemptAt)) ?? Date()
        )
      },
      lastRefreshAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastRefreshAttemptAt),
      refreshFailureCount: try container.decodeIfPresent(Int.self, forKey: .refreshFailureCount) ?? 0,
      nextRetryAt: try container.decodeIfPresent(Date.self, forKey: .nextRetryAt),
      lastRefreshDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .lastRefreshDuration)
    )
  }
}

public struct RSSArticle: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let feedID: UUID
  public var title: String
  public var link: URL?
  public var author: String?
  public var publishedAt: Date?
  public var summaryHTML: String
  public var contentHTML: String
  public var fetchedAt: Date
  public var readAt: Date?
  public var isStarred: Bool
  public var tags: [String]

  public init(
    id: String,
    feedID: UUID,
    title: String,
    link: URL? = nil,
    author: String? = nil,
    publishedAt: Date? = nil,
    summaryHTML: String = "",
    contentHTML: String = "",
    fetchedAt: Date = Date(),
    readAt: Date? = nil,
    isStarred: Bool = false,
    tags: [String] = []
  ) {
    self.id = id
    self.feedID = feedID
    self.title = title
    self.link = link
    self.author = author
    self.publishedAt = publishedAt
    self.summaryHTML = summaryHTML
    self.contentHTML = contentHTML
    self.fetchedAt = fetchedAt
    self.readAt = readAt
    self.isStarred = isStarred
    self.tags = RSSArticle.normalizedTags(tags)
  }

  public var isRead: Bool { readAt != nil }

  public var readableText: String {
    RSSHTMLTextSanitizer.plainText(
      from: contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? summaryHTML
        : contentHTML
    )
  }

  public var readableSummary: String {
    let summary = RSSHTMLTextSanitizer.plainText(from: summaryHTML)
    return summary.isEmpty ? readableText : summary
  }

  public var estimatedReadingMinutes: Int {
    let text = readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return 1 }
    let latinWords = text.split { $0.isWhitespace || $0.isPunctuation }.count
    let cjkCharacters = text.unicodeScalars.filter { scalar in
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
        true
      default:
        false
      }
    }.count
    let readingUnits = max(latinWords, cjkCharacters)
    return max(1, Int(ceil(Double(readingUnits) / 220.0)))
  }

  static func normalizedTags(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { rawValue in
      let value = String(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
      guard !value.isEmpty else { return nil }
      let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      return seen.insert(key).inserted ? value : nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case feedID
    case title
    case link
    case author
    case publishedAt
    case summaryHTML
    case contentHTML
    case fetchedAt
    case readAt
    case isStarred
    case tags
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      feedID: try container.decode(UUID.self, forKey: .feedID),
      title: try container.decode(String.self, forKey: .title),
      link: try container.decodeIfPresent(URL.self, forKey: .link),
      author: try container.decodeIfPresent(String.self, forKey: .author),
      publishedAt: try container.decodeIfPresent(Date.self, forKey: .publishedAt),
      summaryHTML: try container.decodeIfPresent(String.self, forKey: .summaryHTML) ?? "",
      contentHTML: try container.decodeIfPresent(String.self, forKey: .contentHTML) ?? "",
      fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
      readAt: try container.decodeIfPresent(Date.self, forKey: .readAt),
      isStarred: try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false,
      tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    )
  }
}

/// The lightweight, list-safe representation of a persisted RSS article.
///
/// This type deliberately contains no HTML payload. Lists, counters, filters,
/// and navigation can therefore keep the complete local archive in memory
/// without retaining every article body. Call `RSSReaderStore.loadArticle(id:)`
/// when a reader surface needs the full `RSSArticle`.
public struct RSSArticleHeader: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let feedID: UUID
  public var title: String
  public var link: URL?
  public var author: String?
  public var publishedAt: Date?
  public var readableSummary: String
  public var fetchedAt: Date
  public var readAt: Date?
  public var isStarred: Bool
  public var tags: [String]

  public init(
    id: String,
    feedID: UUID,
    title: String,
    link: URL? = nil,
    author: String? = nil,
    publishedAt: Date? = nil,
    readableSummary: String = "",
    fetchedAt: Date = Date(),
    readAt: Date? = nil,
    isStarred: Bool = false,
    tags: [String] = []
  ) {
    self.id = id
    self.feedID = feedID
    self.title = title
    self.link = link
    self.author = author
    self.publishedAt = publishedAt
    self.readableSummary = Self.normalizedReadableSummary(readableSummary)
    self.fetchedAt = fetchedAt
    self.readAt = readAt
    self.isStarred = isStarred
    self.tags = RSSArticle.normalizedTags(tags)
  }

  public init(article: RSSArticle) {
    self.init(
      id: article.id,
      feedID: article.feedID,
      title: article.title,
      link: article.link,
      author: article.author,
      publishedAt: article.publishedAt,
      readableSummary: article.readableSummary,
      fetchedAt: article.fetchedAt,
      readAt: article.readAt,
      isStarred: article.isStarred,
      tags: article.tags
    )
  }

  public var isRead: Bool { readAt != nil }

  private static func normalizedReadableSummary(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 1_000 else { return trimmed }
    return String(trimmed.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}

public extension RSSArticle {
  /// Creates a payload-free compatibility value without touching SQLite.
  ///
  /// `summaryHTML` contains the already-sanitized plain-text list summary so
  /// older list-only call sites remain useful while migrating to
  /// `RSSArticleHeader`. `contentHTML` is always empty.
  init(header: RSSArticleHeader) {
    self.init(
      id: header.id,
      feedID: header.feedID,
      title: header.title,
      link: header.link,
      author: header.author,
      publishedAt: header.publishedAt,
      summaryHTML: header.readableSummary,
      contentHTML: "",
      fetchedAt: header.fetchedAt,
      readAt: header.readAt,
      isStarred: header.isStarred,
      tags: header.tags
    )
  }

  mutating func apply(header: RSSArticleHeader) {
    title = header.title
    link = header.link
    author = header.author
    publishedAt = header.publishedAt
    fetchedAt = header.fetchedAt
    readAt = header.readAt
    isStarred = header.isStarred
    tags = header.tags
  }
}

public struct RSSArticleHighlight: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var articleID: String
  public var text: String
  public var note: String
  public var tags: [String]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    articleID: String,
    text: String,
    note: String = "",
    tags: [String] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.articleID = articleID
    self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    self.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    self.tags = RSSArticle.normalizedTags(tags)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RSSMediaAsset: Codable, Hashable, Identifiable, Sendable {
  public let articleID: String
  public let remoteURL: URL
  public let relativePath: String
  public let contentType: String?
  public let byteCount: Int
  public let archivedAt: Date

  public var id: String {
    "\(articleID)|\(remoteURL.absoluteString)"
  }

  public init(
    articleID: String,
    remoteURL: URL,
    relativePath: String,
    contentType: String? = nil,
    byteCount: Int,
    archivedAt: Date = Date()
  ) {
    self.articleID = articleID
    self.remoteURL = remoteURL
    self.relativePath = relativePath
    self.contentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.byteCount = max(0, byteCount)
    self.archivedAt = archivedAt
  }

  public func localURL(in cacheDirectoryURL: URL) -> URL {
    cacheDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
  }
}

public struct RSSArticlePruneSummary: Equatable, Sendable {
  public let removedArticleCount: Int
  public let removedMediaAssetCount: Int
  public let cutoffDate: Date

  public init(
    removedArticleCount: Int = 0,
    removedMediaAssetCount: Int = 0,
    cutoffDate: Date
  ) {
    self.removedArticleCount = max(0, removedArticleCount)
    self.removedMediaAssetCount = max(0, removedMediaAssetCount)
    self.cutoffDate = cutoffDate
  }
}

public enum RSSArticleScope: Hashable, Sendable {
  case all
  case unread
  case starred
  case feed(UUID)
}

public struct RSSRefreshSummary: Equatable, Sendable {
  public var successCount: Int
  public var failureCount: Int
  public var skippedCount: Int

  public init(successCount: Int = 0, failureCount: Int = 0, skippedCount: Int = 0) {
    self.successCount = max(0, successCount)
    self.failureCount = max(0, failureCount)
    self.skippedCount = max(0, skippedCount)
  }

  public var statusText: String {
    if skippedCount > 0 {
      return "刷新完成：成功 \(successCount)、失败 \(failureCount)、暂缓 \(skippedCount)"
    }
    return "刷新完成：成功 \(successCount)、失败 \(failureCount)"
  }
}

public struct RSSParsedArticle: Equatable, Sendable {
  public let id: String
  public var title: String
  public var link: URL?
  public var author: String?
  public var publishedAt: Date?
  public var summaryHTML: String
  public var contentHTML: String

  public init(
    id: String,
    title: String,
    link: URL? = nil,
    author: String? = nil,
    publishedAt: Date? = nil,
    summaryHTML: String = "",
    contentHTML: String = ""
  ) {
    self.id = id
    self.title = title
    self.link = link
    self.author = author
    self.publishedAt = publishedAt
    self.summaryHTML = summaryHTML
    self.contentHTML = contentHTML
  }
}

public struct RSSParsedFeed: Equatable, Sendable {
  public var title: String
  public var siteURL: URL?
  public var iconURL: URL?
  public var articles: [RSSParsedArticle]

  public init(
    title: String,
    siteURL: URL? = nil,
    iconURL: URL? = nil,
    articles: [RSSParsedArticle] = []
  ) {
    self.title = title
    self.siteURL = siteURL
    self.iconURL = iconURL
    self.articles = articles
  }
}

public enum RSSReaderError: Error, Equatable, LocalizedError, Sendable {
  case invalidFeedURL
  case unsupportedFeedURL
  case network(String)
  case invalidHTTPResponse
  case httpStatus(Int)
  case parseFailed(String)
  case emptyFeed
  case invalidOPML(String)
  case noOPMLFeeds
  case persistence(String)
  case issue(RSSFeedIssue)

  public var errorDescription: String? {
    switch self {
    case .invalidFeedURL:
      return "订阅地址无效。"
    case .unsupportedFeedURL:
      return "订阅地址必须使用 http 或 https。"
    case let .network(message):
      return "读取订阅失败：\(message)"
    case .invalidHTTPResponse:
      return "订阅服务器返回了无法识别的响应。"
    case let .httpStatus(statusCode):
      return "订阅服务器返回 HTTP \(statusCode)。"
    case let .parseFailed(message):
      return "订阅内容无法解析：\(message)"
    case .emptyFeed:
      return "订阅中没有可显示的文章。"
    case let .invalidOPML(message):
      return "OPML 文件无法导入：\(message)"
    case .noOPMLFeeds:
      return "OPML 文件中没有找到可导入的 RSS 或 Atom 订阅。"
    case let .persistence(message):
      return "RSS 本地缓存保存失败：\(message)"
    case let .issue(issue):
      return issue.userMessage
    }
  }

  public func asFeedIssue(occurredAt: Date = Date()) -> RSSFeedIssue {
    switch self {
    case .invalidFeedURL:
      return RSSFeedIssue(
        stage: .validation,
        category: .invalidAddress,
        retryStrategy: .requiresAction,
        userMessage: localizedDescription,
        occurredAt: occurredAt
      )
    case .unsupportedFeedURL:
      return RSSFeedIssue(
        stage: .validation,
        category: .unsupportedAddress,
        retryStrategy: .requiresAction,
        userMessage: localizedDescription,
        occurredAt: occurredAt
      )
    case let .network(message):
      return RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: "订阅读取暂时失败，请稍后重试。",
        technicalDetail: message,
        occurredAt: occurredAt
      )
    case .invalidHTTPResponse:
      return RSSFeedIssue(
        stage: .response,
        category: .invalidResponse,
        retryStrategy: .automatic,
        userMessage: localizedDescription,
        occurredAt: occurredAt
      )
    case let .httpStatus(statusCode):
      return RSSFeedIssue.http(statusCode: statusCode, occurredAt: occurredAt)
    case let .parseFailed(message):
      return RSSFeedIssue(
        stage: .parsing,
        category: .invalidContent,
        retryStrategy: .requiresAction,
        userMessage: "订阅内容不是可识别的 RSS 或 Atom。",
        technicalDetail: message,
        occurredAt: occurredAt
      )
    case .emptyFeed:
      return RSSFeedIssue(
        stage: .parsing,
        category: .emptyFeed,
        retryStrategy: .manual,
        userMessage: localizedDescription,
        occurredAt: occurredAt
      )
    case let .invalidOPML(message):
      return RSSFeedIssue(
        stage: .parsing,
        category: .invalidContent,
        retryStrategy: .requiresAction,
        userMessage: localizedDescription,
        technicalDetail: message,
        occurredAt: occurredAt
      )
    case .noOPMLFeeds:
      return RSSFeedIssue(
        stage: .parsing,
        category: .emptyFeed,
        retryStrategy: .requiresAction,
        userMessage: localizedDescription,
        occurredAt: occurredAt
      )
    case let .persistence(message):
      return RSSFeedIssue(
        stage: .persistence,
        category: .storage,
        retryStrategy: .requiresAction,
        userMessage: "RSS 本地缓存暂时无法保存，请检查磁盘空间或文件权限。",
        technicalDetail: message,
        occurredAt: occurredAt
      )
    case let .issue(issue):
      return issue
    }
  }
}

public enum RSSHTMLTextSanitizer {
  public static func plainText(from source: String) -> String {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ""
    }

    let sanitized = source
      .replacingOccurrences(
        of: "<script\\b[\\s\\S]*?</script>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "<style\\b[\\s\\S]*?</style>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "<br\\s*/?>",
        with: "\n",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "</(p|div|li|h[1-6]|blockquote)>",
        with: "\n",
        options: [.regularExpression, .caseInsensitive]
      )

    let plainText: String
    if let attributed = try? NSAttributedString(
      data: Data(sanitized.utf8),
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil
    ) {
      plainText = attributed.string
    } else {
      plainText = sanitized.replacingOccurrences(
        of: "<[^>]+>",
        with: " ",
        options: .regularExpression
      )
    }

    let normalizedLines = plainText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        line
          .split(whereSeparator: { $0 == " " || $0 == "\t" })
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }

    var result: [String] = []
    var emptyLineCount = 0
    for line in normalizedLines {
      if line.isEmpty {
        emptyLineCount += 1
        if emptyLineCount <= 2, !result.isEmpty {
          result.append("")
        }
      } else {
        emptyLineCount = 0
        result.append(line)
      }
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
