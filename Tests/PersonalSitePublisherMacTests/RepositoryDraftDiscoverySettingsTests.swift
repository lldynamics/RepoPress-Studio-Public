import XCTest

@testable import PersonalSitePublisherMac

final class RepositoryDraftDiscoverySettingsTests: XCTestCase {
  func testAutomaticDiscoveryRequiresSafetyAndPreferenceGates() {
    XCTAssertTrue(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        isEnabled: true,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: true,
        isEnabled: true,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        isEnabled: false,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        isEnabled: true,
        isRefreshRunning: true
      )
    )
  }

  func testManualDiscoveryDoesNotDependOnAutomaticPreference() {
    XCTAssertTrue(
      RepositoryDraftDiscoveryPolicy.canRunManually(
        hasRepositoryRoot: true,
        isRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.canRunManually(
        hasRepositoryRoot: false,
        isRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.canRunManually(
        hasRepositoryRoot: true,
        isRunning: true
      )
    )
  }
}
