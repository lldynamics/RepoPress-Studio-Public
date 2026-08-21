import Foundation
import BrowserExtensionProtocolSupport
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeBrowserBridgeRequestSecurityTests: XCTestCase {
  func testContentLengthOverflowAndMalformedValuesAreRejectedBeforeBodyRead() {
    let values = [
      String(Int.max),
      String(Int.max - 1),
      String(BrowserExtensionProtocol.maximumInputBytes),
      String(BrowserExtensionProtocol.maximumInputBytes + 1),
      "-1",
      "+1",
      "1.0",
      ""
    ]

    for value in values {
      let request = makeRequest(headers: ["Content-Length: " + value])
      guard case .invalid = BrowserBridgeRequestHeaders.parseState(for: request) else {
        return XCTFail("Content-Length " + value.debugDescription + " should be rejected")
      }
    }
  }

  func testDuplicateContentLengthHeadersAreRejectedCaseInsensitively() {
    let request = makeRequest(headers: [
      "Content-Length: 3",
      "content-length: 3"
    ])

    guard case .invalid = BrowserBridgeRequestHeaders.parseState(for: request) else {
      return XCTFail("duplicate Content-Length headers must be rejected")
    }
  }

  func testLargeUnauthorizedRequestIsRepresentedByHeadersOnly() throws {
    let request = makeRequest(
      method: "POST",
      path: "/v1/import",
      headers: [
        "Content-Length: 50300000",
        "X-RepoPress-Protocol: 1",
        "Origin: https://attacker.invalid"
      ]
    )

    guard case .complete(let headers) = BrowserBridgeRequestHeaders.parseState(for: request) else {
      return XCTFail("the header itself should be parsed without reading the body")
    }
    XCTAssertEqual(headers.contentLength, 50_300_000)
    XCTAssertFalse(headers.isLoopbackBridgeRequest)
    XCTAssertEqual(headers.headerLength, request.count)
  }

  func testValidAuthorizedSizedRequestHeaderRemainsAccepted() throws {
    let request = makeRequest(
      method: "POST",
      path: "/v1/open",
      headers: [
        "Content-Length: 3",
        "Authorization: Bearer test-token",
        "X-RepoPress-Protocol: 1",
        "Origin: chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam"
      ]
    )

    guard case .complete(let headers) = BrowserBridgeRequestHeaders.parseState(for: request) else {
      return XCTFail("valid request headers should remain accepted")
    }
    XCTAssertEqual(headers.contentLength, 3)
    XCTAssertEqual(headers.bearerToken, "test-token")
    XCTAssertTrue(headers.isLoopbackBridgeRequest)
  }

  func testConnectionBudgetCapsConcurrencyAndReleasesReservedBytes() throws {
    let budget = BrowserBridgeConnectionBudget(
      maximumConnections: 2,
      maximumBufferedBytes: 10
    )
    let first = try XCTUnwrap(budget.acquire())
    let second = try XCTUnwrap(budget.acquire())
    XCTAssertNil(budget.acquire())
    XCTAssertTrue(first.reserve(8))
    XCTAssertFalse(second.reserve(3))
    XCTAssertEqual(budget.activeConnectionCount, 2)
    XCTAssertEqual(budget.reservedByteCount, 8)

    first.release()
    XCTAssertEqual(budget.activeConnectionCount, 1)
    XCTAssertEqual(budget.reservedByteCount, 0)
    XCTAssertTrue(second.reserve(10))

    second.release()
    XCTAssertEqual(budget.activeConnectionCount, 0)
    XCTAssertEqual(budget.reservedByteCount, 0)
  }

  private func makeRequest(
    method: String = "GET",
    path: String = "/v1/status",
    headers: [String]
  ) -> Data {
    var lines = ["\(method) \(path) HTTP/1.1"]
    lines.append(contentsOf: headers)
    lines.append("")
    lines.append("")
    return Data(lines.joined(separator: "\r\n").utf8)
  }
}
