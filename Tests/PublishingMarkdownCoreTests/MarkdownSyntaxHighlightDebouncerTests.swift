import XCTest
@testable import PublishingMarkdownCore

@MainActor
final class MarkdownSyntaxHighlightDebouncerTests: XCTestCase {
  func testRapidRequestsCoalesceBeforeComputationAndDeliverOnlyLatestValue() async {
    let debouncer = MarkdownSyntaxHighlightDebouncer()
    let recorder = MarkdownSyntaxHighlightValueRecorder<Int>()

    for requestID in 0..<12 {
      debouncer.schedule(delay: 0.02) {
        requestID
      } onValue: { value in
        recorder.values.append(value)
      }
    }
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

  func testReplacementRejectsResultFromAlreadyStartedComputation() async {
    let debouncer = MarkdownSyntaxHighlightDebouncer()
    let recorder = MarkdownSyntaxHighlightValueRecorder<Int>()

    debouncer.schedule(delay: 0) {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {}
      return 1
    } onValue: { value in
      recorder.values.append(value)
    }

    for _ in 0..<1_000 where debouncer.metrics.startedComputationCount == 0 {
      await Task.yield()
    }
    XCTAssertEqual(debouncer.metrics.startedComputationCount, 1)

    debouncer.schedule(delay: 0) {
      2
    } onValue: { value in
      recorder.values.append(value)
    }
    await debouncer.waitUntilIdle()

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
