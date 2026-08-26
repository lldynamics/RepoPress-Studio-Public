import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceResponsiveLayoutSnapshotTests: XCTestCase {
  func testEqualWithinSameSemanticLayoutBand() {
    XCTAssertEqual(
      WorkspaceResponsiveLayoutSnapshot(width: 1_300),
      WorkspaceResponsiveLayoutSnapshot(width: 1_470)
    )
  }

  func testChangesAtEveryLayoutDecisionBoundary() {
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumCompactInspectorWorkspaceWidth)
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumInspectorWorkspaceWidth)
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth)
  }

  private func assertBoundaryChanges(at width: CGFloat) {
    XCTAssertNotEqual(
      WorkspaceResponsiveLayoutSnapshot(width: width - 1),
      WorkspaceResponsiveLayoutSnapshot(width: width)
    )
  }
}
