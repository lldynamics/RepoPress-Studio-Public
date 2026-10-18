import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceDeferredPublishIssueStateTests: XCTestCase {
  func testDestinationWaitsForSheetDismissalAndItsKeyWindow() {
    let profileID = UUID()
    let draftID = UUID()
    var state = WorkspaceDeferredPublishIssueState()
    state.enqueue(
      profileID: profileID, draftID: draftID, target: .metadata(field: "slug"))
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: profileID))
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: false, currentProfileID: profileID))
    let request = state.consume(isKeyWindow: true, currentProfileID: profileID)
    XCTAssertEqual(request?.draftID, draftID)
    XCTAssertEqual(request?.target, .metadata(field: "slug"))
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: profileID))
  }

  func testDestinationCannotNavigateAfterTheSiteChanges() {
    let profileID = UUID()
    var state = WorkspaceDeferredPublishIssueState()
    state.enqueue(profileID: profileID, draftID: UUID(), target: .repository)
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: UUID()))
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: profileID))
  }

  func testAReplacementDestinationRequiresItsOwnDismissal() {
    let profileID = UUID()
    let replacementID = UUID()
    var state = WorkspaceDeferredPublishIssueState()
    state.enqueue(
      profileID: profileID, draftID: UUID(), target: .metadata(field: "slug"))
    state.sheetDidDismiss()
    state.enqueue(
      profileID: profileID, draftID: replacementID, target: .repository)
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: profileID))
    state.sheetDidDismiss()
    XCTAssertEqual(
      state.consume(isKeyWindow: true, currentProfileID: profileID)?.draftID, replacementID)
  }

  func testCancelledDestinationNeverNavigates() {
    let profileID = UUID()
    var state = WorkspaceDeferredPublishIssueState()
    state.enqueue(
      profileID: profileID, draftID: UUID(), target: .metadata(field: "slug"))
    state.cancel()
    state.sheetDidDismiss()
    XCTAssertNil(state.consume(isKeyWindow: true, currentProfileID: profileID))
  }
}
