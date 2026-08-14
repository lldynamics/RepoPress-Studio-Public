import XCTest
@testable import PersonalSitePublisherMac

final class AppUpdateConfigurationTests: XCTestCase {
  func testAboutPanelShowsOnlyMarketingVersion() {
    let presentation = AppAboutPresentation(
      infoDictionary: [
        "CFBundleShortVersionString": "1.0.1",
        "CFBundleVersion": "14",
      ]
    )

    XCTAssertEqual(
      presentation.panelOptions[.applicationVersion] as? String,
      "1.0.1"
    )
    XCTAssertEqual(presentation.panelOptions[.version] as? String, "")
  }

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
