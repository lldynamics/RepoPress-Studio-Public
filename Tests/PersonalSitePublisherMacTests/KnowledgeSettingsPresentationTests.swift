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
    XCTAssertEqual(SettingsTab.applicationSettings, [.language, .storage, .rss, .privacy])
    XCTAssertEqual(SettingsTab.language.title, "语言")
    XCTAssertEqual(SettingsTab.language.systemImage, "globe")
    XCTAssertFalse(SettingsTab.language.isSiteScoped)
    XCTAssertEqual(SettingsTab.storage.title, "存储管理")
    XCTAssertEqual(SettingsTab.storage.systemImage, "externaldrive")
    XCTAssertFalse(SettingsTab.storage.isSiteScoped)
    XCTAssertEqual(SettingsTab.rss.title, "RSS 阅读")
    XCTAssertFalse(SettingsTab.rss.isSiteScoped)
  }

  func testSettingsLayoutMetricsKeepCompactWindowUsable() {
    XCTAssertEqual(WorkbenchSettingsMetrics.minimumWidth, 820)
    XCTAssertEqual(WorkbenchSettingsMetrics.minimumHeight, 560)
    XCTAssertEqual(WorkbenchSettingsMetrics.sidebarWidth, 204)
    XCTAssertEqual(SettingsTab.language.contentMaxWidth, WorkbenchSettingsMetrics.focusedContentWidth)
    XCTAssertEqual(SettingsTab.token.contentMaxWidth, WorkbenchSettingsMetrics.detailedContentWidth)
    XCTAssertGreaterThan(
      WorkbenchSettingsMetrics.minimumWidth - WorkbenchSettingsMetrics.sidebarWidth,
      600
    )
  }
}
