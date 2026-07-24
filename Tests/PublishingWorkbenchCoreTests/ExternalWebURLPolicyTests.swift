import XCTest
@testable import PublishingWorkbenchCore

final class ExternalWebURLPolicyTests: XCTestCase {
  func testAllowsHTTPSAndLoopbackHTTPWebURLs() throws {
    let httpsURL = try XCTUnwrap(URL(string: "https://github.com/owner/site/pulls?q=is%3Aopen#reviews"))
    let localPreviewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4321/posts/preview"))
    let localIPv6PreviewURL = try XCTUnwrap(URL(string: "http://[::1]:4321/posts/preview"))

    XCTAssertEqual(ExternalWebURLPolicy.validatedURL(httpsURL), httpsURL)
    XCTAssertEqual(ExternalWebURLPolicy.validatedURL(localPreviewURL), localPreviewURL)
    XCTAssertEqual(ExternalWebURLPolicy.validatedURL(localIPv6PreviewURL), localIPv6PreviewURL)
  }

  func testRejectsFilesCustomSchemesMissingHostsAndUserInfo() throws {
    let candidates = [
      URL(fileURLWithPath: "/private/tmp/private.txt"),
      try XCTUnwrap(URL(string: "javascript:alert(1)")),
      try XCTUnwrap(URL(string: "custom-app://open/private")),
      try XCTUnwrap(URL(string: "https:///missing-host")),
      try XCTUnwrap(URL(string: "https://user:secret@example.com/private")),
      try XCTUnwrap(URL(string: "http://192.0.2.10/private")),
      try XCTUnwrap(URL(string: "http://preview.internal.example/private")),
      try XCTUnwrap(URL(string: "http://localhost.example/private")),
    ]

    for url in candidates {
      XCTAssertNil(ExternalWebURLPolicy.validatedURL(url), "Expected rejection for \(url)")
    }
  }
}
