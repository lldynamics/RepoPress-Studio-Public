import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkbenchLayoutModeTests: XCTestCase {
  func testRestoredWindowsExpandOnceAndLaterResizingSurvivesBridgeRecreation() throws {
    _ = NSApplication.shared
    let firstWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let firstContent = try XCTUnwrap(firstWindow.contentView)
    let firstBridge = MainWindowSizingView()
    firstContent.addSubview(firstBridge)
    let screen = try XCTUnwrap(firstWindow.screen ?? NSScreen.main)
    let expectedWidth =
      screen.visibleFrame.width >= WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
      ? min(WorkbenchLayoutMode.defaultWindowWidth, screen.visibleFrame.width)
      : 1080
    XCTAssertEqual(firstWindow.contentLayoutRect.width, expectedWidth, accuracy: 1)

    firstWindow.setContentSize(NSSize(width: 1080, height: 720))
    firstBridge.removeFromSuperview()
    firstContent.addSubview(MainWindowSizingView())
    XCTAssertEqual(firstWindow.contentLayoutRect.width, 1080, accuracy: 1)

    let secondWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let secondContent = try XCTUnwrap(secondWindow.contentView)
    secondContent.addSubview(MainWindowSizingView())
    XCTAssertEqual(secondWindow.contentLayoutRect.width, expectedWidth, accuracy: 1)
  }

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

  func testRuntimeLayoutUsesExpandedShellWhenRailAndThreeColumnsFit() {
    XCTAssertFalse(WorkbenchLayoutMode.isCompact(width: 1244))
    XCTAssertTrue(WorkbenchLayoutMode.isCompact(width: 1243))
  }

  func testInspectorIsTemporarilyHiddenUntilWorkspaceCanFitThreeColumns() {
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 980))
    XCTAssertFalse(WorkbenchLayoutMode.allowsInspector(width: 1243))
    XCTAssertTrue(WorkbenchLayoutMode.allowsInspector(width: 1244))
    XCTAssertEqual(
      WorkbenchLayoutMode.minimumInspectorWorkspaceWidth,
      62 + 2 + 300 + 560 + 320,
      "The standard band must fit the rail, default sidebar, editor, and Inspector at its ideal width."
    )
  }

  func testCompactWritingCanRevealInspectorByYieldingSidebar() {
    XCTAssertFalse(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 959)
    )
    XCTAssertTrue(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 960)
    )
    XCTAssertFalse(
      WorkbenchLayoutMode.canManuallyRevealInspector(width: 1244)
    )
  }

  func testInspectorLayoutTemporarilyCompressesWideSidebar() {
    XCTAssertEqual(
      WorkbenchLayoutMode.sidebarWidth(
        storedWidth: 380,
        workspaceWidth: 1244,
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
    XCTAssertEqual(width(1_000), 243.36, accuracy: 0.001)
    XCTAssertEqual(width(1_473), 300)
  }

}
