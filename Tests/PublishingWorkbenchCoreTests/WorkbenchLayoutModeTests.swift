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

  func testInspectorIsTemporarilyHiddenUntilWorkspaceCanFitThreeColumns() {
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 980))
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 1179))
    XCTAssertTrue(WorkbenchLayoutMode.allowsInspector(width: 1180))
  }
}
