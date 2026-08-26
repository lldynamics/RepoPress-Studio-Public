import XCTest

@testable import PersonalSitePublisherMac

final class EditorAutomationSettingsTests: XCTestCase {
  func testEditorAutomationDefaultsCoverRealtimeAnalysisOnly() {
    XCTAssertTrue(MarkdownEditorComfortPreferences.defaultRealtimeAnalysisEnabled)
    XCTAssertTrue(MarkdownEditorComfortConfiguration.defaultRealtimeAnalysisEnabled)

    let keys = [
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

  func testAutomaticWorkUsesQuietIdleWindow() {
    XCTAssertEqual(
      MarkdownEditorAutomationPolicy.automaticWorkIdleDelayMilliseconds,
      1_200
    )
    XCTAssertGreaterThanOrEqual(
      MarkdownEditorAutomationPolicy.automaticWorkIdleDelayMilliseconds,
      1_000
    )
    XCTAssertLessThanOrEqual(
      MarkdownEditorAutomationPolicy.automaticWorkIdleDelayMilliseconds,
      1_500
    )
  }
}
