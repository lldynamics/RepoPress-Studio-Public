import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceModalPresentationStateTests: XCTestCase {
  func testPresentingAnotherModalReplacesTheCurrentModal() {
    var state = WorkspaceModalPresentationState()

    state.present(.commandPalette)
    state.present(.singleArticlePublishConfirmation)

    XCTAssertEqual(state.presented, .singleArticlePublishConfirmation)
  }

  func testExpectedDismissDoesNotCloseADifferentModal() {
    var state = WorkspaceModalPresentationState()
    state.present(.commandPalette)

    state.dismiss(.singleArticlePublishConfirmation)
    XCTAssertEqual(state.presented, .commandPalette)

    state.dismiss(.commandPalette)
    XCTAssertNil(state.presented)
  }

  func testCompactPublishUsesTheSingleModalSlotAndCannotDismissAnotherConfirmation() {
    var state = WorkspaceModalPresentationState()
    state.present(.compactPublishInspector)
    XCTAssertEqual(state.presented, .compactPublishInspector)
    state.present(.singleArticlePublishConfirmation)
    state.dismiss(.compactPublishInspector)
    XCTAssertEqual(state.presented, .singleArticlePublishConfirmation)
  }
}
