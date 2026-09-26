import Foundation
import PublishingWorkbenchCore
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

  func testCompactRailExposesTheSixDirectWorkspaceRoutes() {
    XCTAssertEqual(
      WorkspaceCompactNavigationRail.primarySections,
      [.writing, .library, .rss, .sync, .contentHealth, .images]
    )
  }

  func testFullAndCompactRailsShareTheCommandShortcutOrder() {
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primarySections,
      WorkspaceNavigationPresentation.commandMenuItems.map(\.section)
    )
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primarySections,
      WorkspaceCompactNavigationRail.primarySections
    )
    XCTAssertEqual(
      Set(WorkspaceCompactNavigationRail.primarySections).count,
      6
    )
    XCTAssertEqual(WorkspaceNavigationRouteDescriptor.primarySection(for: .images), .images)
  }

  func testSectionSwitchKeepsAnExistingDraftContextAvailableToTheWindowSession() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .rss, selectedDraftID: draftID)

    session.selectSection(.library) { _ in }

    XCTAssertEqual(session.selectedSection, .library)
    XCTAssertEqual(session.selectedDraftID, draftID)
  }

}
