import XCTest

@testable import PersonalSitePublisherMac

final class AIChatStreamingPresentationTests: XCTestCase {
  func testOnlyLatestAssistantUsesStreamingTextWhileChatRuns() {
    let latestAssistantID = UUID()

    XCTAssertEqual(
      AIChatAssistantMessagePresentationPolicy.mode(
        role: .assistant,
        messageID: latestAssistantID,
        latestMessageID: latestAssistantID,
        isChatRunning: true
      ),
      .streamingText
    )
  }

  func testOlderAssistantRemainsStructuredWhileChatRuns() {
    XCTAssertEqual(
      AIChatAssistantMessagePresentationPolicy.mode(
        role: .assistant,
        messageID: UUID(),
        latestMessageID: UUID(),
        isChatRunning: true
      ),
      .structured
    )
  }

  func testStreamingTextRequiresAnAssistantMessage() {
    let messageID = UUID()

    XCTAssertEqual(
      AIChatAssistantMessagePresentationPolicy.mode(
        role: .user,
        messageID: messageID,
        latestMessageID: messageID,
        isChatRunning: true
      ),
      .structured
    )
  }

  func testLatestAssistantReturnsToStructuredAfterStreamFinishes() {
    let messageID = UUID()

    XCTAssertEqual(
      AIChatAssistantMessagePresentationPolicy.mode(
        role: .assistant,
        messageID: messageID,
        latestMessageID: messageID,
        isChatRunning: false
      ),
      .structured
    )
  }

  func testOlderAssistantRemainsStructuredWhenUserIsLastWhileChatRuns() {
    let assistantID = UUID()

    XCTAssertEqual(
      AIChatAssistantMessagePresentationPolicy.mode(
        role: .assistant,
        messageID: assistantID,
        latestMessageID: UUID(),
        isChatRunning: true
      ),
      .structured
    )
  }
}
