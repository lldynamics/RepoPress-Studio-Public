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
    state.present(.commandPalette)

    state.dismiss(.publishDrawer)
    XCTAssertEqual(state.presented, .commandPalette)

    state.dismiss(.commandPalette)
    XCTAssertNil(state.presented)
  }
}
