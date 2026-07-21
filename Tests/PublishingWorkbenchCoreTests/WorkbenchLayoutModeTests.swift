import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchLayoutModeTests: XCTestCase {
  func testDefaultWindowSizeStartsInExpandedInspectorLayout() {
    XCTAssertEqual(WorkbenchLayoutMode.defaultWindowWidth, 1440)
    XCTAssertEqual(WorkbenchLayoutMode.defaultWindowHeight, 900)
    XCTAssertGreaterThanOrEqual(
      WorkbenchLayoutMode.defaultWindowWidth,
      WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
    )
    XCTAssertFalse(WorkbenchLayoutMode.isCompact(width: WorkbenchLayoutMode.defaultWindowWidth))
  }

  func testRuntimeLayoutUsesCompactShellAtMinimum980Width() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumWindowWidth, 980)
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 980))
  }

  func testRuntimeLayoutUsesExpandedShellAt1180Width() {
    XCTAssertFalse(WorkbenchLayoutMode.isCompact(width: 1180))
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 1179))
  }

  func testInspectorIsTemporarilyHiddenUntilWorkspaceCanFitThreeColumns() {
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 980))
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 1179))
    XCTAssertTrue(WorkbenchLayoutMode.allowsInspector(width: 1180))
  }

  func testSplitEditorRequiresMoreWidthBeforeShowingInspector() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumSplitInspectorWorkspaceWidth, 1580)
    XCTAssertFalse(
      WorkbenchLayoutMode.allowsInspector(width: 1579, editorDisplayMode: .split)
    )
    XCTAssertTrue(
      WorkbenchLayoutMode.allowsInspector(width: 1580, editorDisplayMode: .split)
    )
    XCTAssertTrue(
      WorkbenchLayoutMode.allowsInspector(width: 1180, editorDisplayMode: .edit)
    )
  }

  func testNarrowSplitEditorPrefersFocusedWritingLayout() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumSplitSidebarWorkspaceWidth, 1100)
    XCTAssertTrue(
      WorkbenchLayoutMode.prefersFocusedWriting(width: 1099, editorDisplayMode: .split)
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.prefersFocusedWriting(width: 1100, editorDisplayMode: .split)
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.prefersFocusedWriting(width: 980, editorDisplayMode: .edit)
    )
  }

  func testInspectorLayoutTemporarilyCompressesWideSidebar() {
    XCTAssertEqual(
      WorkbenchLayoutMode.sidebarWidth(
        storedWidth: 380,
        workspaceWidth: 1180,
        centerMinimumWidth: 560,
        inspectorPresented: true
      ),
      300
    )
    XCTAssertEqual(
      WorkbenchLayoutMode.sidebarWidth(
        storedWidth: 380,
        workspaceWidth: 1440,
        centerMinimumWidth: 560,
        inspectorPresented: true
      ),
      380
    )
  }

  func testHTMLSourceInspectorRequiresRoomForBothSourceColumns() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth, 1240)
    XCTAssertEqual(
      WorkbenchLayoutMode.sidebarWidth(
        storedWidth: 380,
        workspaceWidth: 1240,
        centerMinimumWidth: 680,
        inspectorPresented: true
      ),
      240
    )
  }
}
