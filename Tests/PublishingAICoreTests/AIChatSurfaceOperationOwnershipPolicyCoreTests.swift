import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatSurfaceOperationOwnershipPolicyCoreTests: XCTestCase {
  func testLocalTaskOwnershipRequiresTaskAndOwnerToken() {
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.ownsLocalTask(
        localTaskExists: false,
        ownerToken: nil
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.ownsLocalTask(
        localTaskExists: false,
        ownerToken: UUID()
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.ownsLocalTask(
        localTaskExists: true,
        ownerToken: nil
      )
    )
    XCTAssertTrue(
      AIChatSurfaceOperationOwnershipPolicy.ownsLocalTask(
        localTaskExists: true,
        ownerToken: UUID()
      )
    )
  }

  func testCancellationUsesTheSameOwnershipTruthTable() {
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: false,
        ownerToken: nil
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: false,
        ownerToken: UUID()
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: true,
        ownerToken: nil
      )
    )
    XCTAssertTrue(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: true,
        ownerToken: UUID()
      )
    )
  }

  func testStartingRequiresNoLocalTaskAndNoGlobalOperation() {
    XCTAssertTrue(
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: false,
        globalOperationRunning: false
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: true,
        globalOperationRunning: false
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: false,
        globalOperationRunning: true
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: true,
        globalOperationRunning: true
      )
    )
  }
}
