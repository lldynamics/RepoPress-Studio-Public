import XCTest

@testable import PersonalSitePublisherMac

final class WorkbenchMotionPolicyTests: XCTestCase {
  func testMotionIntentIsAClosedThreeItemAllowList() {
    XCTAssertEqual(
      WorkbenchMotionIntent.allCases,
      [.statusChange, .drawerPresentation, .taskCompletion]
    )
  }

  func testDefaultPolicyMapsEachIntentToItsSemanticStyle() {
    let policy = WorkbenchMotionPolicy(reduceMotion: false)

    XCTAssertEqual(policy.style(for: .statusChange), .quickFade)
    XCTAssertEqual(policy.style(for: .drawerPresentation), .drawerSlide)
    XCTAssertEqual(policy.style(for: .taskCompletion), .completionBounce)
  }

  func testReduceMotionDisablesEveryCustomMotionIntent() {
    let policy = WorkbenchMotionPolicy(reduceMotion: true)

    for intent in WorkbenchMotionIntent.allCases {
      XCTAssertEqual(policy.style(for: intent), .none)
      XCTAssertNil(WorkbenchMotion.animation(for: intent, reduceMotion: true))
    }
  }

  func testDefaultPolicyProvidesAnAnimationForEveryAllowedIntent() {
    for intent in WorkbenchMotionIntent.allCases {
      XCTAssertNotNil(WorkbenchMotion.animation(for: intent, reduceMotion: false))
    }
  }
}
