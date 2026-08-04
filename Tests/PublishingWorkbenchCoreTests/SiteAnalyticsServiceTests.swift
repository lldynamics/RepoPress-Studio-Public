import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class SiteAnalyticsServiceTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_767_225_600)
  private let end = Date(timeIntervalSince1970: 1_767_312_000)
  private let fetchedAt = Date(timeIntervalSince1970: 1_767_355_200)

  func testPlausibleUsesStatsV2ReadOnlyQueryAndParsesSummary() async throws {
    let transport = AnalyticsTransportStub(responses: [
      .json(#"{"results":[{"metrics":[120,150,300,42.5,88]}]}"#),
    ])
    let fetchedAt = self.fetchedAt
    let service = SiteAnalyticsService(transport: transport, now: { fetchedAt })

    let summary = try await service.fetchSummary(
      configuration: .plausible(
        baseURL: try XCTUnwrap(URL(string: "https://plausible.example")),
        siteID: "blog.example.com"
      ),
      accessToken: "plausible-token",
      dateRange: .init(start: start, end: end)
    )

    XCTAssertEqual(summary.pageviews, 300)
    XCTAssertEqual(summary.visitors, 120)
    XCTAssertEqual(summary.visits, 150)
    XCTAssertEqual(summary.bounceRate, 42.5)
    XCTAssertEqual(summary.totalVisitDurationSeconds, 88)
    XCTAssertEqual(summary.fetchedAt, fetchedAt)

    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/api/v2/query")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer plausible-token")
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["site_id"] as? String, "blog.example.com")
    XCTAssertEqual(
      payload["metrics"] as? [String],
      ["visitors", "visits", "pageviews", "bounce_rate", "visit_duration"]
    )
  }

  func testPlausiblePageScopeAddsAnExactArticlePathFilter() async throws {
    let transport = AnalyticsTransportStub(responses: [
      .json(#"{"results":[{"metrics":[12,15,30,20,88]}]}"#),
    ])
    let fetchedAt = self.fetchedAt
    let service = SiteAnalyticsService(transport: transport, now: { fetchedAt })
    let pagePath = "/2026/08/publish-loop/"

    let summary = try await service.fetchSummary(
      configuration: .plausible(
        baseURL: try XCTUnwrap(URL(string: "https://plausible.example")),
        siteID: "blog.example.com"
      ),
      accessToken: "plausible-token",
      dateRange: .init(start: start, end: end),
      pagePath: pagePath
    )

    XCTAssertEqual(summary.pagePath, pagePath)
    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let filters = try XCTUnwrap(payload["filters"] as? [[Any]])
    let filter = try XCTUnwrap(filters.first)
    XCTAssertEqual(filter[0] as? String, "is")
    XCTAssertEqual(filter[1] as? String, "event:page")
    XCTAssertEqual((filter[2] as? [String])?.first, pagePath)
  }

  func testUmamiUsesWebsiteStatsGETAndParsesSummary() async throws {
    let transport = AnalyticsTransportStub(responses: [
      .json(#"{"pageviews":{"value":300},"visitors":{"value":120},"visits":{"value":150},"bounces":{"value":20},"totaltime":{"value":9000}}"#),
    ])
    let fetchedAt = self.fetchedAt
    let service = SiteAnalyticsService(transport: transport, now: { fetchedAt })

    let summary = try await service.fetchSummary(
      configuration: .umami(
        baseURL: try XCTUnwrap(URL(string: "https://api.umami.is")),
        websiteID: "website-123"
      ),
      accessToken: "umami-token",
      dateRange: .init(start: start, end: end)
    )

    XCTAssertEqual(summary.pageviews, 300)
    XCTAssertEqual(summary.visitors, 120)
    XCTAssertEqual(summary.visits, 150)
    XCTAssertEqual(summary.bounces, 20)
    XCTAssertEqual(summary.totalVisitDurationSeconds, 9_000)

    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/api/websites/website-123/stats")
    let queryItems = URLComponents(
      url: try XCTUnwrap(request.url),
      resolvingAgainstBaseURL: false
    )?.queryItems
    XCTAssertTrue(queryItems?.contains(URLQueryItem(name: "startAt", value: "1767225600000")) == true)
    XCTAssertTrue(queryItems?.contains(URLQueryItem(name: "endAt", value: "1767312000000")) == true)
  }

  func testUmamiPageScopeAddsArticleURLQuery() async throws {
    let transport = AnalyticsTransportStub(responses: [
      .json(#"{"pageviews":{"value":3},"visitors":{"value":2},"visits":{"value":2},"bounces":{"value":1},"totaltime":{"value":90}}"#),
    ])
    let fetchedAt = self.fetchedAt
    let service = SiteAnalyticsService(transport: transport, now: { fetchedAt })
    let pagePath = "/2026/08/publish-loop/"

    _ = try await service.fetchSummary(
      configuration: .umami(
        baseURL: try XCTUnwrap(URL(string: "https://api.umami.is")),
        websiteID: "website-123"
      ),
      accessToken: "umami-token",
      dateRange: .init(start: start, end: end),
      pagePath: pagePath
    )

    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    let queryItems = URLComponents(
      url: try XCTUnwrap(request.url),
      resolvingAgainstBaseURL: false
    )?.queryItems
    XCTAssertTrue(queryItems?.contains(URLQueryItem(name: "url", value: pagePath)) == true)
  }

  func testCloudflareUsesReadOnlyGraphQLAnalyticsQuery() async throws {
    let transport = AnalyticsTransportStub(responses: [
      .json(#"{"data":{"viewer":{"zones":[{"groups":[{"count":450,"sum":{"visits":180}}]}]}}}"#),
    ])
    let fetchedAt = self.fetchedAt
    let service = SiteAnalyticsService(transport: transport, now: { fetchedAt })

    let summary = try await service.fetchSummary(
      configuration: .cloudflare(zoneID: "zone-123"),
      accessToken: "cloudflare-token",
      dateRange: .init(start: start, end: end)
    )

    XCTAssertEqual(summary.requests, 450)
    XCTAssertEqual(summary.visits, 180)
    XCTAssertNil(summary.pageviews)

    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/graphql")
    XCTAssertEqual(request.httpMethod, "POST")
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let query = try XCTUnwrap(payload["query"] as? String)
    XCTAssertTrue(query.contains("httpRequestsAdaptiveGroups"))
    XCTAssertFalse(query.lowercased().contains("mutation"))
    let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
    XCTAssertEqual(variables["zoneTag"] as? String, "zone-123")
  }

  func testRejectsInsecureCredentialedEndpointBeforeSendingToken() async throws {
    let transport = AnalyticsTransportStub(responses: [])
    let service = SiteAnalyticsService(transport: transport)

    do {
      _ = try await service.fetchSummary(
        configuration: .plausible(
          baseURL: try XCTUnwrap(URL(string: "http://plausible.example")),
          siteID: "blog.example.com"
        ),
        accessToken: "secret-token",
        dateRange: .init(start: start, end: end)
      )
      XCTFail("Expected insecure endpoint to be rejected")
    } catch let error as SiteAnalyticsError {
      XCTAssertEqual(error, .insecureEndpoint)
    }
    let requests = await transport.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testSiteAnalyticsSettingsDoNotPersistAccessTokenAndClampRange() throws {
    let settings = SiteAnalyticsSettings(
      isEnabled: true,
      provider: .plausible,
      baseURL: "https://plausible.example",
      siteID: "blog.example.com",
      dateRangeDays: 999
    )

    XCTAssertEqual(settings.normalizedDateRangeDays, 90)
    guard case .plausible(let baseURL, let siteID) = settings.configuration else {
      return XCTFail("Expected a valid Plausible configuration")
    }
    XCTAssertEqual(baseURL.absoluteString, "https://plausible.example")
    XCTAssertEqual(siteID, "blog.example.com")

    let encoded = try JSONEncoder().encode(settings)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("secret"))
  }
}

private struct AnalyticsStubResponse: Sendable {
  var statusCode: Int
  var data: Data

  static func json(_ text: String, statusCode: Int = 200) -> Self {
    .init(statusCode: statusCode, data: Data(text.utf8))
  }
}

private enum AnalyticsTransportStubError: Error {
  case missingResponse
  case invalidURL
  case invalidHTTPResponse
}

private actor AnalyticsTransportStub: SiteOperationsHTTPTransport {
  private var pendingResponses: [AnalyticsStubResponse]
  private var capturedRequests: [URLRequest] = []

  init(responses: [AnalyticsStubResponse]) {
    pendingResponses = responses
  }

  func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    capturedRequests.append(request)
    guard !pendingResponses.isEmpty else {
      throw AnalyticsTransportStubError.missingResponse
    }
    let stub = pendingResponses.removeFirst()
    guard let url = request.url else { throw AnalyticsTransportStubError.invalidURL }
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    ) else {
      throw AnalyticsTransportStubError.invalidHTTPResponse
    }
    return (stub.data, response)
  }

  func requests() -> [URLRequest] {
    capturedRequests
  }
}
