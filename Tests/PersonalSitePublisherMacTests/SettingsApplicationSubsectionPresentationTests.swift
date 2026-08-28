import XCTest

@testable import PersonalSitePublisherMac

final class SettingsApplicationSubsectionPresentationTests: XCTestCase {
  func testApplicationTabsExposeFocusedStableSubsections() {
    XCTAssertEqual(
      SettingsSubsection.sections(for: .dataManagement),
      [.dataDrafts, .dataStorage, .dataBackup, .dataMigration]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .appearance),
      [.appearanceBehavior, .appearanceTheme, .appearanceLanguage, .appearanceDefaults]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .editor),
      [.editorPreview, .editorTypography, .editorAssistance, .editorAutomation]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .rss),
      [.rssRefresh, .rssReading, .rssOfflineNetwork, .rssMigration, .rssCleanup]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .privacy),
      [.privacyQuickHide, .privacyMasking, .privacyStatus]
    )
  }

  func testApplicationTabsHaveFocusedDefaultSubsections() {
    XCTAssertEqual(SettingsSubsection.defaultSection(for: .dataManagement), .dataDrafts)
    XCTAssertEqual(SettingsSubsection.defaultSection(for: .appearance), .appearanceBehavior)
    XCTAssertEqual(SettingsSubsection.defaultSection(for: .editor), .editorPreview)
    XCTAssertEqual(SettingsSubsection.defaultSection(for: .rss), .rssRefresh)
    XCTAssertEqual(SettingsSubsection.defaultSection(for: .privacy), .privacyQuickHide)
  }
}
