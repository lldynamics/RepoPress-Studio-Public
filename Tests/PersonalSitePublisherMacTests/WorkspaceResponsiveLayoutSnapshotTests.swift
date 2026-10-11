import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceResponsiveLayoutSnapshotTests: XCTestCase {
  func testInspectorWaitsForFirstMeasuredWindowWidth() {
    let initial = WorkspaceResponsiveLayoutSnapshot.initial
    XCTAssertFalse(initial.canManuallyRevealInspector(for: .writing))
    XCTAssertEqual(initial.band, .constrained)
    XCTAssertFalse(initial.allowsStandardInspector)

    let measured = WorkspaceResponsiveLayoutSnapshot(
      width: WorkbenchLayoutMode.minimumInspectorWorkspaceWidth)
    XCTAssertEqual(measured.band, .standardInspector)
    XCTAssertTrue(measured.allowsStandardInspector)
  }

  func testEqualWithinSameSemanticLayoutBand() {
    assertSameBand(900, 959)
    assertSameBand(960, 1_243)
    assertSameBand(1_244, 1_473)
  }

  func testChangesAtEveryLayoutDecisionBoundary() {
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumCompactInspectorWorkspaceWidth)
    assertBoundaryChanges(at: WorkbenchLayoutMode.minimumInspectorWorkspaceWidth)
  }

  func testNarrowingWindowHidesInspectorBeforeArticleList() {
    let wide = WorkspaceResponsiveLayoutSnapshot(width: 1_440)
    XCTAssertTrue(wide.allowsStandardInspector)
    XCTAssertFalse(wide.collapsesContextSidebar)

    let narrower = WorkspaceResponsiveLayoutSnapshot(width: 1_180)
    XCTAssertFalse(narrower.allowsStandardInspector)
    XCTAssertFalse(narrower.collapsesContextSidebar)

    XCTAssertTrue(WorkspaceResponsiveLayoutSnapshot(width: 900).collapsesContextSidebar)
  }

  func testCompactInspectorOverrideIncludesAllContextualSurfaces() {
    let compactInspector = WorkspaceResponsiveLayoutSnapshot(width: 1_000)

    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .writing))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .library))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .rss))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .sync))
    XCTAssertTrue(compactInspector.canManuallyRevealInspector(for: .contentHealth))

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
