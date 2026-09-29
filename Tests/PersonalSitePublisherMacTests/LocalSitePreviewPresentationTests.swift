import Foundation
import WebKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class LocalSitePreviewPresentationTests: XCTestCase {
  func testInitialNavigationWaitsForServerAndDoesNotReloadOnUnrelatedUpdates() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: url, onNavigationError: { _ in })

    XCTAssertNil(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 0, isServerReachable: false))
    XCTAssertNil(coordinator.lastLoadedURL)
    XCTAssertEqual(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 0, isServerReachable: true), url)
    // WebKit can still have a nil URL while the requested page is loading.
    XCTAssertNil(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 0, isServerReachable: true))
  }

  func testRefreshRetriesFailedInitialNavigationEvenAfterReadinessTimeout() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: url, onNavigationError: { _ in })

    XCTAssertNil(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 7, isServerReachable: false))
    XCTAssertEqual(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 8, isServerReachable: false), url)
    XCTAssertEqual(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 8, isServerReachable: true), url)
    XCTAssertNil(
      coordinator.requestURL(
        for: url, currentURL: nil, reloadToken: 8, isServerReachable: true))
  }

  func testRefreshPreservesLocalPathButNeverReusesAnotherOrigin() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    let articleURL = url.appendingPathComponent("posts/example")
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: url, onNavigationError: { _ in })
    _ = coordinator.requestURL(
      for: url, currentURL: nil, reloadToken: 0, isServerReachable: true)

    XCTAssertEqual(
      coordinator.requestURL(
        for: url, currentURL: articleURL, reloadToken: 1, isServerReachable: true), articleURL)
    for (index, address) in [
      "about:blank", "https://example.com", "http://127.0.0.1:4322/posts/old",
    ].enumerated() {
      XCTAssertEqual(
        coordinator.requestURL(
          for: url, currentURL: URL(string: address), reloadToken: UInt64(index + 2),
          isServerReachable: true), url)
    }
  }

  func testNewPreviewIdentityWaitsForReadinessAndDiscardsOldPage() throws {
    let oldURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    let newURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4322"))
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: oldURL, onNavigationError: { _ in })
    _ = coordinator.requestURL(
      for: oldURL, currentURL: nil, reloadToken: 2, isServerReachable: true)

    XCTAssertNil(
      coordinator.requestURL(
        for: newURL, currentURL: oldURL, reloadToken: 3, isServerReachable: false))
    XCTAssertEqual(
      coordinator.requestURL(
        for: newURL, currentURL: oldURL, reloadToken: 3, isServerReachable: true), newURL)
  }

  func testNavigationRecoveryClearsErrorsAndIgnoresCancellationAndTeardown() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
    var messages: [String?] = []
    let coordinator = LocalSitePreviewWebView.Coordinator(
      previewURL: url, onNavigationError: { messages.append($0) })
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)

    coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: error)
    XCTAssertEqual(messages.count, 1)
    XCTAssertNotNil(messages[0])
    coordinator.webView(webView, didStartProvisionalNavigation: nil)
    XCTAssertEqual(messages.count, 2)
    XCTAssertNil(messages[1])
    coordinator.webView(webView, didFail: nil, withError: error)
    coordinator.webView(webView, didFinish: nil)
    XCTAssertEqual(messages.count, 4)
    XCTAssertNil(messages[3])
    coordinator.webView(
      webView, didFailProvisionalNavigation: nil,
      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
    XCTAssertEqual(messages.count, 4)
    coordinator.resetForTeardown()
    coordinator.webView(webView, didFail: nil, withError: error)
    coordinator.webView(webView, didFinish: nil)
    XCTAssertEqual(messages.count, 4)
  }

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
