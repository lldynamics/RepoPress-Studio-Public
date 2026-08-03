import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceModalPresentationStateTests: XCTestCase {
  func testPresentingAnotherModalReplacesTheCurrentModal() {
    var state = WorkspaceModalPresentationState()

    state.present(.commandPalette)
    state.present(.publishDrawer)

    XCTAssertEqual(state.presented, .publishDrawer)
  }

  func testExpectedDismissDoesNotCloseADifferentModal() {
    var state = WorkspaceModalPresentationState()
    state.present(.draftFullTextSearch)

    state.dismiss(.publishDrawer)
    XCTAssertEqual(state.presented, .draftFullTextSearch)

    state.dismiss(.draftFullTextSearch)
    XCTAssertNil(state.presented)
  }
}
