import XCTest
@testable import PublishingWorkbenchCore

final class CredentialSafeURLSessionTests: XCTestCase {
  func testCredentialRedirectAllowsSameHTTPSOrigin() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v1/chat")))
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v2/chat")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testCredentialRedirectRejectsDifferentHostPortAndHTTPSDowngrade() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v1/chat")))
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let destinations = [
      "https://other.example/v1/chat",
      "https://api.example.com:8443/v1/chat",
      "http://api.example.com/v1/chat",
    ]

    for value in destinations {
      let proposed = URLRequest(url: try XCTUnwrap(URL(string: value)))
      XCTAssertNil(
        CredentialSafeURLSessionDelegate.redirectedRequest(
          originalRequest: original,
          responseURL: original.url,
          proposedRequest: proposed
        ),
        "Expected credential redirect rejection for \(value)"
      )
    }
  }

  func testPublicRedirectRemainsAvailableWithoutCredentialHeaders() throws {
    let original = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/start")))
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.net/result")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testPrivateRequestBodyCannotRedirectToAnotherOriginWithoutAPIKey() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://ai.example.com/v1/chat")))
    original.httpMethod = "POST"
    original.httpBody = Data("private article body".utf8)
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://collector.example.net/chat")))

    XCTAssertNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testLoopbackPrivateRequestBodyCanRedirectWithinSameOrigin() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/chat")))
    original.httpMethod = "POST"
    original.httpBody = Data("local private article body".utf8)
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v2/chat")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }
}
