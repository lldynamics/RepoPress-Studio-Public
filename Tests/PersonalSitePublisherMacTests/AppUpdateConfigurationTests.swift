import XCTest
@testable import PersonalSitePublisherMac

final class AppUpdateConfigurationTests: XCTestCase {
  func testRequiresHTTPSFeedAndPublicKey() {
    XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [:]).isReady)
    XCTAssertFalse(
      AppUpdateConfiguration(
        infoDictionary: [
          "SUFeedURL": "http://updates.example.com/appcast.xml",
          "SUPublicEDKey": "public-key",
        ]
      ).isReady
    )
    XCTAssertFalse(
      AppUpdateConfiguration(
        infoDictionary: ["SUFeedURL": "https://updates.example.com/appcast.xml"]
      ).isReady
    )
  }

  func testAcceptsSecureConfiguredFeed() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "https://updates.example.com/stable/appcast.xml",
        "SUPublicEDKey": "public-key",
        "RepoPressUpdateChannel": "beta",
      ]
    )

    XCTAssertTrue(configuration.isReady)
    XCTAssertEqual(configuration.channel, "beta")
  }

  func testDefaultsToStableChannel() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "https://updates.example.com/appcast.xml",
        "SUPublicEDKey": "public-key",
      ]
    )

    XCTAssertEqual(configuration.channel, "stable")
  }

  func testUnknownChannelFallsBackToStable() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "https://updates.example.com/appcast.xml",
        "SUPublicEDKey": "public-key",
        "RepoPressUpdateChannel": "nightly",
      ]
    )

    XCTAssertEqual(configuration.channel, "stable")
  }
}
