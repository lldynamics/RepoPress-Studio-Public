import PublishingTestSupport
import XCTest
@testable import PublishingMarkdownCore

@MainActor
final class MarkdownSyntaxHighlightDebouncerTests: XCTestCase {
  func testRapidRequestsCoalesceBeforeComputationAndDeliverOnlyLatestValue() async {
    let clock = ManualClock()
    let debouncer = MarkdownSyntaxHighlightDebouncer(clock: clock)
    let recorder = MarkdownSyntaxHighlightValueRecorder<Int>()

    for requestID in 0..<12 {
      debouncer.schedule(delay: 0.02) {
        requestID
      } onValue: { value in
        recorder.values.append(value)
      }
      await clock.waitForSleepCount(requestID + 1)
    }

    XCTAssertEqual(recorder.values, [])
    XCTAssertEqual(debouncer.metrics.startedComputationCount, 0)

    clock.advance(by: .milliseconds(20))
    await debouncer.waitUntilIdle()

    XCTAssertEqual(recorder.values, [11])
    XCTAssertEqual(
      debouncer.metrics,
      MarkdownSyntaxHighlightDebouncerMetrics(
        scheduledRequestCount: 12,
        startedComputationCount: 1,
        deliveredResultCount: 1
      )
    )
    XCTAssertEqual(debouncer.metrics.coalescedBeforeComputationCount, 11)
  }

  func testCancellationPreventsComputationBeforeDeadline() async {
    let clock = ManualClock()
    let debouncer = MarkdownSyntaxHighlightDebouncer(clock: clock)
    let recorder = MarkdownSyntaxHighlightValueRecorder<Int>()

    debouncer.schedule(delay: 0.02) {
      1
    } onValue: { value in
      recorder.values.append(value)
    }

    await clock.waitForSleepCount(1)
    debouncer.cancel()
    clock.advance(by: .milliseconds(20))
    await debouncer.waitUntilIdle()

    XCTAssertEqual(recorder.values, [])
    XCTAssertEqual(debouncer.metrics.scheduledRequestCount, 1)
    XCTAssertEqual(debouncer.metrics.startedComputationCount, 0)
    XCTAssertEqual(debouncer.metrics.deliveredResultCount, 0)
  }

  func testReplacementRejectsResultFromAlreadyStartedComputation() async {
    let clock = ManualClock()
    let debouncer = MarkdownSyntaxHighlightDebouncer(clock: clock)
    let recorder = MarkdownSyntaxHighlightValueRecorder<Int>()
    let staleOperationGate = MarkdownSyntaxHighlightAsyncGate()

    debouncer.schedule(delay: 0.02) {
      await staleOperationGate.wait()
      return 1
    } onValue: { value in
      recorder.values.append(value)
    }

    await clock.waitForSleepCount(1)
    clock.advance(by: .milliseconds(20))
    await staleOperationGate.waitUntilStarted()
    XCTAssertEqual(debouncer.metrics.startedComputationCount, 1)

    debouncer.schedule(delay: 0.02) {
      2
    } onValue: { value in
      recorder.values.append(value)
    }

    await clock.waitForSleepCount(2)
    clock.advance(by: .milliseconds(20))
    await debouncer.waitUntilIdle()

    await staleOperationGate.open()
    await staleOperationGate.waitUntilFinished()
    await Task.yield()

    XCTAssertEqual(recorder.values, [2])
    XCTAssertEqual(debouncer.metrics.scheduledRequestCount, 2)
    XCTAssertEqual(debouncer.metrics.startedComputationCount, 2)
    XCTAssertEqual(debouncer.metrics.deliveredResultCount, 1)
  }
}

@MainActor
private final class MarkdownSyntaxHighlightValueRecorder<Value: Sendable> {
  var values: [Value] = []
}

private actor MarkdownSyntaxHighlightAsyncGate {
  private var isOpen = false
  private var hasStarted = false
  private var hasFinished = false
  private var operationWaiter: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var finishWaiter: CheckedContinuation<Void, Never>?

  func wait() async {
    hasStarted = true
    startWaiter?.resume()
    startWaiter = nil
    if !isOpen {
      await withCheckedContinuation { operationWaiter = $0 }
    }
    hasFinished = true
    finishWaiter?.resume()
    finishWaiter = nil
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func waitUntilFinished() async {
    guard !hasFinished else { return }
    await withCheckedContinuation { finishWaiter = $0 }
  }

  func open() {
    isOpen = true
    operationWaiter?.resume()
    operationWaiter = nil
  }
}
