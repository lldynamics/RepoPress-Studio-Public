import XCTest

@testable import PublishingAICore

final class SelectionActionBarPresentationTests: XCTestCase {
  func testSelectionActionBarShowsForSelectionRunningActionOrMessage() {
    XCTAssertFalse(
      SelectionActionBarPresentation.shouldShow(
        hasSelectedText: false,
        isSelectionAIActionRunning: false,
        selectionActionMessage: ""
      )
    )

    XCTAssertTrue(
      SelectionActionBarPresentation.shouldShow(
        hasSelectedText: true,
        isSelectionAIActionRunning: false,
        selectionActionMessage: ""
      )
    )

    XCTAssertTrue(
      SelectionActionBarPresentation.shouldShow(
        hasSelectedText: false,
        isSelectionAIActionRunning: true,
        selectionActionMessage: ""
      )
    )

    XCTAssertTrue(
      SelectionActionBarPresentation.shouldShow(
        hasSelectedText: false,
        isSelectionAIActionRunning: false,
        selectionActionMessage: "润色选中文本处理中..."
      )
    )

    XCTAssertFalse(
      SelectionActionBarPresentation.shouldShow(
        hasSelectedText: false,
        isSelectionAIActionRunning: false,
        selectionActionMessage: "   "
      )
    )
  }
}
