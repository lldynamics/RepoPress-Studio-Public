import XCTest
@testable import PersonalSitePublisherMac

final class PersistentWindowCommandMenuPolicyTests: XCTestCase {
  func testKeepsStableCommandAvailableWithOrWithoutMainWindow() {
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: false,
        commandExists: false,
        isMenuTracking: false
      ),
      .install
    )
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: true,
        commandExists: false,
        isMenuTracking: false
      ),
      .install
    )
  }

  func testExistingPersistentCommandRemainsInstalled() {
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: true,
        commandExists: true,
        isMenuTracking: false
      ),
      .noChange
    )
  }

  func testDefersEveryMutationUntilMenuTrackingEnds() {
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: false,
        commandExists: false,
        isMenuTracking: true
      ),
      .deferUntilTrackingEnds
    )
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: true,
        commandExists: true,
        isMenuTracking: true
      ),
      .noChange
    )
  }

  func testExistingDesiredStateIsIdempotentDuringTracking() {
    XCTAssertEqual(
      PersistentWindowCommandMenuPolicy.decision(
        hasMainWindow: false,
        commandExists: true,
        isMenuTracking: true
      ),
      .noChange
    )
  }
}

final class PersistentWindowCommandRequestStateTests: XCTestCase {
  func testCoalescesRequestsUntilTheScheduledAttemptBegins() {
    var state = PersistentWindowCommandRequestState()

    XCTAssertTrue(state.request())
    XCTAssertFalse(state.request())
    XCTAssertTrue(state.isPending)
    XCTAssertTrue(state.isScheduled)
    XCTAssertTrue(state.beginScheduledAttempt())
    XCTAssertFalse(state.isScheduled)
  }

  func testMenuResolutionRemainsPendingPastThreeFailures() throws {
    var state = PersistentWindowCommandRequestState()
    XCTAssertTrue(state.request())

    var delays = [TimeInterval]()
    for _ in 0..<6 {
      XCTAssertTrue(state.beginScheduledAttempt())
      let retry = try XCTUnwrap(state.markAttemptUnavailable())
      delays.append(retry.delay)
      XCTAssertTrue(state.isPending)
      XCTAssertTrue(state.retryTimerFired(token: retry.token))
    }

    XCTAssertEqual(delays, [0.1, 0.2, 0.4, 0.8, 1.0, 1.0])
    XCTAssertTrue(state.isPending)
    XCTAssertTrue(state.isScheduled)
  }

  func testCompletedRequestInvalidatesItsRetryTimer() throws {
    var state = PersistentWindowCommandRequestState()
    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    let staleRetry = try XCTUnwrap(state.markAttemptUnavailable())

    state.markCompleted()

    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    let currentRetry = try XCTUnwrap(state.markAttemptUnavailable())
    XCTAssertFalse(state.retryTimerFired(token: staleRetry.token))
    XCTAssertTrue(state.isPending)
    XCTAssertFalse(state.isScheduled)
    XCTAssertTrue(state.retryTimerFired(token: currentRetry.token))
    XCTAssertTrue(state.isScheduled)
  }
}

final class MainWindowRestoreRequestStateTests: XCTestCase {
  func testUnavailableActionKeepsRetryingWithCappedBackoff() throws {
    var state = MainWindowRestoreRequestState()
    XCTAssertTrue(state.request())

    var delays = [TimeInterval]()
    for _ in 0..<6 {
      XCTAssertTrue(state.beginScheduledAttempt())
      let retry = try XCTUnwrap(state.markActionUnavailable())
      delays.append(retry.delay)
      XCTAssertTrue(state.retryTimerFired(token: retry.token))
    }

    XCTAssertEqual(delays, [0.1, 0.2, 0.4, 0.8, 1.0, 1.0])
    XCTAssertTrue(state.isPending)
    XCTAssertTrue(state.isScheduled)
  }

  func testLateActionDispatchInvalidatesFallbackWithoutSchedulingAnotherOpen() throws {
    var state = MainWindowRestoreRequestState()
    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    let staleRetry = try XCTUnwrap(state.markActionUnavailable())

    XCTAssertTrue(state.actionBecameAvailable())
    XCTAssertTrue(state.beginScheduledAttempt())
    state.markActionDispatched()

    XCTAssertTrue(state.isActionInFlight)
    XCTAssertFalse(state.request())
    XCTAssertFalse(state.retryTimerFired(token: staleRetry.token))
    XCTAssertTrue(state.isActionInFlight)
    XCTAssertFalse(state.isScheduled)
  }

  func testOldRetryCannotClearANewerActionInFlight() throws {
    var state = MainWindowRestoreRequestState()
    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    let staleRetry = try XCTUnwrap(state.markActionUnavailable())

    XCTAssertTrue(state.actionBecameAvailable())
    XCTAssertTrue(state.beginScheduledAttempt())
    state.markActionDispatched()
    state.markCompleted()

    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    state.markActionDispatched()

    XCTAssertFalse(state.retryTimerFired(token: staleRetry.token))
    XCTAssertTrue(state.isPending)
    XCTAssertTrue(state.isActionInFlight)
    XCTAssertFalse(state.isScheduled)
  }

  func testWindowConfirmationCompletesActionInFlight() {
    var state = MainWindowRestoreRequestState()
    XCTAssertTrue(state.request())
    XCTAssertTrue(state.beginScheduledAttempt())
    state.markActionDispatched()

    state.markCompleted()

    XCTAssertFalse(state.isPending)
    XCTAssertFalse(state.isActionInFlight)
    XCTAssertEqual(state.retryCount, 0)
    XCTAssertFalse(state.isScheduled)
  }
}
