import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

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
    let coordinator = MarkdownFindMatchRefreshCoordinator(debounce: .milliseconds(30))
    var results: [MarkdownFindMatchRefreshResult] = []

    coordinator.schedule(
      text: "old old",
      query: "old",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    coordinator.schedule(
      text: "new new",
      query: "new",
      options: MarkdownFindOptions()
    ) { results.append($0) }

    try await Task.sleep(for: .milliseconds(120))

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.ranges.count, 2)
    XCTAssertNil(results.first?.errorMessage)
    XCTAssertFalse(coordinator.isPending)
  }

  func testInvalidRegularExpressionIsReportedAsynchronously() async throws {
    let coordinator = MarkdownFindMatchRefreshCoordinator(debounce: .milliseconds(20))
    var result: MarkdownFindMatchRefreshResult?

    coordinator.schedule(
      text: "alpha",
      query: "[",
      options: MarkdownFindOptions(usesRegularExpression: true)
    ) { result = $0 }

    XCTAssertNil(result)
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(result?.ranges, [])
    XCTAssertNotNil(result?.errorMessage)
  }

  func testCancelPreventsAStaleResultFromBeingApplied() async throws {
    let coordinator = MarkdownFindMatchRefreshCoordinator(debounce: .milliseconds(20))
    var didApply = false

    coordinator.schedule(
      text: String(repeating: "alpha ", count: 2_000),
      query: "alpha",
      options: MarkdownFindOptions()
    ) { _ in didApply = true }
    coordinator.cancel()

    try await Task.sleep(for: .milliseconds(100))

    XCTAssertFalse(didApply)
    XCTAssertFalse(coordinator.isPending)
  }

  func testRunningScanIsCancelledBeforeLatestResultIsApplied() async throws {
    let gate = MarkdownFindScannerCancellationGate()
    let coordinator = MarkdownFindMatchRefreshCoordinator(
      debounce: .milliseconds(1)
    ) { _, query, _ in
      if query == "old" {
        gate.markStarted()
        while !Task.isCancelled {
          Thread.sleep(forTimeInterval: 0.001)
        }
        gate.markCancelled()
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
    XCTAssertTrue(gate.waitUntilStarted())

    coordinator.schedule(
      text: "new new",
      query: "new",
      options: MarkdownFindOptions()
    ) { results.append($0) }
    XCTAssertTrue(gate.waitUntilCancelled())

    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(
      results,
      [MarkdownFindMatchRefreshResult(
        ranges: [NSRange(location: 4, length: 3)],
        errorMessage: nil
      )]
    )
    XCTAssertFalse(coordinator.isPending)
  }
}

private final class MarkdownFindScannerCancellationGate: @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let cancelled = DispatchSemaphore(value: 0)

  func markStarted() {
    started.signal()
  }

  func markCancelled() {
    cancelled.signal()
  }

  func waitUntilStarted() -> Bool {
    started.wait(timeout: .now() + .seconds(1)) == .success
  }

  func waitUntilCancelled() -> Bool {
    cancelled.wait(timeout: .now() + .seconds(1)) == .success
  }
}
