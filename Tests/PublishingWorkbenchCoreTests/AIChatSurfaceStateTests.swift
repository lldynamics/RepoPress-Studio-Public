import XCTest

@testable import PublishingWorkbenchCore

final class AIChatSurfaceStateTests: XCTestCase {
  func testAcceptedSubmissionClearsUnchangedInputAndAttachments() {
    var fixture = SubmissionFixture()
    fixture.state.setComposerText("  submitted\n", for: fixture.conversationID)
    fixture.complete()

    XCTAssertEqual(fixture.state.composerText(for: fixture.conversationID), "")
    XCTAssertTrue(fixture.state.contextReferences(for: fixture.conversationID).isEmpty)
    XCTAssertTrue(fixture.state.imageAttachmentIDs(for: fixture.attachmentConversationID).isEmpty)
  }

  func testUnacceptedSubmissionOrQuickPromptPreservesInput() {
    for (clearsComposer, accepted) in [(true, false), (false, true)] {
      var fixture = SubmissionFixture()
      let original = fixture.state
      fixture.complete(clearsComposer: clearsComposer, accepted: accepted)
      XCTAssertEqual(fixture.state, original)
    }
  }

  func testLateCompletionPreservesNewlyTypedInputAndItsAttachments() {
    var fixture = SubmissionFixture()
    fixture.state.setComposerText("new message", for: fixture.conversationID)
    let original = fixture.state
    fixture.complete()
    XCTAssertEqual(fixture.state, original)
  }

  func testLateCompletionDoesNotClearAnotherConversationsInput() {
    var fixture = SubmissionFixture()
    let otherID = UUID()
    fixture.state.selectedConversationID = otherID
    fixture.state.setComposerText("other message", for: otherID)
    fixture.state.setContextReferences([fixture.reference], for: otherID)
    fixture.state.setImageAttachmentIDs([fixture.attachmentID], for: otherID)
    fixture.complete()

    XCTAssertEqual(fixture.state.selectedConversationID, otherID)
    XCTAssertEqual(fixture.state.composerText(for: otherID), "other message")
    XCTAssertEqual(fixture.state.contextReferences(for: otherID), [fixture.reference])
    XCTAssertEqual(fixture.state.imageAttachmentIDs(for: otherID), [fixture.attachmentID])
    XCTAssertEqual(fixture.state.composerText(for: fixture.conversationID), "")
  }

  func testLateCompletionPreservesChangedReferencesAndAttachmentSelection() {
    var fixture = SubmissionFixture()
    let newReference = AIContextReference(
      kind: .knowledgeEntry, displayName: "new", characterCount: 3)
    let newAttachmentID = UUID()
    fixture.state.setContextReferences([newReference], for: fixture.conversationID)
    fixture.state.setImageAttachmentIDs([newAttachmentID], for: fixture.attachmentConversationID)
    fixture.complete()

    XCTAssertEqual(fixture.state.composerText(for: fixture.conversationID), "")
    XCTAssertEqual(fixture.state.contextReferences(for: fixture.conversationID), [newReference])
    XCTAssertEqual(
      fixture.state.imageAttachmentIDs(for: fixture.attachmentConversationID), [newAttachmentID]
    )
  }

  func testWorkspaceComposerStateIsScopedByConversation() {
    let firstConversationID = UUID()
    let secondConversationID = UUID()
    var state = AIChatSurfaceState(
      surface: .inspector,
      selectedConversationID: firstConversationID
    )
    let reference = AIContextReference(
      kind: .currentArticle,
      resourceID: UUID().uuidString,
      displayName: "明确文章",
      characterCount: 12
    )
    let attachment = AIChatImageAttachment(
      filename: "image.png",
      mimeType: "image/png",
      data: Data([1, 2, 3])
    )

    state.setComposerText("第一条对话草稿", for: firstConversationID)
    state.setContextReferences([reference], for: firstConversationID)
    state.setImageAttachments([attachment], for: firstConversationID)
    state.setComposerText("第二条对话草稿", for: secondConversationID)

    XCTAssertEqual(state.surface, .inspector)
    XCTAssertEqual(state.composerText(for: firstConversationID), "第一条对话草稿")
    XCTAssertEqual(state.contextReferences(for: firstConversationID), [reference])
    XCTAssertEqual(state.imageAttachments(for: firstConversationID), [attachment])
    XCTAssertEqual(state.composerText(for: secondConversationID), "第二条对话草稿")
    XCTAssertTrue(state.contextReferences(for: secondConversationID).isEmpty)
    XCTAssertTrue(state.imageAttachments(for: secondConversationID).isEmpty)
  }

  func testDiscardStateRemovesTextReferencesImagesAndSelection() {
    let conversationID = UUID()
    var state = AIChatSurfaceState(
      surface: .inspector,
      selectedConversationID: conversationID
    )
    state.setComposerText("不要在窗口销毁后保留", for: conversationID)
    state.setContextReferences(
      [
        AIContextReference(kind: .knowledgeEntry, displayName: "资料", characterCount: 4)
      ], for: conversationID)
    state.setImageAttachments(
      [
        AIChatImageAttachment(
          filename: "private.png", mimeType: "image/png", data: Data([1, 2, 3]))
      ], for: conversationID)
    state.setImageAttachmentIDs([UUID()], for: conversationID)

    state.discardState(for: conversationID)

    XCTAssertNil(state.selectedConversationID)
    XCTAssertFalse(state.conversationsWithEphemeralState.contains(conversationID))
    XCTAssertEqual(state.composerText(for: conversationID), "")
    XCTAssertTrue(state.contextReferences(for: conversationID).isEmpty)
    XCTAssertTrue(state.imageAttachments(for: conversationID).isEmpty)
    XCTAssertTrue(state.imageAttachmentIDs(for: conversationID).isEmpty)
  }
}

private struct SubmissionFixture {
  let conversationID = UUID()
  let attachmentConversationID = UUID()
  let attachmentID = UUID()
  let reference = AIContextReference(
    kind: .knowledgeEntry, displayName: "original", characterCount: 8)
  var state = AIChatSurfaceState(surface: .inspector)

  init() {
    state.selectedConversationID = conversationID
    state.setComposerText("submitted", for: conversationID)
    state.setContextReferences([reference], for: conversationID)
    state.setImageAttachmentIDs([attachmentID], for: attachmentConversationID)
  }

  mutating func complete(clearsComposer: Bool = true, accepted: Bool = true) {
    state.completeSubmission(
      conversationID: conversationID,
      message: "submitted",
      imageAttachmentConversationID: attachmentConversationID,
      submittedImageAttachmentIDs: [attachmentID],
      submittedContextReferences: [reference],
      clearsComposerOnAccept: clearsComposer,
      wasAccepted: accepted
    )
  }
}
