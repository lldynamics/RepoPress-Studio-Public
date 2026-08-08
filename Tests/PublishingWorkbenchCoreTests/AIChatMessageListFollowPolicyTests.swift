import XCTest
@testable import PublishingWorkbenchCore

final class AIChatMessageListFollowPolicyTests: XCTestCase {
  func testFollowingLatestScrollsWhenContentChanges() {
    XCTAssertTrue(
      AIChatMessageListFollowPolicy.shouldFollowLatest(
        isFollowingLatest: true,
        contentChanged: true
      )
    )
  }

  func testUserScrollUpPreventsForcedFollow() {
    XCTAssertFalse(
      AIChatMessageListFollowPolicy.shouldFollowLatest(
        isFollowingLatest: false,
        contentChanged: true
      )
    )
  }

  func testNoContentChangeDoesNotScroll() {
    XCTAssertFalse(
      AIChatMessageListFollowPolicy.shouldFollowLatest(
        isFollowingLatest: true,
        contentChanged: false
      )
    )
  }

  func testConversationChangeResetsFollowState() {
    XCTAssertTrue(
      AIChatMessageListFollowPolicy.shouldResetFollowState(
        previousConversationID: UUID(),
        newConversationID: UUID()
      )
    )
    XCTAssertFalse(
      AIChatMessageListFollowPolicy.shouldResetFollowState(
        previousConversationID: nil,
        newConversationID: nil
      )
    )
  }
}
