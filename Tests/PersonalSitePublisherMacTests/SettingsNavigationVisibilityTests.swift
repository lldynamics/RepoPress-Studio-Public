import XCTest

@testable import PersonalSitePublisherMac

/// Protects Settings entry points and subsection discovery.
final class SettingsNavigationVisibilityTests: XCTestCase {
  func testEveryVisiblePageHasAtLeastOneDiscoverableSubsection() {
    for tab in SettingsTab.allCases {
      XCTAssertFalse(
        SettingsSubsection.sections(for: tab).isEmpty, "Missing sections for \(tab.id)")
      XCTAssertEqual(SettingsDestination(requestedID: tab.id), .tab(tab))
      XCTAssertEqual(SettingsRoute.requestedID(tab.id), .tab(tab))
      XCTAssertEqual(SettingsRoute.restored(lastViewedID: tab.id), .tab(tab))
    }
  }
}
