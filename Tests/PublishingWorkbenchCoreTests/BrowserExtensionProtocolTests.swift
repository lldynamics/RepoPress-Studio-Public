import BrowserExtensionProtocolSupport
import XCTest

final class BrowserExtensionProtocolTests: XCTestCase {
  func testActiveReleaseSupportsOnlySafariAndChrome() {
    XCTAssertEqual(
      BrowserExtensionProtocol.activeBrowserExtensions,
      ["safari", "chrome"]
    )
  }

  func testLoopbackCaptureContractIsLocalAndBounded() {
    XCTAssertEqual(BrowserExtensionProtocol.loopbackHost, "127.0.0.1")
    XCTAssertEqual(BrowserExtensionProtocol.loopbackPort, 17_843)
    XCTAssertEqual(
      BrowserExtensionProtocol.loopbackBaseURL,
      "http://127.0.0.1:17843"
    )
    XCTAssertEqual(
      BrowserExtensionProtocol.loopbackProtocolHeaderName,
      "X-RepoPress-Protocol"
    )
    XCTAssertEqual(BrowserExtensionProtocol.loopbackProtocolHeaderValue, "1")
    XCTAssertEqual(BrowserExtensionProtocol.maximumInputBytes, 50 * 1_024 * 1_024)
  }

  func testCaptureRoutesRemainExplicitlyAllowlisted() {
    XCTAssertEqual(
      BrowserExtensionProtocol.allowedRoutes,
      [
        "/v1/folders": ["GET"],
        "/v1/import": ["POST"],
        "/v1/open": ["POST"],
        "/v1/suggestions": ["POST"],
      ]
    )
  }
}
