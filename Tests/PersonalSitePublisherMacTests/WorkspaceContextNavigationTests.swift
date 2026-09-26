import Foundation
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceContextNavigationTests: XCTestCase {
  func testCompactInspectorUsesRailOnlyAcrossTheManualInspectorBand() {
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 959).band, .constrained)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 960).band, .compactInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_179).band, .compactInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_180).band, .standardInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_240).band, .htmlSourceInspector)
  }

  func testCompactRailExposesTheFiveDirectWorkspaceRoutes() {
    XCTAssertEqual(
      WorkspaceCompactNavigationRail.primarySections,
      [.writing, .library, .rss, .sync, .contentHealth]
    )
  }

  func testFullAndCompactRailsShareTheCommandShortcutOrder() {
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primaryRows,
      [[.writing, .library], [.rss, .sync], [.contentHealth]]
    )
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primaryRows.flatMap { $0 },
      WorkspaceCompactNavigationRail.primarySections
    )
    XCTAssertEqual(
      Set(WorkspaceCompactNavigationRail.primarySections).count,
      5
    )
  }

  func testSectionSwitchKeepsAnExistingDraftContextAvailableToTheWindowSession() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .rss, selectedDraftID: draftID)

    session.selectSection(.library) { _ in }

    XCTAssertEqual(session.selectedSection, .library)
    XCTAssertEqual(session.selectedDraftID, draftID)
  }

}
