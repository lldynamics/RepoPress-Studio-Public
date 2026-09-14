import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore

final class AIChatCitationBacklinkRetryTests: XCTestCase {
  func testRetryDoesNotMatchAnotherConversationForTheSameDraft() {
    let draftID = UUID()
    let originalConversationID = UUID()
    let retry = AIChatContextInspectorView.AIChatCitationBacklinkRetry(
      draftID: draftID,
      conversationID: originalConversationID,
      citations: [citation()],
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: draftID.uuidString,
        title: "当前文章"
      )
    )

    XCTAssertTrue(retry.matches(draftID: draftID, conversationID: originalConversationID))
    XCTAssertFalse(retry.matches(draftID: draftID, conversationID: UUID()))
    XCTAssertFalse(retry.matches(draftID: UUID(), conversationID: originalConversationID))
  }

  private func citation() -> KnowledgeCitation {
    KnowledgeCitation(
      id: "K1",
      documentID: UUID(),
      revisionID: UUID(),
      chunkID: UUID(),
      title: "资料",
      excerpt: "回归测试引用。"
    )
  }
}
