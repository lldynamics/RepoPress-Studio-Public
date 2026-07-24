import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchFirstRunSetupPolicyTests: XCTestCase {
  func testPresentsForUnconfiguredPublishingProfile() {
    XCTAssertTrue(
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: false,
        profile: .defaultProfile,
        isScreenshotDemo: false
      )
    )
  }

  func testDoesNotPresentAfterCompletionOrDuringScreenshotCapture() {
    XCTAssertFalse(
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: true,
        profile: .defaultProfile,
        isScreenshotDemo: false
      )
    )
    XCTAssertFalse(
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: false,
        profile: .defaultProfile,
        isScreenshotDemo: true
      )
    )
  }

  func testDoesNotPresentForConfiguredOrRepositoryFreeProfile() {
    var configured = SiteProfile.defaultProfile
    configured.localRepositoryRootPath = "/tmp/site"
    XCTAssertFalse(
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: false,
        profile: configured,
        isScreenshotDemo: false
      )
    )

    var library = SiteProfile.defaultProfile
    library.purpose = .generalDraftBackup
    XCTAssertFalse(
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: false,
        profile: library,
        isScreenshotDemo: false
      )
    )
  }
}
