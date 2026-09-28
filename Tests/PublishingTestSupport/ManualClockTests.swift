import XCTest

final class ManualClockTests: XCTestCase {
  func testAdvanceResumesDueSleepersInDeadlineOrder() async throws {
    let clock = ManualClock()
    let later = Task {
      try await clock.sleep(for: .milliseconds(20))
    }
    let earlier = Task {
      try await clock.sleep(for: .milliseconds(10))
    }
    await clock.waitForSleepCount(2)

    XCTAssertEqual(
      clock.pendingDeadlinesInWakeOrder,
      [clock.now.advanced(by: .milliseconds(10)), clock.now.advanced(by: .milliseconds(20))]
    )

    clock.advance(by: .milliseconds(20))
    try await earlier.value
    try await later.value
    XCTAssertEqual(clock.pendingSleepCount, 0)
  }

  func testAdvanceReleasesOnlyDueSleepers() async throws {
    let clock = ManualClock()
    let first = Task { try await clock.sleep(for: .milliseconds(10)) }
    let second = Task { try await clock.sleep(for: .milliseconds(20)) }
    await clock.waitForSleepCount(2)

    clock.advance(by: .milliseconds(9))
    XCTAssertEqual(clock.pendingSleepCount, 2)
    clock.advance(by: .milliseconds(1))
    XCTAssertEqual(clock.pendingSleepCount, 1)
    try await first.value
    clock.advance(by: .milliseconds(10))
    try await second.value
    XCTAssertEqual(clock.pendingSleepCount, 0)
  }

  func testCancellationRemovesSleepWithoutAdvancingTime() async {
    let clock = ManualClock()
    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    await clock.waitForSleepCount(1)

    sleeper.cancel()
    do {
      try await sleeper.value
      XCTFail("Cancelled sleep should throw")
    } catch is CancellationError {
      XCTAssertEqual(clock.pendingSleepCount, 0)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
