import XCTest

@testable import PersonalSitePublisherMac

final class EditorAutomationSettingsTests: XCTestCase {
  func testEditorAutomationDefaultsPreserveLegacyBehavior() {
    XCTAssertTrue(MarkdownEditorComfortPreferences.defaultAutomaticPreviewRefreshEnabled)
    XCTAssertTrue(MarkdownEditorComfortPreferences.defaultRealtimeAnalysisEnabled)
    XCTAssertTrue(MarkdownEditorComfortConfiguration.defaultAutomaticPreviewRefreshEnabled)
    XCTAssertTrue(MarkdownEditorComfortConfiguration.defaultRealtimeAnalysisEnabled)

    let keys = [
      MarkdownEditorComfortPreferences.automaticPreviewRefreshEnabledKey,
      MarkdownEditorComfortPreferences.realtimeAnalysisEnabledKey,
    ]
    XCTAssertEqual(Set(keys).count, keys.count)
  }

  func testAutomationPolicyStopsAutomaticWorkWhenDisabled() {
    XCTAssertTrue(
      MarkdownEditorAutomationPolicy.allows(isAutomatic: true, isEnabled: true)
    )
    XCTAssertFalse(
      MarkdownEditorAutomationPolicy.allows(isAutomatic: true, isEnabled: false)
    )
  }

  func testAutomationPolicyAlwaysAllowsManualActions() {
    XCTAssertTrue(
      MarkdownEditorAutomationPolicy.allows(isAutomatic: false, isEnabled: true)
    )
    XCTAssertTrue(
      MarkdownEditorAutomationPolicy.allows(isAutomatic: false, isEnabled: false)
    )
  }
}
