import XCTest

@testable import PersonalSitePublisherMac

final class SettingsNavigationExpansionTests: XCTestCase {
  func testExpansionStateDefaultsToACollapsedTree() {
    let state = SettingsNavigationExpansionState(
      rawValue: SettingsNavigationExpansionState.defaultRawValue
    )

    XCTAssertEqual(
      SettingsTab.allCases.filter { state.contains($0) },
      []
    )
  }

  func testCollapsingOnePagePreservesTheOtherPageExpansions() {
    var state = SettingsNavigationExpansionState(expandedTabs: Set(SettingsTab.allCases))
    state.setExpanded(false, for: .ai)

    XCTAssertFalse(state.contains(.ai))
    XCTAssertTrue(state.contains(.token))
    XCTAssertTrue(state.contains(.dataManagement))
  }

  func testStoredExpansionStateIgnoresUnknownTabIdentifiers() {
    let state = SettingsNavigationExpansionState(
      rawValue: "ai,removed-page,privacy"
    )

    XCTAssertTrue(state.contains(.ai))
    XCTAssertTrue(state.contains(.privacy))
    XCTAssertEqual(state.rawValue, "ai,privacy")
  }

  func testCollapsedPageShowsItsParentSelectionWithoutChangingTheDetailRoute() {
    var state = SettingsNavigationExpansionState(expandedTabs: [.appearance])
    let route = SettingsRoute.subsection(.appearanceTheme)

    XCTAssertEqual(state.visibleSelection(for: route), route)
    state.setExpanded(false, for: .appearance)
    XCTAssertEqual(state.visibleSelection(for: route), .tab(.appearance))
    state.setExpanded(true, for: .appearance)
    XCTAssertEqual(state.visibleSelection(for: route), route)
  }
}
