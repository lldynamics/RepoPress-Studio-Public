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
    XCTAssertEqual(SettingsTab.applicationSettings, [.language, .rss, .privacy])
    XCTAssertEqual(SettingsTab.language.title, "语言")
    XCTAssertEqual(SettingsTab.language.systemImage, "globe")
    XCTAssertFalse(SettingsTab.language.isSiteScoped)
    XCTAssertEqual(SettingsTab.rss.title, "RSS 阅读")
    XCTAssertFalse(SettingsTab.rss.isSiteScoped)
  }
}
