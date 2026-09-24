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
      [.appearanceBehavior, .appearanceTheme, .appearanceLanguage]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .editor),
      [
        .editorPreview, .editorTypography, .editorAssistance, .editorAutomation,
        .appearanceDefaults,
      ]
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
}
