import XCTest
@testable import PersonalSitePublisherMac

final class KnowledgeSettingsPresentationTests: XCTestCase {
  func testAdvancedKnowledgeSettingsStartFullyCollapsed() {
    let state = KnowledgeAdvancedSettingsExpansionState()

    XCTAssertTrue(state.isFullyCollapsed)
    XCTAssertFalse(state.vectorSearch)
    XCTAssertFalse(state.smartCollections)
    XCTAssertFalse(state.backup)
    XCTAssertFalse(state.browserConnection)
  }

  func testApplicationSettingsExcludeTheLibraryManagedSettingsSheet() {
    XCTAssertEqual(
      SettingsTab.applicationSettings,
      [.dataManagement, .appearance, .rss, .privacy]
    )
    XCTAssertEqual(SettingsTab.allCases.count, 8)
    XCTAssertEqual(SettingsTab.appearance.title, "外观")
    XCTAssertEqual(SettingsTab.appearance.systemImage, "paintpalette")
    XCTAssertFalse(SettingsTab.appearance.isSiteScoped)
    XCTAssertEqual(SettingsTab.rss.title, "RSS 阅读")
    XCTAssertFalse(SettingsTab.rss.isSiteScoped)
  }

  func testMergedSettingsKeepLegacyRequestedTabIDsUsable() {
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "language"), .appearance)
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "storage"), .dataManagement)
    XCTAssertNil(SettingsTab.tab(forRequestedID: "removed-tab"))
  }

  func testDataManagementCollectsCrossCuttingSections() {
    XCTAssertEqual(
      DataManagementSection.allCases,
      [.drafts, .backup, .migration]
    )
    XCTAssertEqual(DataManagementSection.drafts.title, "草稿生命周期")
    XCTAssertEqual(DataManagementSection.backup.title, "备份与恢复")
    XCTAssertEqual(DataManagementSection.migration.title, "内容迁移")
  }

  func testSettingsLayoutMetricsKeepCompactWindowUsable() {
    XCTAssertEqual(WorkbenchSettingsMetrics.minimumWidth, 820)
    XCTAssertEqual(WorkbenchSettingsMetrics.minimumHeight, 560)
    XCTAssertEqual(WorkbenchSettingsMetrics.sidebarWidth, 204)
    XCTAssertEqual(
      SettingsTab.appearance.contentMaxWidth,
      WorkbenchSettingsMetrics.focusedContentWidth
    )
    XCTAssertEqual(
      SettingsTab.token.contentMaxWidth,
      WorkbenchSettingsMetrics.detailedContentWidth
    )
    XCTAssertGreaterThan(
      WorkbenchSettingsMetrics.minimumWidth - WorkbenchSettingsMetrics.sidebarWidth,
      600
    )
  }
}
