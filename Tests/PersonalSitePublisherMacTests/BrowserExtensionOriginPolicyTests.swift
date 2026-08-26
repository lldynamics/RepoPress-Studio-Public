import XCTest

@testable import PersonalSitePublisherMac
import BrowserExtensionProtocolSupport

final class BrowserExtensionOriginPolicyTests: XCTestCase {
  func testRejectsSafariWebExtensionOrigins() {
    XCTAssertFalse(
      BrowserExtensionOriginPolicy.allows(
        "safari-web-extension://E522689D-94A6-4561-90F3-BF22C7848965"
      )
    )
    XCTAssertFalse(
      BrowserExtensionOriginPolicy.allows(
        "safari-web-extension://com.jinfang.PersonalSitePublisherMac.SafariExtension"
      )
    )
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("safari-web-extension://"))
  }

  func testAllowsCurrentChromeAndFirefoxReleaseOrigins() {
    XCTAssertEqual(
      BrowserExtensionProtocol.activeBrowserExtensions,
      ["chrome", "firefox"]
    )
    XCTAssertTrue(BrowserExtensionOriginPolicy.allows(nil))
    XCTAssertTrue(
      BrowserExtensionOriginPolicy.allows(
        "moz-extension://E522689D-94A6-4561-90F3-BF22C7848965"
      )
    )
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("moz-extension://temporary-id"))
    XCTAssertTrue(
      BrowserExtensionOriginPolicy.allows(
        "chrome-extension://\(BrowserExtensionProtocol.chromiumDevelopmentExtensionID)"
      )
    )
    XCTAssertFalse(
      BrowserExtensionOriginPolicy.allows(
        "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    )
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("https://example.com"))
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("null"))
  }
}
