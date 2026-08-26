import XCTest

@testable import PersonalSitePublisherMac

final class EditorAndRSSSettingsTests: XCTestCase {
  func testEditorSettingsUseExistingPreferenceKeysWithoutDuplicates() {
    let keys = [
      MarkdownEditorComfortPreferences.fontSizeKey,
      MarkdownEditorComfortPreferences.lineSpacingKey,
      MarkdownEditorComfortPreferences.bodyWidthKey,
      MarkdownEditorComfortPreferences.spellCheckEnabledKey,
      MarkdownEditorComfortPreferences.typewriterModeEnabledKey,
      MarkdownEditorComfortPreferences.currentParagraphHighlightEnabledKey,
      MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey,
      MarkdownEditorComfortPreferences.automaticPairingEnabledKey,
      MarkdownEditorComfortPreferences.paragraphSpotlightEnabledKey,
    ]

    XCTAssertEqual(Set(keys).count, keys.count)
    XCTAssertEqual(MarkdownEditorComfortConfiguration.defaultFontSize, 14)
    XCTAssertEqual(MarkdownEditorComfortConfiguration.defaultLineSpacing, 4)
    XCTAssertEqual(MarkdownEditorComfortConfiguration.defaultBodyWidth, 820)
  }

  func testRSSReaderDefaultsAreOffAndUseCentralizedKeys() {
    XCTAssertEqual(
      RSSReaderUserPreferences.automaticTranslationEnabledKey,
      "rssReaderAutomaticTranslationEnabled"
    )
    XCTAssertEqual(
      RSSReaderUserPreferences.remoteImagesEnabledKey,
      "rssReaderRemoteImagesEnabled"
    )
    XCTAssertFalse(RSSReaderUserPreferences.defaultAutomaticTranslationEnabled)
    XCTAssertFalse(RSSReaderUserPreferences.defaultRemoteImagesEnabled)
  }
}
