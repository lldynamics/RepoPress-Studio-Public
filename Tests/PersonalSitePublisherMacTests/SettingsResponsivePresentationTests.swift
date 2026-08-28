import XCTest

@testable import PersonalSitePublisherMac

final class SettingsResponsivePresentationTests: XCTestCase {
  func testSidebarWidthScalesWithinUsableBounds() {
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(180), 232)
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(248), 248)
    XCTAssertEqual(SettingsSidebarPresentation.clampedWidth(280), 272)
  }

  func testSidebarAttentionBadgeKeepsVisibleAndSpokenMeanings() {
    XCTAssertEqual(SettingsSidebarPresentation.attentionBadgeTitle, "需配置")
    XCTAssertEqual(
      SettingsSidebarPresentation.attentionAccessibilityValue,
      "需要配置"
    )
  }

  func testMinimumWindowUsesOneSidebarAndKeepsDetailUsable() {
    let presentation = SettingsWorkspaceLayout.presentation(
      width: 820,
      height: 560,
      scaledSidebarWidth: 180
    )

    XCTAssertTrue(presentation.usesCompactVerticalMetrics)
    XCTAssertEqual(presentation.primarySidebarWidth, 232)
    let detailWidth = SettingsWorkspaceLayout.availableDetailWidth(
      totalWidth: 820,
      presentation: presentation
    )
    XCTAssertEqual(detailWidth, 820 - presentation.primarySidebarWidth)
    XCTAssertGreaterThanOrEqual(detailWidth, 560)
  }

  func testWideWindowAlsoUsesOneNavigationRail() {
    let presentation = SettingsWorkspaceLayout.presentation(
      width: 1_487,
      height: 760,
      scaledSidebarWidth: 248
    )

    XCTAssertFalse(presentation.usesCompactVerticalMetrics)
    XCTAssertEqual(presentation.primarySidebarWidth, 248)
    let detailWidth = SettingsWorkspaceLayout.availableDetailWidth(
      totalWidth: 1_487,
      presentation: presentation
    )
    XCTAssertEqual(detailWidth, 1_487 - presentation.primarySidebarWidth)
    XCTAssertGreaterThan(detailWidth, 1_000)
  }

  func testCompactDensityUsesCompactVerticalMetricsAtRegularHeight() {
    let presentation = SettingsWorkspaceLayout.presentation(
      width: 1_120,
      height: 760,
      scaledSidebarWidth: 204,
      density: .compact
    )

    XCTAssertTrue(presentation.usesCompactVerticalMetrics)
    XCTAssertLessThan(presentation.sidebarRowVerticalPadding, 8)
    XCTAssertLessThan(presentation.subsectionRowVerticalPadding, 8)
  }
}
