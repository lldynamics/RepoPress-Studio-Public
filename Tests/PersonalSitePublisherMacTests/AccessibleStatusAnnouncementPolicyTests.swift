import XCTest
@testable import PersonalSitePublisherMac

final class AccessibleStatusAnnouncementPolicyTests: XCTestCase {
  func testInfoStatusIsSilentByDefault() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .info,
      announcesNonUrgentStatus: false
    )

    XCTAssertFalse(policy.shouldAnnounce)
    XCTAssertFalse(policy.shouldMoveAccessibilityFocus)
    XCTAssertNil(policy.priority)
  }

  func testSuccessStatusIsSilentByDefault() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .success,
      announcesNonUrgentStatus: false
    )

    XCTAssertFalse(policy.shouldAnnounce)
    XCTAssertFalse(policy.shouldMoveAccessibilityFocus)
    XCTAssertNil(policy.priority)
  }

  func testInfoStatusCanBeAnnouncedWithoutMovingFocus() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .info,
      announcesNonUrgentStatus: true
    )

    XCTAssertTrue(policy.shouldAnnounce)
    XCTAssertFalse(policy.shouldMoveAccessibilityFocus)
    XCTAssertEqual(policy.priority, .low)
  }

  func testSuccessStatusCanBeAnnouncedWithoutMovingFocus() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .success,
      announcesNonUrgentStatus: true
    )

    XCTAssertTrue(policy.shouldAnnounce)
    XCTAssertFalse(policy.shouldMoveAccessibilityFocus)
    XCTAssertEqual(policy.priority, .medium)
  }

  func testWarningAlwaysUsesHighPriorityAndMovesFocus() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .warning,
      announcesNonUrgentStatus: false
    )

    XCTAssertTrue(policy.shouldAnnounce)
    XCTAssertTrue(policy.shouldMoveAccessibilityFocus)
    XCTAssertEqual(policy.priority, .high)
  }

  func testErrorAlwaysUsesHighPriorityAndMovesFocus() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .error,
      announcesNonUrgentStatus: false
    )

    XCTAssertTrue(policy.shouldAnnounce)
    XCTAssertTrue(policy.shouldMoveAccessibilityFocus)
    XCTAssertEqual(policy.priority, .high)
  }

  func testUrgentStatusCanAnnounceWithoutMovingAccessibilityFocus() {
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: .warning,
      announcesNonUrgentStatus: false,
      movesAccessibilityFocusForUrgentStatus: false
    )

    XCTAssertTrue(policy.shouldAnnounce)
    XCTAssertFalse(policy.shouldMoveAccessibilityFocus)
    XCTAssertEqual(policy.priority, .high)
  }
}
