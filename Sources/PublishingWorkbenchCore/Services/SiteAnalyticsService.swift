import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SiteAnalyticsProvider: String, Codable, CaseIterable, Hashable, Sendable {
  case plausible
  case umami
  case cloudflare

  public var displayName: String {
    switch self {
    case .plausible:
      return "Plausible"
    case .umami:
      return "Umami"
    case .cloudflare:
      return "Cloudflare Analytics"
    }
  }
}

public enum SiteAnalyticsConfiguration: Hashable, Sendable {
  case plausible(baseURL: URL, siteID: String)
  case umami(baseURL: URL, websiteID: String)
  case cloudflare(zoneID: String)

  public var provider: SiteAnalyticsProvider {
    switch self {
    case .plausible: return .plausible
    case .umami: return .umami
    case .cloudflare: return .cloudflare
    }
  }
}

public struct SiteAnalyticsDateRange: Codable, Hashable, Sendable {
  public var start: Date
  public var end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

public struct SiteAnalyticsSummary: Codable, Hashable, Sendable {
  public var provider: SiteAnalyticsProvider
  public var dateRange: SiteAnalyticsDateRange
  /// The article path used for a page-scoped query. Nil means site aggregate.
  public var pagePath: String?
  public var pageviews: Int?
  public var visitors: Int?
  public var visits: Int?
  public var bounces: Int?
  public var bounceRate: Double?
  public var totalVisitDurationSeconds: Int?
  public var requests: Int?
  public var fetchedAt: Date

  public init(
    provider: SiteAnalyticsProvider,
    dateRange: SiteAnalyticsDateRange,
    pagePath: String? = nil,
    pageviews: Int? = nil,
    visitors: Int? = nil,
    visits: Int? = nil,
    bounces: Int? = nil,
    bounceRate: Double? = nil,
    totalVisitDurationSeconds: Int? = nil,
    requests: Int? = nil,
    fetchedAt: Date = Date()
  ) {
    self.provider = provider
    self.dateRange = dateRange
    self.pagePath = pagePath
    self.pageviews = pageviews
    self.visitors = visitors
    self.visits = visits
    self.bounces = bounces
    self.bounceRate = bounceRate
    self.totalVisitDurationSeconds = totalVisitDurationSeconds
    self.requests = requests
    self.fetchedAt = fetchedAt
  }
}

public enum SiteAnalyticsError: LocalizedError, Hashable, Sendable {
  case invalidDateRange
  case invalidConfiguration(String)
  case insecureEndpoint
  case invalidResponse
  case httpStatus(Int)
  case providerError(String)

  public var errorDescription: String? {
    switch self {
    case .invalidDateRange:
      return "统计开始时间必须早于结束时间，且查询跨度不能超过 366 天。"
    case .invalidConfiguration(let message):
      return message
    case .insecureEndpoint:
      return "统计接口携带访问令牌，只允许使用不含账号信息的 HTTPS 地址。"
    case .invalidResponse:
      return "统计服务返回了无法识别的数据。"
    case .httpStatus(let statusCode):
      return "统计服务返回 HTTP \(statusCode)。"
    case .providerError(let message):
      return "统计服务返回错误：\(message)"
    }
  }
}

public struct SiteAnalyticsService: Sendable {
  static let maximumResponseByteCount = 2 * 1_024 * 1_024

  private let transport: SiteOperationsHTTPTransport
  private let now: @Sendable () -> Date

  public init(
    transport: SiteOperationsHTTPTransport = URLSessionSiteOperationsHTTPTransport()
  ) {
    self.transport = transport
    self.now = { Date() }
  }

  init(
    transport: SiteOperationsHTTPTransport,
    now: @escaping @Sendable () -> Date
  ) {
    self.transport = transport
    self.now = now
  }

  /// Fetches read-only statistics. When pagePath is supplied, providers are
  /// asked for that article path instead of the whole-site aggregate.
  public func fetchSummary(
    configuration: SiteAnalyticsConfiguration,
    accessToken: String,
    dateRange: SiteAnalyticsDateRange,
    pagePath: String? = nil
  ) async throws -> SiteAnalyticsSummary {
    try validate(dateRange)
    let normalizedPagePath = try normalizedPagePath(pagePath)
    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw SiteAnalyticsError.invalidConfiguration("请输入只读统计访问令牌。")
    }

    switch configuration {
    case .plausible(let baseURL, let siteID):
      return try await fetchPlausible(
        baseURL: baseURL,
        siteID: siteID,
        token: token,
        dateRange: dateRange,
        pagePath: normalizedPagePath
      )
    case .umami(let baseURL, let websiteID):
      return try await fetchUmami(
        baseURL: baseURL,
        websiteID: websiteID,
        token: token,
        dateRange: dateRange,
        pagePath: normalizedPagePath
      )
    case .cloudflare(let zoneID):
      return try await fetchCloudflare(
        zoneID: zoneID,
        token: token,
        dateRange: dateRange,
        pagePath: normalizedPagePath
      )
    }
  }

  private func fetchPlausible(
    baseURL: URL,
    siteID: String,
    token: String,
    dateRange: SiteAnalyticsDateRange,
    pagePath: String?
  ) async throws -> SiteAnalyticsSummary {
    let normalizedSiteID = try requiredIdentifier(siteID, name: "Plausible Site ID")
    let endpoint = try secureEndpoint(baseURL)
      .appendingPathComponent("api/v2/query")
    let payload = PlausibleQuery(
      siteID: normalizedSiteID,
      metrics: ["visitors", "visits", "pageviews", "bounce_rate", "visit_duration"],
      dateRange: [Self.dayString(dateRange.start), Self.dayString(dateRange.end)],
      filters: pagePath.map {
        [PlausibleFilter(operatorName: "is", property: "event:page", values: [$0])]
      }
    )
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(payload)

    let data = try await responseData(for: request)
    let response = try JSONDecoder().decode(PlausibleResponse.self, from: data)
    guard let metrics = response.results.first?.metrics, metrics.count >= 5 else {
      throw SiteAnalyticsError.invalidResponse
    }
    return SiteAnalyticsSummary(
      provider: .plausible,
      dateRange: dateRange,
      pagePath: pagePath,
      pageviews: Self.integer(metrics[2]),
      visitors: Self.integer(metrics[0]),
      visits: Self.integer(metrics[1]),
      bounceRate: metrics[3],
      totalVisitDurationSeconds: Self.integer(metrics[4]),
      fetchedAt: now()
    )
  }

  private func fetchUmami(
    baseURL: URL,
    websiteID: String,
    token: String,
    dateRange: SiteAnalyticsDateRange,
    pagePath: String?
  ) async throws -> SiteAnalyticsSummary {
    let normalizedWebsiteID = try requiredIdentifier(websiteID, name: "Umami Website ID")
    let base = try secureEndpoint(baseURL)
    var components = URLComponents(
      url: base.appendingPathComponent("api/websites/\(normalizedWebsiteID)/stats"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "startAt", value: String(Self.milliseconds(dateRange.start))),
      URLQueryItem(name: "endAt", value: String(Self.milliseconds(dateRange.end))),
    ]
    if let pagePath {
      components?.queryItems?.append(URLQueryItem(name: "url", value: pagePath))
    }
    guard let endpoint = components?.url else {
      throw SiteAnalyticsError.invalidConfiguration("Umami 接口地址无效。")
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data = try await responseData(for: request)
    let response = try JSONDecoder().decode(UmamiStatsResponse.self, from: data)
    return SiteAnalyticsSummary(
      provider: .umami,
      dateRange: dateRange,
      pagePath: pagePath,
      pageviews: Self.integer(response.pageviews.value),
      visitors: Self.integer(response.visitors.value),
      visits: Self.integer(response.visits.value),
      bounces: Self.integer(response.bounces.value),
      totalVisitDurationSeconds: Self.integer(response.totalTime.value),
      fetchedAt: now()
    )
  }

  private func fetchCloudflare(
    zoneID: String,
    token: String,
    dateRange: SiteAnalyticsDateRange,
    pagePath: String?
  ) async throws -> SiteAnalyticsSummary {
    let normalizedZoneID = try requiredIdentifier(zoneID, name: "Cloudflare Zone ID")
    guard let endpoint = URL(string: "https://api.cloudflare.com/client/v4/graphql") else {
      throw SiteAnalyticsError.invalidConfiguration("Cloudflare GraphQL 地址无效。")
    }
    let payload = CloudflareQuery(
      query: pagePath == nil
        ? Self.cloudflareAggregateReadOnlyQuery
        : Self.cloudflarePathReadOnlyQuery,
      variables: CloudflareVariables(
        zoneTag: normalizedZoneID,
        start: Self.timestamp(dateRange.start),
        end: Self.timestamp(dateRange.end),
        path: pagePath
      )
    )
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(payload)

    let data = try await responseData(for: request)
    let response = try JSONDecoder().decode(CloudflareResponse.self, from: data)
    if let message = response.errors?.first?.message {
      throw SiteAnalyticsError.providerError(message)
    }
    guard let group = response.data?.viewer.zones.first?.groups.first else {
      throw SiteAnalyticsError.invalidResponse
    }
    return SiteAnalyticsSummary(
      provider: .cloudflare,
      dateRange: dateRange,
      pagePath: pagePath,
      visits: Self.integer(group.sum.visits),
      requests: Self.integer(group.count),
      fetchedAt: now()
    )
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    let (data, response) = try await transport.data(
      for: request,
      maximumByteCount: Self.maximumResponseByteCount
    )
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SiteAnalyticsError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SiteAnalyticsError.httpStatus(httpResponse.statusCode)
    }
    return data
  }

  private func validate(_ range: SiteAnalyticsDateRange) throws {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0, duration <= 366 * 24 * 60 * 60 else {
      throw SiteAnalyticsError.invalidDateRange
    }
  }

  private func normalizedPagePath(_ rawValue: String?) throws -> String? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 2_048, value.hasPrefix("/"),
          !value.contains("\n"), !value.contains("\r") else {
      throw SiteAnalyticsError.invalidConfiguration("文章统计路径无效。")
    }
    return value
  }

  private func requiredIdentifier(_ rawValue: String, name: String) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 256, !value.contains("/") else {
      throw SiteAnalyticsError.invalidConfiguration("\(name) 无效。")
    }
    return value
  }

  private func secureEndpoint(_ url: URL) throws -> URL {
    guard CredentialedEndpointPolicy.isSecureAPIBaseURL(url) else {
      throw SiteAnalyticsError.insecureEndpoint
    }
    return url
  }

  private static func integer(_ value: Double) -> Int {
    Int(value.rounded())
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private static func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  private static let cloudflareAggregateReadOnlyQuery = """
  query RepoPressSiteAnalytics($zoneTag: string, $start: Time, $end: Time) {
    viewer {
      zones(filter: {zoneTag: $zoneTag}) {
        groups: httpRequestsAdaptiveGroups(
          limit: 1
          filter: {datetime_geq: $start, datetime_lt: $end, requestSource: "eyeball"}
        ) {
          count
          sum { visits }
        }
      }
    }
  }
  """

  private static let cloudflarePathReadOnlyQuery = """
  query RepoPressSiteAnalytics($zoneTag: string, $start: Time, $end: Time, $path: string) {
    viewer {
      zones(filter: {zoneTag: $zoneTag}) {
        groups: httpRequestsAdaptiveGroups(
          limit: 1
          filter: {datetime_geq: $start, datetime_lt: $end, requestSource: "eyeball", clientRequestPath: $path}
        ) {
          count
          sum { visits }
        }
      }
    }
  }
  """
}

private struct PlausibleQuery: Encodable {
  var siteID: String
  var metrics: [String]
  var dateRange: [String]
  var filters: [PlausibleFilter]?

  enum CodingKeys: String, CodingKey {
    case siteID = "site_id"
    case metrics
    case dateRange = "date_range"
    case filters
  }
}

private struct PlausibleFilter: Encodable {
  var operatorName: String
  var property: String
  var values: [String]

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(operatorName)
    try container.encode(property)
    try container.encode(values)
  }
}

private struct PlausibleResponse: Decodable {
  struct Result: Decodable {
    var metrics: [Double]
  }
  var results: [Result]
}

private struct UmamiStatsResponse: Decodable {
  struct Metric: Decodable {
    var value: Double
  }

  var pageviews: Metric
  var visitors: Metric
  var visits: Metric
  var bounces: Metric
  var totalTime: Metric

  enum CodingKeys: String, CodingKey {
    case pageviews
    case visitors
    case visits
    case bounces
    case totalTime = "totaltime"
  }
}

private struct CloudflareQuery: Encodable {
  var query: String
  var variables: CloudflareVariables
}

private struct CloudflareVariables: Encodable {
  var zoneTag: String
  var start: String
  var end: String
  var path: String?

  enum CodingKeys: String, CodingKey {
    case zoneTag
    case start
    case end
    case path
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(zoneTag, forKey: .zoneTag)
    try container.encode(start, forKey: .start)
    try container.encode(end, forKey: .end)
    try container.encodeIfPresent(path, forKey: .path)
  }
}

private struct CloudflareResponse: Decodable {
  struct ErrorMessage: Decodable {
    var message: String
  }
  struct Payload: Decodable {
    var viewer: Viewer
  }
  struct Viewer: Decodable {
    var zones: [Zone]
  }
  struct Zone: Decodable {
    var groups: [Group]
  }
  struct Group: Decodable {
    struct Sum: Decodable {
      var visits: Double
    }
    var count: Double
    var sum: Sum
  }

  var data: Payload?
  var errors: [ErrorMessage]?
}
