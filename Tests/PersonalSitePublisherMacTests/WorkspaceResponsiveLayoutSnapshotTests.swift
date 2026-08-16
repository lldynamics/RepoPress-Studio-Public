import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceResponsiveLayoutSnapshotTests: XCTestCase {
  func testEqualWithinSameSemanticLayoutBand() {
    XCTAssertEqual(
      WorkspaceResponsiveLayoutSnapshot(width: 1_300, editorDisplayMode: .edit),
      WorkspaceResponsiveLayoutSnapshot(width: 1_470, editorDisplayMode: .edit)
    )
  }

  func testChangesAtEveryLayoutDecisionBoundary() {
    assertBoundaryChanges(
      at: WorkbenchLayoutMode.minimumCompactInspectorWorkspaceWidth,
      mode: .edit
    )
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumSplitSidebarWorkspaceWidth, mode: .split)
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumInspectorWorkspaceWidth, mode: .split)
    assertBoundaryChanges(
      at: WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth, mode: .split)
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumSplitInspectorWorkspaceWidth, mode: .split)
  }

  func testEditorDisplayModeRemainsPartOfLayoutIdentity() {
    XCTAssertNotEqual(
      WorkspaceResponsiveLayoutSnapshot(width: 1_300, editorDisplayMode: .edit),
      WorkspaceResponsiveLayoutSnapshot(width: 1_300, editorDisplayMode: .split)
    )
  }

  private func assertBoundaryChanges(at width: CGFloat, mode: EditorDisplayMode) {
    XCTAssertNotEqual(
      WorkspaceResponsiveLayoutSnapshot(width: width - 1, editorDisplayMode: mode),
      WorkspaceResponsiveLayoutSnapshot(width: width, editorDisplayMode: mode)
    )
  }
}
