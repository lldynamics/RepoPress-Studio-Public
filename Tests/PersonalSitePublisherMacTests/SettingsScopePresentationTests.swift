import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class SettingsScopePresentationTests: XCTestCase {
  func testOneAIPageKeepsSharedConnectionsAndSitePreferencesDistinct() {
    XCTAssertFalse(SettingsTab.ai.isSiteScoped)
    XCTAssertTrue(SettingsTab.ai.showsSiteSwitcher)
    XCTAssertEqual(SettingsTab.ai.scopePresentation, .sharedConnection)
    XCTAssertEqual(SettingsTab.ai.title, "AI 与写作")
    XCTAssertEqual(SettingsTab.ai.scopePresentation.badgeTitle, "共享连接与当前站点")
    XCTAssertTrue(SettingsTab.ai.scopePresentation.accessibilityDescription.contains("所有引用"))
    XCTAssertTrue(SettingsTab.ai.scopePresentation.accessibilityDescription.contains("当前站点"))
    XCTAssertEqual(SettingsDestination.ai(.writingStyle).tab, .ai)
    XCTAssertEqual(SettingsDestination.ai(.credentials).tab, .ai)
    XCTAssertEqual(SettingsTab.tab(forRequestedID: "siteAI"), .ai)
    XCTAssertEqual(
      SettingsSubsection.sections(for: .ai),
      [.aiConnection, .aiAdvanced, .aiSiteConnection, .aiWritingStyle]
    )
    for tab in SettingsTab.allCases where tab != .ai {
      XCTAssertEqual(tab.showsSiteSwitcher, tab.isSiteScoped)
    }
  }

  func testConnectionUsageListsOnlyReferencingSiteNamesOnceInProfileOrder() {
    let connectionID = UUID()
    var first = SiteProfile.defaultProfile
    first.name = "中文站"
    first.aiConnectionProfileID = connectionID

    var second = SiteProfile.defaultProfile
    second.id = UUID()
    second.name = "英文站"
    second.aiConnectionProfileID = connectionID

    var duplicateName = SiteProfile.defaultProfile
    duplicateName.id = UUID()
    duplicateName.name = "中文站"
    duplicateName.aiConnectionProfileID = connectionID

    var unrelated = SiteProfile.defaultProfile
    unrelated.id = UUID()
    unrelated.name = "未引用站点"

    let presentation = AIConnectionUsagePresentation(
      connectionProfileID: connectionID,
      siteProfiles: [first, second, duplicateName, unrelated]
    )

    XCTAssertEqual(presentation.referencedSiteNames, ["中文站", "英文站", "中文站"])
    XCTAssertEqual(presentation.referencedSitesDescription, "引用站点：中文站、英文站、中文站")
  }
}
