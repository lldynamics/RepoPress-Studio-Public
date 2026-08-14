import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishingAutomationSettingsTests: XCTestCase {
  func testRepositoryUpdatePreservesOtherFieldsAndNormalizesInterval() {
    let current = RepositoryAutoSyncSettings(
      isEnabled: true,
      intervalMinutes: 30,
      fetchBeforeScan: false,
      autoImportRemoteArticles: true
    )

    let updated = TokenRepositoryAutomationSettingsSupport.updated(
      current,
      intervalMinutes: 999
    )

    XCTAssertEqual(updated.normalizedIntervalMinutes, RepositoryAutoSyncSettings.maximumIntervalMinutes)
    XCTAssertTrue(updated.isEnabled)
    XCTAssertFalse(updated.fetchBeforeScan)
    XCTAssertTrue(updated.autoImportRemoteArticles)
  }

  func testRepositoryDisablingKeepsIntervalAndChildOptions() {
    let current = RepositoryAutoSyncSettings(
      isEnabled: true,
      intervalMinutes: 45,
      fetchBeforeScan: false,
      autoImportRemoteArticles: true
    )

    let updated = TokenRepositoryAutomationSettingsSupport.updated(current, isEnabled: false)

    XCTAssertFalse(updated.isEnabled)
    XCTAssertEqual(updated.normalizedIntervalMinutes, 45)
    XCTAssertFalse(updated.fetchBeforeScan)
    XCTAssertTrue(updated.autoImportRemoteArticles)
  }

  func testDeploymentUpdatePreservesEnabledStateAndNormalizesInterval() {
    let current = DeploymentPollingSettings(isEnabled: true, intervalMinutes: 15)

    let updated = TokenDeploymentAutomationSettingsSupport.updated(
      current,
      intervalMinutes: 999
    )

    XCTAssertTrue(updated.isEnabled)
    XCTAssertEqual(updated.normalizedIntervalMinutes, DeploymentPollingSettings.maximumIntervalMinutes)
  }

  func testDeploymentDisablingKeepsSavedInterval() {
    let current = DeploymentPollingSettings(isEnabled: true, intervalMinutes: 30)

    let updated = TokenDeploymentAutomationSettingsSupport.updated(current, isEnabled: false)

    XCTAssertFalse(updated.isEnabled)
    XCTAssertEqual(updated.normalizedIntervalMinutes, 30)
  }

  func testIntervalOptionsMatchModelBounds() {
    XCTAssertEqual(
      TokenRepositoryAutomationSettingsSupport.intervalOptions.first,
      RepositoryAutoSyncSettings.minimumIntervalMinutes
    )
    XCTAssertEqual(
      TokenRepositoryAutomationSettingsSupport.intervalOptions.last,
      RepositoryAutoSyncSettings.maximumIntervalMinutes
    )
    XCTAssertEqual(
      TokenDeploymentAutomationSettingsSupport.intervalOptions.first,
      DeploymentPollingSettings.minimumIntervalMinutes
    )
    XCTAssertEqual(
      TokenDeploymentAutomationSettingsSupport.intervalOptions.last,
      DeploymentPollingSettings.maximumIntervalMinutes
    )
  }
}
