import XCTest
@testable import PersonalSitePublisherMac

final class LocalSitePreviewPresentationTests: XCTestCase {
  func testNavigationPolicyAllowsOnlyTheCurrentLoopbackPort() throws {
    let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))

    XCTAssertTrue(
      LocalSitePreviewNavigationPolicy.isAllowedLoopbackURL(
        try XCTUnwrap(URL(string: "http://127.0.0.1:4321/post")),
        matching: previewURL
      )
    )
    XCTAssertTrue(
      LocalSitePreviewNavigationPolicy.isAllowedLoopbackURL(
        try XCTUnwrap(URL(string: "http://localhost:4321/post")),
        matching: previewURL
      )
    )
    XCTAssertFalse(
      LocalSitePreviewNavigationPolicy.isAllowedLoopbackURL(
        try XCTUnwrap(URL(string: "http://127.0.0.1:4322/post")),
        matching: previewURL
      )
    )
    XCTAssertFalse(
      LocalSitePreviewNavigationPolicy.isAllowedLoopbackURL(
        try XCTUnwrap(URL(string: "https://example.com/post")),
        matching: previewURL
      )
    )
  }
}
