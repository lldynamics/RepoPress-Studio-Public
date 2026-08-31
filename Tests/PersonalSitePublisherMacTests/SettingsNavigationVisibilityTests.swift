import Foundation
import XCTest

@testable import PersonalSitePublisherMac

/// Protects the user-visible nine-page Settings navigation contract.
final class SettingsNavigationVisibilityTests: XCTestCase {
  func testSidebarRendersEveryPageAndExpandedSubsectionAsVisibleRows() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sidebarSourceURL = repositoryRoot.appendingPathComponent(
      "Sources/PersonalSitePublisherMac/Views/Settings/SettingsNavigationSidebar.swift"
    )
    let source = try String(contentsOf: sidebarSourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("pageSection(\"当前站点\", tabs: SettingsTab.siteSettings)"))
    XCTAssertTrue(source.contains("pageSection(\"应用\", tabs: SettingsTab.applicationSettings)"))
    XCTAssertTrue(source.contains("ForEach(subsections)"))
    XCTAssertTrue(source.contains("settings-tab-\\(tab.id)"))
    XCTAssertTrue(source.contains("settings-subsection-\\(subsection.id)"))
    XCTAssertTrue(source.contains(".scrollIndicators(.hidden)"))
  }

  func testSidebarExposesAllNineSettingsPagesInStableSections() {
    XCTAssertEqual(
      SettingsTab.siteSettings,
      [.configurationStatus, .defaultRules, .token, .ai]
    )
    XCTAssertEqual(
      SettingsTab.applicationSettings,
      [.dataManagement, .appearance, .editor, .rss, .privacy]
    )
    let visibleTabs = SettingsTab.siteSettings + SettingsTab.applicationSettings
    XCTAssertEqual(visibleTabs.count, SettingsTab.allCases.count)
    XCTAssertEqual(Set(visibleTabs), Set(SettingsTab.allCases))
    XCTAssertEqual(Set(visibleTabs).count, visibleTabs.count)
  }

  func testEveryVisiblePageHasAtLeastOneDiscoverableSubsection() {
    for tab in SettingsTab.allCases {
      XCTAssertFalse(
        SettingsSubsection.sections(for: tab).isEmpty, "Missing sections for \(tab.id)")
      XCTAssertEqual(SettingsDestination(requestedID: tab.id), .tab(tab))
      XCTAssertEqual(SettingsRoute.requestedID(tab.id), .tab(tab))
      XCTAssertEqual(SettingsRoute.restored(lastViewedID: tab.id), .tab(tab))
    }
  }
}
