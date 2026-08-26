import XCTest
@testable import PersonalSitePublisherMac

@MainActor
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

  func testNavigationPolicyAllowsAboutBlankWithoutAnActivePreview() throws {
    XCTAssertTrue(
      LocalSitePreviewNavigationPolicy.isAllowedNavigationURL(
        try XCTUnwrap(URL(string: "about:blank")),
        matching: nil
      )
    )
    XCTAssertFalse(
      LocalSitePreviewNavigationPolicy.isAllowedNavigationURL(
        try XCTUnwrap(URL(string: "https://example.com/post")),
        matching: nil
      )
    )
  }

  func testTeardownPerformsEveryReleaseOperationInOrder() {
    var operations: [String] = []

    let state = LocalSitePreviewWebView.Teardown.perform(
      stopLoading: { operations.append("stopLoading") },
      navigateToBlank: { operations.append("about:blank") },
      removeUserScripts: { operations.append("removeUserScripts") },
      detachNavigationDelegate: { operations.append("detachNavigationDelegate") },
      resetCoordinator: { operations.append("resetCoordinator") }
    )

    XCTAssertEqual(
      operations,
      [
        "stopLoading",
        "about:blank",
        "removeUserScripts",
        "detachNavigationDelegate",
        "resetCoordinator",
      ]
    )
    XCTAssertTrue(state.isComplete)
  }

  func testCoordinatorTeardownClearsPreviewIdentity() throws {
    let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: previewURL,
      onNavigationError: { _ in }
    )
    coordinator.lastLoadedURL = previewURL
    coordinator.lastReloadToken = 42

    coordinator.resetForTeardown()

    XCTAssertNil(coordinator.lastLoadedURL)
    XCTAssertNil(coordinator.lastReloadToken)
    XCTAssertNil(coordinator.previewURL)
  }
}
