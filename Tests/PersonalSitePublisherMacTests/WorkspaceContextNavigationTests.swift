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

  func testCompactRailExposesTheFivePrimaryWorkspaceRoutesThatMatchFullRailOrder() {
    XCTAssertEqual(
      WorkspaceCompactNavigationRail.primarySections,
      [.rss, .library, .sync, .contentHealth, .writing]
    )
  }

  func testFullAndCompactRailsShareTheSamePrimaryRouteOrder() {
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primarySections,
      WorkspaceCompactNavigationRail.primarySections
    )
    XCTAssertEqual(
      WorkspaceNavigationRouteDescriptor.primaryRows.flatMap { $0 },
      WorkspaceNavigationRouteDescriptor.primarySections
    )
  }

  func testSectionSwitchKeepsAnExistingDraftContextAvailableToTheWindowSession() {
    let draftID = UUID()
    let session = WorkspaceWindowSession(selectedSection: .rss, selectedDraftID: draftID)

    session.selectSection(.library) { _ in }

    XCTAssertEqual(session.selectedSection, .library)
    XCTAssertEqual(session.selectedDraftID, draftID)
  }

  func testRSSReadingToolbarUsesNoLayoutStackThatCouldMergeToolbarAccessibility() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/PersonalSitePublisherMac/Views/Workspace/WorkspaceRSSReadingToolbar.swift"
      ),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("Group {"))
    XCTAssertFalse(source.contains("HStack"))
  }
}
