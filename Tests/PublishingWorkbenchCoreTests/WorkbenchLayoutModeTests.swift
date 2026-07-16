import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchLayoutModeTests: XCTestCase {
  func testRuntimeLayoutUsesCompactShellAtMinimum980Width() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumWindowWidth, 980)
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 980))
  }

  func testRuntimeLayoutUsesExpandedShellAt1180Width() {
    XCTAssertFalse(WorkbenchLayoutMode.isCompact(width: 1180))
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 1179))
  }

  func testSplitEditorAutoHidesAuxiliaryPanelsBelowComfortableWidth() {
    XCTAssertTrue(
      WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
        editorDisplayMode: .split,
        width: WorkbenchLayoutMode.comfortableSplitWorkspaceWidth - 1
      )
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
        editorDisplayMode: .split,
        width: WorkbenchLayoutMode.comfortableSplitWorkspaceWidth
      )
    )
  }

  func testSinglePaneEditorKeepsAuxiliaryPanelsAtNarrowerExpandedWidth() {
    XCTAssertFalse(
      WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
        editorDisplayMode: .edit,
        width: WorkbenchLayoutMode.expandedWorkspaceWidth
      )
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
        editorDisplayMode: .preview,
        width: WorkbenchLayoutMode.expandedWorkspaceWidth
      )
    )
  }

  func testMinimumWindowWidthAutoHidesInspectorForEveryEditorMode() {
    for mode in EditorDisplayMode.allCases {
      XCTAssertTrue(
        WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
          editorDisplayMode: mode,
          width: WorkbenchLayoutMode.minimumWindowWidth
        )
      )
    }
  }
}
