import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceModalPresentationStateTests: XCTestCase {
  func testPresentingAnotherModalReplacesTheCurrentModal() {
    var state = WorkspaceModalPresentationState()

    state.present(.commandPalette)
    state.present(.publish)

    XCTAssertEqual(state.presented, .publish)
  }

  func testExpectedDismissDoesNotCloseADifferentModal() {
    var state = WorkspaceModalPresentationState()
    state.present(.commandPalette)

    state.dismiss(.publish)
    XCTAssertEqual(state.presented, .commandPalette)

    state.dismiss(.commandPalette)
    XCTAssertNil(state.presented)
  }

  func testCompactPublishUsesTheSingleModalSlotAndCannotDismissAnotherConfirmation() {
    var state = WorkspaceModalPresentationState()
    state.present(.compactPublishInspector)
    XCTAssertEqual(state.presented, .compactPublishInspector)
    state.present(.publish)
    state.dismiss(.compactPublishInspector)
    XCTAssertEqual(state.presented, .publish)
  }
}
