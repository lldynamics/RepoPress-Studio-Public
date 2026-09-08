import XCTest

@testable import PersonalSitePublisherMac

final class UIOptimizationWorkspaceTests: XCTestCase {
  func testPointerSelectionChangesReturnTargetWithoutScrolling() {
    var selection = WorkspaceCommandPaletteSelection()
    selection.synchronize(with: ["new", "save", "ai"])
    let initialRevision = selection.scrollRevision
    selection.select("save")
    XCTAssertEqual(selection.selectedID, "save")
    XCTAssertEqual(selection.scrollRevision, initialRevision)
    selection.move(by: 1, among: ["new", "save", "ai"])
    XCTAssertEqual(selection.selectedID, "ai")
    XCTAssertEqual(selection.scrollRevision, initialRevision + 1)
  }

  func testFilteringCannotLeaveAnInvisibleActivationTarget() {
    var selection = WorkspaceCommandPaletteSelection()
    selection.select("old")
    selection.synchronize(with: ["new", "save"])
    XCTAssertEqual(selection.selectedID, "new")
    selection.move(by: -1, among: ["new", "save"])
    XCTAssertEqual(selection.selectedID, "save")
    selection.synchronize(with: [])
    XCTAssertNil(selection.selectedID)
  }

  func testAIRequestWaitsForBothSheetDismissalAndPresentingWindow() {
    var state = WorkspaceDeferredAIRequestState()
    let draftID = UUID()
    state.enqueue(draftID: draftID, quickPrompt: nil)
    XCTAssertNil(state.consume(isKeyWindow: true))
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: false))
    XCTAssertEqual(state.consume(isKeyWindow: true)?.draftID, draftID)
    XCTAssertNil(state.consume(isKeyWindow: true))
  }

  func testQuickHideCancelsDeferredAIRequest() {
    var state = WorkspaceDeferredAIRequestState()
    state.enqueue(draftID: UUID(), quickPrompt: nil)
    state.cancel()
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: true))
  }
}
