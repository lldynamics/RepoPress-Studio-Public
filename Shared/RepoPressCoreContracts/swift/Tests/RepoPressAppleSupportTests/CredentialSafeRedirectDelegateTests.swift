import Foundation
import RepoPressAppleSupport
import XCTest

final class CredentialSafeRedirectDelegateTests: XCTestCase {
  func testCredentialHeadersAllowSameHTTPSOriginAndKeepProposedRequest() throws {
    for header in ["Authorization", "PRIVATE-TOKEN", "X-API-Key"] {
      let original = request("https://gitlab.example/api/v4", header: header)
      var proposed = request("https://GITLAB.example:443/api/v4/projects", header: header)
      proposed.httpMethod = "POST"
      proposed.httpBody = Data("body".utf8)
      XCTAssertEqual(redirect(original, to: proposed), proposed)
    }
  }

  func testCredentialHeadersRejectHostPortDowngradeAndUserInfo() {
    for header in ["Authorization", "private-token", "X-API-Key"] {
      let original = request("https://gitlab.example/api/v4", header: header)
      for destination in [
        "https://collector.example/api", "https://gitlab.example:8443/api",
        "http://gitlab.example/api", "https://user@gitlab.example/api",
        "https://gitlab.example.attacker.test/api",
      ] {
        XCTAssertNil(redirect(original, to: request(destination)), destination)
      }
    }
  }

  func testCredentialsInProposedRequestAlsoRequireSafeOrigin() {
    XCTAssertNil(redirect(
      request("https://gitlab.example/start"),
      to: request("https://collector.example/end", header: "PRIVATE-TOKEN")
    ))
  }

  func testRedirectChainRemainsBoundToOriginalOrigin() {
    let original = request("https://gitlab.example/start", header: "PRIVATE-TOKEN")
    XCTAssertNil(CredentialSafeRedirectDelegate.redirectedRequest(
      originalRequest: original,
      responseURL: URL(string: "https://collector.example/hop"),
      proposedRequest: request("https://collector.example/end")
    ))
  }

  func testSensitiveBodyAndBodyStreamCannotLeaveOrigin() {
    for usesStream in [false, true] {
      var original = request("https://ai.example/chat")
      original.httpMethod = "POST"
      if usesStream {
        original.httpBodyStream = InputStream(data: Data("private article".utf8))
      } else {
        original.httpBody = Data("private article".utf8)
      }
      XCTAssertNil(redirect(original, to: request("https://collector.example/chat")))
      XCTAssertNotNil(redirect(original, to: request("https://ai.example/v2/chat")))
    }
  }

  func testLoopbackBodyWithoutCredentialsRemainsAllowedWithinOrigin() {
    var original = request("http://127.0.0.1:11434/chat")
    original.httpMethod = "POST"
    original.httpBody = Data("article".utf8)
    XCTAssertNotNil(redirect(original, to: request("http://127.0.0.1:11434/v2/chat")))
    XCTAssertNil(redirect(original, to: request("http://127.0.0.1:11435/chat")))
  }

  func testPublicRedirectsRemainAvailable() {
    XCTAssertNotNil(redirect(request("https://example.com/start"), to: request("https://cdn.example.com/end")))
  }

  func testSensitiveRedirectWithoutKnownSourceFailsClosed() {
    XCTAssertNil(CredentialSafeRedirectDelegate.redirectedRequest(
      originalRequest: nil, responseURL: nil,
      proposedRequest: request("https://collector.example/end", header: "PRIVATE-TOKEN")
    ))
  }

  private func request(_ value: String, header: String? = nil) -> URLRequest {
    var request = URLRequest(url: URL(string: value)!)
    if let header { request.setValue("test-only-token", forHTTPHeaderField: header) }
    return request
  }

  private func redirect(_ original: URLRequest, to proposed: URLRequest) -> URLRequest? {
    CredentialSafeRedirectDelegate.redirectedRequest(
      originalRequest: original, responseURL: original.url, proposedRequest: proposed
    )
  }
}
