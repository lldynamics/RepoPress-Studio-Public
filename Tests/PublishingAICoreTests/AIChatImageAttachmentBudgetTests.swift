import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatImageAttachmentBudgetTests: XCTestCase {
  func testConversationBudgetRemainsEightMegabytes() {
    XCTAssertEqual(AIChatImageAttachmentBudget.maximumConversationBytes, 8_000_000)
  }

  func testByteCountUsesTheLargerPersistedOrInMemoryValue() {
    let inMemoryLarger = AIChatImageAttachment(
      filename: "memory.png",
      mimeType: "image/png",
      data: Data(repeating: 0x01, count: 4),
      byteCount: 2
    )
    let persistedLarger = AIChatImageAttachment(
      filename: "persisted.png",
      mimeType: "image/png",
      data: Data(repeating: 0x02, count: 3),
      byteCount: 7
    )

    XCTAssertEqual(AIChatImageAttachmentBudget.byteCount(inMemoryLarger), 4)
    XCTAssertEqual(AIChatImageAttachmentBudget.byteCount(persistedLarger), 7)
  }

  func testArrayByteCountSumsEveryAttachment() {
    let attachments = [
      AIChatImageAttachment(
        filename: "first.png",
        mimeType: "image/png",
        data: Data(repeating: 0x01, count: 5),
        byteCount: 3
      ),
      AIChatImageAttachment(
        filename: "second.png",
        mimeType: "image/png",
        data: Data(repeating: 0x02, count: 2),
        byteCount: 8
      ),
    ]

    XCTAssertEqual(AIChatImageAttachmentBudget.byteCount(attachments), 13)
  }
}
