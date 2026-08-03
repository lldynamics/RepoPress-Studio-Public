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

  func testKnowledgeSettingsAppearWithApplicationSettings() {
    XCTAssertEqual(SettingsTab.applicationSettings, [.language, .privacy])
    XCTAssertEqual(SettingsTab.language.title, "语言")
    XCTAssertEqual(SettingsTab.language.systemImage, "globe")
    XCTAssertFalse(SettingsTab.language.isSiteScoped)
    XCTAssertEqual(SettingsTab.knowledge.title, "资料库")
    XCTAssertEqual(SettingsTab.knowledge.systemImage, "books.vertical")
    XCTAssertFalse(SettingsTab.knowledge.isSiteScoped)
  }
}
