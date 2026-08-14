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
      [.dataManagement, .appearance, .editor, .rss, .privacy]
    )
    XCTAssertEqual(SettingsTab.allCases.count, 9)
    XCTAssertEqual(SettingsTab.configurationStatus.title, "站点概览")
    XCTAssertEqual(SettingsTab.defaultRules.title, "内容与路径")
    XCTAssertEqual(SettingsTab.token.title, "发布连接")
    XCTAssertEqual(SettingsTab.ai.title, "AI 助手")
    XCTAssertEqual(SettingsTab.appearance.title, "通用与外观")
    XCTAssertEqual(SettingsTab.appearance.systemImage, "paintpalette")
    XCTAssertFalse(SettingsTab.appearance.isSiteScoped)
    XCTAssertEqual(SettingsTab.editor.title, "编辑器")
    XCTAssertEqual(SettingsTab.editor.systemImage, "textformat")
    XCTAssertFalse(SettingsTab.editor.isSiteScoped)
    XCTAssertEqual(SettingsTab.rss.title, "RSS 阅读")
    XCTAssertEqual(SettingsTab.privacy.title, "隐私与安全")
    XCTAssertEqual(SettingsTab.dataManagement.title, "数据与备份")
    XCTAssertFalse(SettingsTab.rss.isSiteScoped)
  }

  func testMergedSettingsKeepLegacyRequestedTabIDsUsable() {
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "language"), .appearance)
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "storage"), .dataManagement)
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "defaultRules"), .defaultRules)
    XCTAssertNil(SettingsTab.tab(forRequestedID: "removed-tab"))
  }

  func testSettingsDestinationParsesStructuredSectionRequests() {
    XCTAssertEqual(SettingsDestination(requestedID: "rules.paths"), .rules(.paths))
    XCTAssertEqual(SettingsDestination(requestedID: "token.repository"), .token(.repository))
    XCTAssertEqual(SettingsDestination(requestedID: "token.deployment"), .token(.deployment))
    XCTAssertEqual(SettingsDestination(requestedID: "token.analytics"), .token(.analytics))
    XCTAssertEqual(SettingsDestination(requestedID: "ai.connection"), .ai(.connection))
    XCTAssertEqual(SettingsDestination(requestedID: "ai.credentials"), .ai(.credentials))
    XCTAssertEqual(SettingsDestination(requestedID: "ai.writingStyle"), .ai(.writingStyle))
    XCTAssertEqual(SettingsDestination(requestedID: "data.drafts"), .data(.drafts))
    XCTAssertEqual(SettingsDestination(requestedID: "data.backup"), .data(.backup))
    XCTAssertEqual(SettingsDestination(requestedID: "data.migration"), .data(.migration))
  }

  func testSettingsDestinationMapsSectionsToTheirTopLevelTab() {
    XCTAssertEqual(SettingsDestination.rules(.paths).tab, .defaultRules)
    XCTAssertEqual(SettingsDestination.token(.deployment).tab, .token)
    XCTAssertEqual(SettingsDestination.ai(.writingStyle).tab, .ai)
    XCTAssertEqual(SettingsDestination.data(.backup).tab, .dataManagement)
  }

  func testSettingsSelectionDefaultsToOverviewAndRestoresValidTopLevelTab() {
    XCTAssertEqual(SettingsNavigation.initialTab(lastViewedTabID: nil), .configurationStatus)
    XCTAssertEqual(SettingsNavigation.initialTab(lastViewedTabID: ""), .configurationStatus)
    XCTAssertEqual(
      SettingsNavigation.initialTab(lastViewedTabID: "removed-tab"), .configurationStatus)
    XCTAssertEqual(SettingsNavigation.initialTab(lastViewedTabID: "ai"), .ai)
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
