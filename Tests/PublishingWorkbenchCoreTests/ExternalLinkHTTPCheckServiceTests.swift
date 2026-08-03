import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class ExternalLinkHTTPCheckServiceTests: XCTestCase {
  func testReachableLinkUsesHEADAndReturnsStatus() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/article"))
    let transport = ExternalLinkTransportStub(responses: [
      .init(url: url, statusCode: 204),
    ])
    let service = makeService(transport: transport)

    let result = await service.check(url)

    XCTAssertEqual(result.state, .reachable)
    XCTAssertEqual(result.statusCode, 204)
    XCTAssertTrue(result.isHealthy)
    let requests = await transport.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["HEAD"])
  }

  func testFollowsValidatedRedirectAndPreservesChain() async throws {
    let source = try XCTUnwrap(URL(string: "https://example.com/old"))
    let destination = try XCTUnwrap(URL(string: "https://www.example.com/new"))
    let transport = ExternalLinkTransportStub(responses: [
      .init(url: source, statusCode: 301, headers: ["Location": destination.absoluteString]),
      .init(url: destination, statusCode: 200),
    ])
    let service = makeService(transport: transport)

    let result = await service.check(source)

    XCTAssertEqual(result.state, .redirected)
    XCTAssertEqual(result.finalURL, destination)
    XCTAssertEqual(result.redirectChain, [destination])
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 2)
  }

  func testFallsBackToBoundedGETWhenHEADIsUnsupported() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/headless"))
    let transport = ExternalLinkTransportStub(responses: [
      .init(url: url, statusCode: 405),
      .init(url: url, statusCode: 206),
    ])
    let service = makeService(transport: transport)

    let result = await service.check(url)

    XCTAssertEqual(result.state, .reachable)
    let requests = await transport.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["HEAD", "GET"])
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
  }

  func testBlocksPrivateAddressBeforeNetworkRequest() async throws {
    let url = try XCTUnwrap(URL(string: "https://private.example/status"))
    let transport = ExternalLinkTransportStub(responses: [])
    let service = ExternalLinkHTTPCheckService(
      transport: transport,
      resolver: { _ in [.ipv4([192, 168, 1, 20])] }
    )

    let result = await service.check(url)

    XCTAssertEqual(result.state, .blocked)
    XCTAssertTrue(result.message.contains("已阻止"))
    let requests = await transport.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAllowsCommonPacketTunnelFakeIPAddressRange() async throws {
    let url = try XCTUnwrap(URL(string: "https://proxied.example/status"))
    let transport = ExternalLinkTransportStub(responses: [
      .init(url: url, statusCode: 200),
    ])
    let service = ExternalLinkHTTPCheckService(
      transport: transport,
      resolver: { _ in [.ipv4([198, 18, 0, 42])] }
    )

    let result = await service.check(url)

    XCTAssertEqual(result.state, .reachable)
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 1)
  }

  func testBatchDeduplicatesURLsAndKeepsInputOrder() async throws {
    let first = try XCTUnwrap(URL(string: "https://a.example/page"))
    let second = try XCTUnwrap(URL(string: "https://b.example/page"))
    let transport = ExternalLinkTransportStub(responses: [
      .init(url: first, statusCode: 200),
      .init(url: second, statusCode: 404),
    ])
    let service = makeService(transport: transport)

    let results = await service.check([first, first, second], maximumConcurrentChecks: 1)

    XCTAssertEqual(results.map(\.requestedURL), [first, second])
    XCTAssertEqual(results.map(\.state), [.reachable, .clientError])
  }

  private func makeService(
    transport: ExternalLinkHTTPTransport
  ) -> ExternalLinkHTTPCheckService {
    ExternalLinkHTTPCheckService(
      transport: transport,
      resolver: { _ in [.ipv4([93, 184, 216, 34])] }
    )
  }
}

private struct ExternalLinkStubResponse: Sendable {
  var url: URL
  var statusCode: Int
  var headers: [String: String] = [:]
  var data = Data()
}

private enum ExternalLinkTransportStubError: Error {
  case missingResponse
  case invalidHTTPResponse
}

private actor ExternalLinkTransportStub: ExternalLinkHTTPTransport {
  private var pendingResponses: [ExternalLinkStubResponse]
  private var capturedRequests: [URLRequest] = []

  init(responses: [ExternalLinkStubResponse]) {
    pendingResponses = responses
  }

  func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    capturedRequests.append(request)
    guard !pendingResponses.isEmpty else {
      throw ExternalLinkTransportStubError.missingResponse
    }
    let stub = pendingResponses.removeFirst()
    guard let response = HTTPURLResponse(
      url: stub.url,
      statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: stub.headers
    ) else {
      throw ExternalLinkTransportStubError.invalidHTTPResponse
    }
    return (stub.data, response)
  }

  func requests() -> [URLRequest] {
    capturedRequests
  }
}
