import PublishingWorkbenchCore
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

  func testRSSReaderTranslationBackendPreferenceUsesStableRawValues() {
    XCTAssertEqual(
      RSSReaderUserPreferences.translationBackendKey,
      "rssReaderTranslationBackend"
    )
    XCTAssertEqual(RSSArticleTranslationBackend.apple.rawValue, "apple")
    XCTAssertEqual(RSSArticleTranslationBackend.ai.rawValue, "ai")

    let expectedDefault: RSSArticleTranslationBackend =
      if #available(macOS 15.0, *) { .apple } else { .ai }
    XCTAssertEqual(RSSReaderUserPreferences.defaultTranslationBackend, expectedDefault)

    let suiteName = "RSSReaderUserPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(
      RSSReaderUserPreferences.translationBackend(defaults: defaults),
      expectedDefault
    )
    defaults.set(
      RSSArticleTranslationBackend.ai.rawValue,
      forKey: RSSReaderUserPreferences.translationBackendKey)
    XCTAssertEqual(
      RSSReaderUserPreferences.translationBackend(defaults: defaults),
      .ai
    )
  }

  func testSharedReaderTypographyDefaultsAndKeysAreStable() {
    let keys = [
      ReaderTypographyConfiguration.fontSizeKey,
      ReaderTypographyConfiguration.lineSpacingKey,
      ReaderTypographyConfiguration.themeKey,
      ReaderTypographyConfiguration.fontFamilyKey,
      ReaderTypographyConfiguration.paragraphSpacingKey,
      ReaderTypographyConfiguration.textAlignmentKey,
      ReaderTypographyConfiguration.codeHighlightThemeKey,
    ]

    XCTAssertEqual(Set(keys).count, keys.count)
    XCTAssertEqual(ReaderTypographyConfiguration.fontSizeKey, "rssReaderFontSize")
    XCTAssertEqual(ReaderTypographyConfiguration.lineSpacingKey, "rssReaderLineSpacing")
    XCTAssertEqual(ReaderTypographyConfiguration.defaultFontFamily, .system)
    XCTAssertEqual(ReaderTypographyConfiguration.defaultParagraphSpacing, 0.82)
    XCTAssertEqual(ReaderTypographyConfiguration.defaultTextAlignment, .natural)
    XCTAssertEqual(ReaderTypographyConfiguration.defaultCodeHighlightTheme, .adaptive)
    XCTAssertEqual(ReaderFontFamily.newYork.rawValue, "newYork")
    XCTAssertEqual(ReaderFontFamily.songti.rawValue, "songti")
    XCTAssertEqual(
      ReaderTypographyConfiguration.normalizedFontSize(.nan),
      ReaderTypographyConfiguration.defaultFontSize
    )
    XCTAssertEqual(
      ReaderTypographyConfiguration.normalizedLineSpacing(.infinity),
      ReaderTypographyConfiguration.defaultLineSpacing
    )
    XCTAssertEqual(
      ReaderTypographyConfiguration.normalizedParagraphSpacing(-10),
      ReaderTypographyConfiguration.paragraphSpacingRange.lowerBound
    )
  }
}
