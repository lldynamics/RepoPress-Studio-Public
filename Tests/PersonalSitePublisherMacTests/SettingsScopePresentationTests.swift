import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class SettingsScopePresentationTests: XCTestCase {
  func testAISettingsRetainTheirSiteNavigationGroupButPresentMixedScope() {
    XCTAssertTrue(SettingsTab.ai.isSiteScoped)
    XCTAssertEqual(SettingsTab.ai.scopePresentation, .mixed)
    XCTAssertEqual(SettingsTab.ai.scopePresentation.badgeTitle, "混合作用范围")
    XCTAssertTrue(SettingsTab.ai.scopePresentation.accessibilityDescription.contains("连接档案共享"))
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
