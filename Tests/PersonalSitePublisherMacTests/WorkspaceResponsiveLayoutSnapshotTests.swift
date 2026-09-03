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

  func testCompactInspectorOverrideIncludesWritingKnowledgeAndRSSOnly() {
    let compactInspector = WorkspaceResponsiveLayoutSnapshot(width: 1_000)

    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .writing))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .library))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .rss))
    XCTAssertFalse(compactInspector.canManuallyRevealInspector(for: .sync))
    XCTAssertFalse(compactInspector.canManuallyRevealInspector(for: .contentHealth))

    let constrained = WorkspaceResponsiveLayoutSnapshot(width: 959)
    XCTAssertFalse(constrained.canManuallyRevealInspector(for: .library))
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
