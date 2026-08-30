import XCTest

@testable import PersonalSitePublisherMac

final class AIChatInspectorScrollPolicyTests: XCTestCase {
  func testUserHistoryDragRequiresExplicitReturnBeforeStreamingCanFollowAgain() {
    XCTAssertFalse(AIChatScrollPinningPolicy.isPinnedAfterUserDrag())
    XCTAssertTrue(
      AIChatScrollPinningPolicy.shouldShowReturnToLatest(
        isPinnedToLatest: false,
        hasLatestMessage: true
      )
    )
    XCTAssertTrue(AIChatScrollPinningPolicy.isPinnedAfterReturnToLatest())
    XCTAssertFalse(
      AIChatScrollPinningPolicy.shouldShowReturnToLatest(
        isPinnedToLatest: true,
        hasLatestMessage: true
      )
    )
  }

  func testUserDragInvalidatesAnAlreadyScheduledFollow() {
    let scheduledGeneration: UInt64 = 12
    let generationAfterUserDrag = scheduledGeneration + 1

    XCTAssertFalse(
      AIChatScrollPinningPolicy.shouldFollowScheduledScroll(
        isPinnedToLatest: false,
        scheduledGeneration: scheduledGeneration,
        currentGeneration: generationAfterUserDrag
      )
    )
  }
}
