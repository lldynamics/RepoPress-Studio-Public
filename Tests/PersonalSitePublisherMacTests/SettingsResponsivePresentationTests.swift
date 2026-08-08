import XCTest

@testable import PersonalSitePublisherMac

final class SettingsResponsivePresentationTests: XCTestCase {
  func testSidebarWidthScalesWithinUsableBounds() {
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(180), 204)
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(224), 224)
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(280), 244)
  }

  func testSidebarAttentionBadgeKeepsVisibleAndSpokenMeanings() {
    XCTAssertEqual(SettingsSidebarPresentation.attentionBadgeTitle, "需配置")
    XCTAssertEqual(
      SettingsSidebarPresentation.attentionAccessibilityValue,
      "需要配置"
    )
  }
}
