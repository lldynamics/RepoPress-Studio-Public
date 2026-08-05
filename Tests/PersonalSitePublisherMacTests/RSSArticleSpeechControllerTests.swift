import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class RSSArticleSpeechControllerTests: XCTestCase {
  func testSupportedRateMultipliersCoverRequestedRange() {
    XCTAssertEqual(
      RSSArticleSpeechController.supportedRateMultipliers,
      [1.0, 1.25, 1.5, 1.75, 2.0]
    )
  }

  func testRateMultiplierIsClampedToOneToTwoTimes() {
    XCTAssertEqual(
      RSSArticleSpeechController.normalizedRateMultiplier(.nan),
      1.0
    )
    XCTAssertEqual(
      RSSArticleSpeechController.normalizedRateMultiplier(0.5),
      1.0
    )
    XCTAssertEqual(
      RSSArticleSpeechController.normalizedRateMultiplier(2.5),
      2.0
    )
  }
}
