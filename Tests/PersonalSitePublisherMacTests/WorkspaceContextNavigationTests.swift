import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceContextNavigationTests: XCTestCase {
  func testCompactInspectorBandKeepsTheSharedRailAvailable() {
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 959).band, .constrained)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 960).band, .compactInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_180).band, .compactInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_243).band, .compactInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_244).band, .standardInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_423).band, .standardInspector)
    XCTAssertEqual(WorkspaceResponsiveLayoutSnapshot(width: 1_424).band, .standardInspector)
  }

  func testVisualRailAndCommandMenuKeepSeparateStableOrders() {
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primarySections,
      [.writing, .library, .rss, .images, .sync]
    )
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primarySections,
      WorkspacePrimaryNavigationRail.primarySections
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.section),
      [.writing, .library, .rss, .sync, .contentHealth, .images]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.keyboardShortcutKey),
      ["1", "2", "3", "4", "5", "6"]
    )
    XCTAssertEqual(WorkspaceNavigationRouteDescriptor.primarySection(for: .images), .images)
    XCTAssertEqual(WorkspaceNavigationRouteDescriptor.primarySection(for: .contentHealth), .sync)
    XCTAssertEqual(WorkspaceSection.sync.systemImage, "globe")
    XCTAssertTrue(
      WorkspaceNavigationRouteDescriptor.checksHint(for: .sync, issueCount: 3).contains("3")
    )
    XCTAssertEqual(WorkspaceNavigationRouteDescriptor.checksHint(for: .writing, issueCount: 3), "")
    XCTAssertEqual(WorkspaceNavigationRouteDescriptor.checksHint(for: .sync, issueCount: nil), "")
  }

  func testSectionSwitchKeepsAnExistingDraftContextAvailableToTheWindowSession() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .rss, selectedDraftID: draftID)

    session.selectSection(.library) { _ in }

    XCTAssertEqual(session.selectedSection, .library)
    XCTAssertEqual(session.selectedDraftID, draftID)
  }

}
