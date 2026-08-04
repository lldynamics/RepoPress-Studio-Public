import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchSessionRecoveryTests: XCTestCase {
  func testUncleanPreviousSessionIsDetectedAndCleanExitClearsTheSignal() {
    let suiteName = "WorkbenchSessionRecoveryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let recovery = WorkbenchSessionRecovery(
      defaults: defaults,
      keyPrefix: "session"
    )

    let firstLaunch = recovery.beginLaunch()
    XCTAssertFalse(firstLaunch.hadUncleanPreviousSession)

    let secondLaunch = recovery.beginLaunch()
    XCTAssertTrue(secondLaunch.hadUncleanPreviousSession)

    recovery.markCleanExit()
    let cleanLaunch = recovery.beginLaunch()
    XCTAssertFalse(cleanLaunch.hadUncleanPreviousSession)
  }

  func testSafeModeRequestIsConsumedOnlyByTheNextLaunch() {
    let suiteName = "WorkbenchSessionRecoveryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let recovery = WorkbenchSessionRecovery(
      defaults: defaults,
      keyPrefix: "session"
    )

    recovery.requestSafeModeOnNextLaunch()
    XCTAssertTrue(recovery.beginLaunch().safeModeWasRequested)
    XCTAssertFalse(recovery.beginLaunch().safeModeWasRequested)
  }
}
