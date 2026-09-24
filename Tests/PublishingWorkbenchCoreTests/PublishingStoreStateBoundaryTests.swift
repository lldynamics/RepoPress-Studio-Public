import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class PublishingStoreStateBoundaryTests: XCTestCase {
  func testChildStoresPublishOnlyTheirOwnedStateAndForwardCompatibilityChanges() throws {
    let workbench = try TestWorkbenchFactory.makeStore(prefix: "publishing-state-boundary")
    let publishing = workbench.publishingStore
    var rootChanges = 0
    var sessionChanges = 0

    let rootCancellable = publishing.objectWillChange.sink { rootChanges += 1 }
    let sessionCancellable = publishing.publishSession.objectWillChange.sink {
      sessionChanges += 1
    }

    publishing.lastSaveStatus = "已保存"

    XCTAssertEqual(rootChanges, 1)
    XCTAssertEqual(sessionChanges, 0)

    publishing.publishActionFeedback = PublishActionFeedback(
      message: "发布会话状态",
      status: .information
    )

    XCTAssertEqual(rootChanges, 2)
    XCTAssertEqual(sessionChanges, 1)
    XCTAssertEqual(publishing.publishSession.publishActionFeedback?.message, "发布会话状态")

    withExtendedLifetime((rootCancellable, sessionCancellable)) {}
  }
}
