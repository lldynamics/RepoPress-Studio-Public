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

  func testSpeechHighlightExpandsToContainingSentence() {
    let text = "第一句内容。第二句内容！第三句内容？"
    let highlight = RSSArticleSpeechController.speechHighlight(
      in: text,
      around: NSRange(location: 2, length: 1)
    )

    XCTAssertEqual(highlight?.text, "第一句内容。")
    XCTAssertEqual(highlight?.location, 0)
    XCTAssertEqual(highlight?.length, ("第一句内容。" as NSString).length)
  }

  func testSpeechHighlightTreatsUnpunctuatedTextAsOneSentence() {
    let text = "没有句号的正文"
    let highlight = RSSArticleSpeechController.speechHighlight(
      in: text,
      around: NSRange(location: 2, length: 2)
    )

    XCTAssertEqual(highlight?.text, text)
    XCTAssertEqual(highlight?.location, 0)
    XCTAssertEqual(highlight?.length, (text as NSString).length)
  }
}
