import XCTest
@testable import PublishingWorkbenchCore

final class AIChatSurfaceStateTests: XCTestCase {
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
    state.setContextReferences([
      AIContextReference(kind: .knowledgeEntry, displayName: "资料", characterCount: 4)
    ], for: conversationID)
    state.setImageAttachments([
      AIChatImageAttachment(filename: "private.png", mimeType: "image/png", data: Data([1, 2, 3]))
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
