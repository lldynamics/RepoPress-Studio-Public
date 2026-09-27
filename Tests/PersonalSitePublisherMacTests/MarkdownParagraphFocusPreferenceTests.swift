import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownParagraphFocusPreferenceTests: XCTestCase {
  func testFreshInstallDoesNotScrollOrHighlightAutomatically() throws {
    try withDefaults { defaults in
      XCTAssertFalse(
        MarkdownEditorComfortPreferences.initialParagraphFocusEnabled(defaults: defaults))
      let configuration = MarkdownEditorComfortConfiguration()
      XCTAssertFalse(configuration.typewriterModeEnabled)
      XCTAssertFalse(configuration.currentParagraphHighlightEnabled)
    }
  }

  func testEitherLegacyWritingAidMigratesToParagraphFocus() throws {
    for legacyKey in [
      "markdownEditorTypewriterModeEnabled", "markdownEditorParagraphSpotlightEnabled",
    ] {
      try withDefaults { defaults in
        defaults.set(true, forKey: legacyKey)
        XCTAssertTrue(
          MarkdownEditorComfortPreferences.initialParagraphFocusEnabled(defaults: defaults))
        XCTAssertTrue(
          defaults.bool(forKey: MarkdownEditorComfortPreferences.paragraphFocusEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: legacyKey))
      }
    }
  }

  func testLegacyHighlightDoesNotOptUserIntoAutomaticScrolling() throws {
    try withDefaults { defaults in
      defaults.set(true, forKey: "markdownEditorCurrentParagraphHighlightEnabled")
      defaults.set(20, forKey: MarkdownEditorComfortPreferences.fontSizeKey)
      XCTAssertFalse(
        MarkdownEditorComfortPreferences.initialParagraphFocusEnabled(defaults: defaults))
      XCTAssertEqual(defaults.integer(forKey: MarkdownEditorComfortPreferences.fontSizeKey), 20)
    }
  }

  func testTurningOffMigratedPreferenceIsNotUndoneOnNextLaunch() throws {
    try withDefaults { defaults in
      defaults.set(true, forKey: "markdownEditorTypewriterModeEnabled")
      XCTAssertTrue(
        MarkdownEditorComfortPreferences.initialParagraphFocusEnabled(defaults: defaults))
      defaults.set(false, forKey: MarkdownEditorComfortPreferences.paragraphFocusEnabledKey)
      XCTAssertFalse(
        MarkdownEditorComfortPreferences.initialParagraphFocusEnabled(defaults: defaults))
    }
  }

  func testParagraphFocusControlsBothRenderingBehaviorsTogether() {
    for enabled in [false, true] {
      let configuration = MarkdownEditorComfortConfiguration(paragraphFocusEnabled: enabled)
      XCTAssertEqual(configuration.typewriterModeEnabled, enabled)
      XCTAssertEqual(configuration.currentParagraphHighlightEnabled, enabled)
    }
  }

  private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "MarkdownParagraphFocusPreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }
}
