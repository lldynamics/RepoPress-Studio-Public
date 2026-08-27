import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceResponsiveLayoutSnapshotTests: XCTestCase {
  func testEqualWithinSameSemanticLayoutBand() {
    assertSameBand(900, 959)
    assertSameBand(960, 1_179)
    assertSameBand(1_180, 1_239)
    assertSameBand(1_240, 1_473)
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

  private func assertSameBand(_ lhs: CGFloat, _ rhs: CGFloat) {
    XCTAssertEqual(
      WorkspaceResponsiveLayoutSnapshot(width: lhs),
      WorkspaceResponsiveLayoutSnapshot(width: rhs)
    )
  }
}
