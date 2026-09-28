import Foundation
import PublishingMarkdownCore
import PublishingTestSupport
import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownFindMatchRefreshCoordinatorTests: XCTestCase {
  func testEmptyQueryPublishesEmptyResultImmediately() {
    let coordinator = MarkdownFindMatchRefreshCoordinator(debounce: .seconds(1))
    var result: MarkdownFindMatchRefreshResult?

    coordinator.schedule(
      text: "alpha alpha",
      query: "",
      options: MarkdownFindOptions()
    ) { result = $0 }

    XCTAssertEqual(result, .empty)
    XCTAssertFalse(coordinator.isPending)
  }

  func testDebouncedRequestPublishesOnlyTheLatestResult() async throws {
    let clock = ManualClock()
    let coordinator = MarkdownFindMatchRefreshCoordinator(
      debounce: .milliseconds(30), clock: clock
    )
    var results: [MarkdownFindMatchRefreshResult] = []

    coordinator.schedule(
      text: "old old",
      query: "old",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    await clock.waitForSleepCount(1)
    coordinator.schedule(
      text: "new new",
      query: "new",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    await clock.waitForSleepCount(2)

    clock.advance(by: .milliseconds(29))
    XCTAssertTrue(results.isEmpty)
    clock.advance(by: .milliseconds(1))
    await coordinator.waitUntilIdle()

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.ranges.count, 2)
    XCTAssertNil(results.first?.errorMessage)
    XCTAssertFalse(coordinator.isPending)
  }

  func testInvalidRegularExpressionIsReportedAsynchronously() async throws {
    let clock = ManualClock()
    let coordinator = MarkdownFindMatchRefreshCoordinator(
      debounce: .milliseconds(20), clock: clock
    )
    var result: MarkdownFindMatchRefreshResult?

    coordinator.schedule(
      text: "alpha",
      query: "[",
      options: MarkdownFindOptions(usesRegularExpression: true)
    ) { result = $0 }

    XCTAssertNil(result)
    await clock.waitForSleepCount(1)
    clock.advance(by: .milliseconds(20))
    await coordinator.waitUntilIdle()

    XCTAssertEqual(result?.ranges, [])
    XCTAssertNotNil(result?.errorMessage)
  }

  func testCancelPreventsAStaleResultFromBeingApplied() async throws {
    let clock = ManualClock()
    let coordinator = MarkdownFindMatchRefreshCoordinator(
      debounce: .milliseconds(20), clock: clock
    )
    var didApply = false

    coordinator.schedule(
      text: String(repeating: "alpha ", count: 2_000),
      query: "alpha",
      options: MarkdownFindOptions()
    ) { _ in didApply = true }
    await clock.waitForSleepCount(1)
    coordinator.cancel()

    clock.advance(by: .milliseconds(20))

    XCTAssertFalse(didApply)
    XCTAssertFalse(coordinator.isPending)
  }

  func testRunningScanIsCancelledBeforeLatestResultIsApplied() async throws {
    let gate = MarkdownFindScannerCancellationGate()
    let clock = ManualClock()
    let coordinator = MarkdownFindMatchRefreshCoordinator(
      debounce: .milliseconds(1), clock: clock
    ) { _, query, _ in
      if query == "old" {
        gate.markStarted()
        gate.waitForRelease()
        if Task.isCancelled { gate.markCancelled() }
        return nil
      }
      return MarkdownFindMatchRefreshResult(
        ranges: [NSRange(location: 4, length: 3)],
        errorMessage: nil
      )
    }
    var results: [MarkdownFindMatchRefreshResult] = []

    coordinator.schedule(
      text: "old old",
      query: "old",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    await clock.waitForSleepCount(1)
    clock.advance(by: .milliseconds(1))
    XCTAssertTrue(gate.waitUntilStarted())

    coordinator.schedule(
      text: "new new",
      query: "new",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    gate.release()
    XCTAssertTrue(gate.waitUntilCancelled())
    await clock.waitForSleepCount(2)

    clock.advance(by: .milliseconds(1))
    await coordinator.waitUntilIdle()

    XCTAssertEqual(
      results,
      [
        MarkdownFindMatchRefreshResult(
          ranges: [NSRange(location: 4, length: 3)],
          errorMessage: nil
        )
      ]
    )
    XCTAssertFalse(coordinator.isPending)
  }

  func testReplacementPlanningProducesAnUndoableCurrentEdit() async {
    let coordinator = MarkdownFindReplacePlanningCoordinator()
    let received = expectation(description: "replacement plan")
    var result: MarkdownFindReplacePlanningCoordinator.Result?
    coordinator.schedule(
      .init(
        kind: .current(selectedRange: NSRange(location: 0, length: 0)),
        body: "alpha alpha",
        scopeRange: NSRange(location: 0, length: 11),
        query: "alpha",
        replacement: "beta",
        options: MarkdownFindOptions()
      )
    ) {
      result = $0
      received.fulfill()
    }
    await fulfillment(of: [received], timeout: 1)
    await coordinator.waitUntilIdle()
    guard case .current(let edit?) = result else {
      return XCTFail("Expected a current replacement edit")
    }
    XCTAssertEqual(edit.edit.replacedRange, NSRange(location: 0, length: 5))
    XCTAssertEqual(edit.edit.replacement, "beta")
  }

  func testReplacementPlanningCancelPreventsAStalePlanFromApplying() async {
    let gate = MarkdownReplacementPlanningGate()
    let coordinator = MarkdownFindReplacePlanningCoordinator { request in
      gate.markStarted()
      gate.waitForRelease()
      return .failure("stale \(request.query)")
    }
    var applied = false
    coordinator.schedule(
      .init(
        kind: .current(selectedRange: NSRange(location: 0, length: 0)),
        body: "alpha", scopeRange: NSRange(location: 0, length: 5),
        query: "alpha", replacement: "beta", options: MarkdownFindOptions()
      )
    ) { _ in applied = true }
    XCTAssertTrue(gate.waitUntilStarted())
    coordinator.cancel()
    gate.release()
    await coordinator.waitUntilIdle()
    XCTAssertFalse(applied)
    XCTAssertFalse(coordinator.isPending)
  }
}

private final class MarkdownFindScannerCancellationGate: @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let cancelled = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  func markStarted() {
    started.signal()
  }

  func markCancelled() {
    cancelled.signal()
  }

  func waitForRelease() {
    released.wait()
  }

  func release() {
    released.signal()
  }

  func waitUntilStarted() -> Bool {
    started.wait(timeout: .now() + .seconds(1)) == .success
  }

  func waitUntilCancelled() -> Bool {
    cancelled.wait(timeout: .now() + .seconds(1)) == .success
  }
}

private final class MarkdownReplacementPlanningGate: Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  func markStarted() { started.signal() }
  func waitForRelease() { released.wait() }
  func release() { released.signal() }
  func waitUntilStarted() -> Bool {
    started.wait(timeout: .now() + .seconds(1)) == .success
  }
}
