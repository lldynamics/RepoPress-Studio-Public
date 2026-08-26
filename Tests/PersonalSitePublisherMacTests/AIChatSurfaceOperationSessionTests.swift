import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class AIChatSurfaceOperationSessionTests: XCTestCase {
  func testSceneOwnedOperationSurvivesTransientSurfaceRemovalAndCanStillStop() async {
    let session = AIChatSurfaceOperationSession()
    let ownerToken = UUID()
    let started = expectation(description: "operation started")
    let cancelled = expectation(description: "operation cancelled")

    XCTAssertTrue(
      session.start(ownerToken: ownerToken) {
        started.fulfill()
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected operation error: \(error)")
        }
      }
    )
    await fulfillment(of: [started], timeout: 1)

    // A workspace page switch only removes the Inspector view. Its parent
    // keeps this session alive, so the lifecycle event must not cancel.
    var forwardedOwnerTokens: [UUID] = []
    XCTAssertFalse(
      session.handle(
        .transientSurfaceDisappearance,
        forwardingTo: { forwardedOwnerTokens.append($0) }
      )
    )
    XCTAssertTrue(session.hasActiveTask)
    XCTAssertEqual(session.activeOwnerToken, ownerToken)
    XCTAssertTrue(forwardedOwnerTokens.isEmpty)

    XCTAssertFalse(
      session.handle(
        .explicitStop(ownerToken: UUID()),
        forwardingTo: { forwardedOwnerTokens.append($0) }
      )
    )
    XCTAssertTrue(session.hasActiveTask)
    XCTAssertTrue(forwardedOwnerTokens.isEmpty)

    XCTAssertTrue(
      session.handle(
        .explicitStop(ownerToken: ownerToken),
        forwardingTo: { forwardedOwnerTokens.append($0) }
      )
    )
    XCTAssertEqual(forwardedOwnerTokens, [ownerToken])
    await fulfillment(of: [cancelled], timeout: 1)
    await waitUntilFinished(session)
  }

  func testStaleCompletionCannotClearReplacementOperation() async {
    let session = AIChatSurfaceOperationSession()
    let firstOwnerToken = UUID()
    let firstCompleted = expectation(description: "first operation completed")

    XCTAssertTrue(
      session.start(ownerToken: firstOwnerToken) {
        firstCompleted.fulfill()
      }
    )
    await fulfillment(of: [firstCompleted], timeout: 1)
    await waitUntilFinished(session)

    let secondOwnerToken = UUID()
    let secondStarted = expectation(description: "second operation started")
    let secondCancelled = expectation(description: "second operation cancelled")
    XCTAssertTrue(
      session.start(ownerToken: secondOwnerToken) {
        secondStarted.fulfill()
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
          secondCancelled.fulfill()
        } catch {
          XCTFail("Unexpected operation error: \(error)")
        }
      }
    )
    await fulfillment(of: [secondStarted], timeout: 1)

    session.finish(ownerToken: firstOwnerToken)
    XCTAssertTrue(session.hasActiveTask)
    XCTAssertEqual(session.activeOwnerToken, secondOwnerToken)

    XCTAssertTrue(
      session.handle(
        .explicitStop(ownerToken: secondOwnerToken),
        forwardingTo: { _ in }
      )
    )
    await fulfillment(of: [secondCancelled], timeout: 1)
    await waitUntilFinished(session)
  }

  func testOwnerTeardownReleasesSessionAndForwardsExactOwnerToken() async {
    let session = AIChatSurfaceOperationSession()
    let ownerToken = UUID()
    let started = expectation(description: "operation started")
    let cancelled = expectation(description: "operation cancelled")

    XCTAssertTrue(
      session.start(ownerToken: ownerToken) {
        started.fulfill()
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected operation error: \(error)")
        }
      }
    )
    await fulfillment(of: [started], timeout: 1)

    var forwardedOwnerTokens: [UUID] = []
    XCTAssertTrue(
      session.handle(
        .ownerTeardown,
        forwardingTo: { forwardedOwnerTokens.append($0) }
      )
    )

    XCTAssertEqual(forwardedOwnerTokens, [ownerToken])
    XCTAssertFalse(session.hasActiveTask)
    XCTAssertNil(session.activeOwnerToken)
    await fulfillment(of: [cancelled], timeout: 1)
  }

  private func waitUntilFinished(
    _ session: AIChatSurfaceOperationSession
  ) async {
    for _ in 0..<20 {
      guard session.hasActiveTask else { break }
      await Task.yield()
    }
    XCTAssertFalse(session.hasActiveTask)
    XCTAssertNil(session.activeOwnerToken)
  }
}
