import XCTest

@testable import PersonalSitePublisherMac

final class RepositoryDraftDiscoverySettingsTests: XCTestCase {
  func testAutomaticDiscoveryRequiresEverySafetyAndPreferenceGate() {
    XCTAssertTrue(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        canUseProtectedWorkbench: true,
        isEnabled: true,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: true,
        canUseProtectedWorkbench: true,
        isEnabled: true,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        canUseProtectedWorkbench: false,
        isEnabled: true,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        canUseProtectedWorkbench: true,
        isEnabled: false,
        isRefreshRunning: false
      )
    )
    XCTAssertFalse(
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: false,
        canUseProtectedWorkbench: true,
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
