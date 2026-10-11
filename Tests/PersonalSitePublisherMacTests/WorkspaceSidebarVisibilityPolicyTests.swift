import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceSidebarVisibilityPolicyTests: XCTestCase {
  func testUserCanHideSidebarOutsideFocusMode() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
        userWantsVisible: false,
        isFocusMode: false
      )
    )
  }

  func testUserCanShowSidebarOutsideFocusMode() {
    XCTAssertTrue(
      WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
        userWantsVisible: true,
        isFocusMode: false
      )
    )
  }

  func testFocusModeHidesSidebarEvenWhenUserWantsItVisible() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
        userWantsVisible: true,
        isFocusMode: true
      )
    )
  }

  func testFocusModeDoesNotChangeUserPreferenceInput() {
    let userWantsVisible = true

    _ = WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
      userWantsVisible: userWantsVisible,
      isFocusMode: true
    )

    XCTAssertTrue(userWantsVisible)
  }

  func testNavigationRailStaysVisibleWhenContextSidebarIsHidden() {
    XCTAssertTrue(
      WorkspaceSidebarVisibilityPolicy.shouldShowNavigationRail(isFocusMode: false)
    )
  }

  func testNavigationRailRespectsFocusMode() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowNavigationRail(isFocusMode: true)
    )
  }

  func testCompactContextSidebarStartsHiddenUntilExplicitlyRevealed() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowContextSidebar(
        userWantsVisible: true,
        isCompact: true,
        userRevealedInCompact: false,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: false
      )
    )
    XCTAssertTrue(
      WorkspaceSidebarVisibilityPolicy.shouldShowContextSidebar(
        userWantsVisible: true,
        isCompact: true,
        userRevealedInCompact: true,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: false
      )
    )
  }

  func testCompactInspectorTemporarilyOverridesARevealedContextSidebar() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowContextSidebar(
        userWantsVisible: true,
        isCompact: true,
        userRevealedInCompact: true,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: true
      )
    )
  }
}
