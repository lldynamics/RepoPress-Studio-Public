import XCTest

@testable import PersonalSitePublisherMac

final class WorkbenchLayoutModeTests: XCTestCase {
  func testDefaultWindowSizeStartsInExpandedInspectorLayout() {
    XCTAssertEqual(WorkbenchLayoutMode.defaultWindowWidth, 1473)
    XCTAssertEqual(WorkbenchLayoutMode.defaultWindowHeight, 768)
    XCTAssertEqual(WorkbenchLayoutMode.defaultSidebarWidth, 300)
    XCTAssertGreaterThanOrEqual(
      WorkbenchLayoutMode.defaultWindowWidth,
      WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
    )
    XCTAssertFalse(WorkbenchLayoutMode.isCompact(width: WorkbenchLayoutMode.defaultWindowWidth))
  }

  func testRuntimeLayoutUsesCompactShellAtMinimum900Width() {
    XCTAssertEqual(WorkbenchLayoutMode.minimumWindowWidth, 900)
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 900))
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

  func testCompactWritingCanRevealInspectorByYieldingSidebar() {
    XCTAssertFalse(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 959)
    )
    XCTAssertTrue(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 960)
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 1180)
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

  func testSidebarNarrowsWithTheWindowWithoutInspector() {
    func width(_ workspaceWidth: CGFloat) -> CGFloat {
      WorkbenchLayoutMode.sidebarWidth(
        storedWidth: 300,
        workspaceWidth: workspaceWidth,
        centerMinimumWidth: 460,
        inspectorPresented: false
      )
    }
    XCTAssertEqual(width(900), 240)
    XCTAssertEqual(width(1_000), 260)
    XCTAssertEqual(width(1_473), 300)
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
