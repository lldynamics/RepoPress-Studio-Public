import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIChatSurfaceOperationOwnershipPolicyTests: XCTestCase {
  func testInspectorWithoutLocalTaskCannotCancelWindowOperation() {
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: false,
        ownerToken: nil
      )
    )
    XCTAssertTrue(
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: true,
        ownerToken: UUID()
      )
    )
    XCTAssertFalse(
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: false,
        globalOperationRunning: true
      )
    )
  }

  @MainActor
  func testSurfaceTokenCannotCancelForeignOperationButOwnedOperationCanStop() {
    let coordinator = AIChatOperationCoordinator()
    let foreignOwnerToken = UUID()
    let surfaceOwnerToken = UUID()

    let operationID = coordinator.begin(ownerToken: foreignOwnerToken)
    XCTAssertNotNil(operationID)
    XCTAssertFalse(
      coordinator.requestCancellation(
        whileRunning: true,
        expectedOwnerToken: surfaceOwnerToken
      )
    )
    XCTAssertFalse(coordinator.isCancellationRequested)
    XCTAssertTrue(
      coordinator.requestCancellation(
        whileRunning: true,
        expectedOwnerToken: foreignOwnerToken
      )
    )
    XCTAssertTrue(coordinator.isCancellationRequested)
    guard let operationID else {
      return XCTFail("expected the foreign operation to be admitted")
    }
    XCTAssertTrue(coordinator.finish(operationID))
  }
}
