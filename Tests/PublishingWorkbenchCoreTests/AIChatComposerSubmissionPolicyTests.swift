import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIChatComposerSubmissionPolicyTests: XCTestCase {
  func testSuccessfulReplyClearsUnchangedComposer() {
    let snapshot = makeSnapshot()

    XCTAssertTrue(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: snapshot.conversationID,
        currentText: snapshot.text,
        currentContextReferences: snapshot.contextReferences,
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: true,
        didAcceptSubmittedUserMessage: false
      )
    )
  }

  func testEarlyFailurePreservesComposerWhenNothingWasAccepted() {
    let snapshot = makeSnapshot()

    XCTAssertFalse(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: snapshot.conversationID,
        currentText: snapshot.text,
        currentContextReferences: snapshot.contextReferences,
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: false,
        didAcceptSubmittedUserMessage: false
      )
    )
  }

  func testAcceptedUserMessageMayClearAfterPartialOrEarlyTransportFailure() {
    let snapshot = makeSnapshot()

    XCTAssertTrue(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: snapshot.conversationID,
        currentText: snapshot.text,
        currentContextReferences: snapshot.contextReferences,
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: false,
        didAcceptSubmittedUserMessage: true
      )
    )
  }

  func testChangedComposerStateOrConversationNeverClearsLateResult() {
    let snapshot = makeSnapshot()
    let otherConversationID = UUID()

    XCTAssertFalse(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: otherConversationID,
        currentText: snapshot.text,
        currentContextReferences: snapshot.contextReferences,
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: true,
        didAcceptSubmittedUserMessage: true
      )
    )
    XCTAssertFalse(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: snapshot.conversationID,
        currentText: "用户刚刚改写的内容",
        currentContextReferences: snapshot.contextReferences,
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: true,
        didAcceptSubmittedUserMessage: true
      )
    )
    XCTAssertFalse(
      AIChatComposerSubmissionPolicy.shouldClearComposer(
        snapshot: snapshot,
        currentConversationID: snapshot.conversationID,
        currentText: snapshot.text,
        currentContextReferences: [],
        currentImageAttachments: snapshot.imageAttachments,
        didReceiveReply: true,
        didAcceptSubmittedUserMessage: true
      )
    )
  }

  private func makeSnapshot() -> AIChatComposerSubmissionSnapshot {
    let reference = AIContextReference(
      kind: .knowledgeEntry,
      resourceID: "entry-1",
      displayName: "明确附加的资料",
      characterCount: 12
    )
    let attachment = AIChatImageAttachment(
      filename: "diagram.png",
      mimeType: "image/png",
      data: Data([0x89, 0x50])
    )
    return AIChatComposerSubmissionSnapshot(
      conversationID: UUID(),
      text: "解释这个架构",
      contextReferences: [reference],
      imageAttachments: [attachment]
    )
  }
}
