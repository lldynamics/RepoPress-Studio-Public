import XCTest

@testable import PersonalSitePublisherMac
import KnowledgeNativeMessagingSupport

final class BrowserExtensionOriginPolicyTests: XCTestCase {
  func testAllowsSafariPerInstallUUIDOrigin() {
    XCTAssertTrue(
      BrowserExtensionOriginPolicy.allows(
        "safari-web-extension://E522689D-94A6-4561-90F3-BF22C7848965"
      )
    )
  }

  func testRejectsSafariOriginWithoutUUIDHost() {
    XCTAssertFalse(
      BrowserExtensionOriginPolicy.allows(
        "safari-web-extension://com.jinfang.PersonalSitePublisherMac.SafariExtension"
      )
    )
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("safari-web-extension://"))
  }

  func testAllowsOnlyCurrentSafariAndChromeReleaseOrigins() {
    XCTAssertEqual(
      KnowledgeNativeMessagingProtocol.activeBrowserExtensions,
      ["safari", "chrome"]
    )
    XCTAssertTrue(BrowserExtensionOriginPolicy.allows(nil))
    XCTAssertFalse(BrowserExtensionOriginPolicy.allows("moz-extension://temporary-id"))
    XCTAssertTrue(
      BrowserExtensionOriginPolicy.allows(
        "chrome-extension://\(KnowledgeNativeMessagingProtocol.chromiumDevelopmentExtensionID)"
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
