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

  func testCompactInspectorRailKeepsWorkspaceNavigationWhenSidebarIsYielded() {
    XCTAssertTrue(
      WorkspaceSidebarVisibilityPolicy.shouldShowCompactNavigationRail(
        userWantsVisible: true,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: true
      )
    )
  }

  func testCompactInspectorRailRespectsExplicitSidebarHide() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowCompactNavigationRail(
        userWantsVisible: false,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: true
      )
    )
  }

  func testCompactInspectorRailRespectsFocusMode() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowCompactNavigationRail(
        userWantsVisible: true,
        isFocusMode: true,
        inspectorTemporarilyReplacesSidebar: true
      )
    )
  }

  func testCompactInspectorRailDoesNotReplaceTheNormalSidebar() {
    XCTAssertFalse(
      WorkspaceSidebarVisibilityPolicy.shouldShowCompactNavigationRail(
        userWantsVisible: true,
        isFocusMode: false,
        inspectorTemporarilyReplacesSidebar: false
      )
    )
  }
}
