import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatDraftApplicationServiceTests: XCTestCase {
	  func testAppendAssistantContentToExistingBody() throws {
	    let profileID = UUID()
	    let draft = ArticleDraft(
	      siteProfileID: profileID,
	      title: "Existing Body",
	      bodyMarkdown: "# Title\n\nOriginal paragraph.\n",
	      updatedAt: oldUpdatedAt
	    )

    let result = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        "  New AI paragraph.  ",
        to: draft
      )
    )

    XCTAssertEqual(result.draft.bodyMarkdown, "# Title\n\nOriginal paragraph.\n\nNew AI paragraph.")
    XCTAssertEqual(result.action, .appendedToBody)
    XCTAssertEqual(result.appliedTextCharacterCount, "New AI paragraph.".count)
    XCTAssertGreaterThan(result.draft.updatedAt, draft.updatedAt)
  }

  func testAppendAssistantContentToEmptyBodyUsesTrimmedContentOnly() throws {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Empty Body",
      bodyMarkdown: " \n "
    )

    let result = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        "\nGenerated section\n",
        to: draft
      )
    )

    XCTAssertEqual(result.draft.bodyMarkdown, "Generated section")
  }

	  func testReplaceSelectionUsesAssistantContent() throws {
	    let draft = ArticleDraft(
	      siteProfileID: UUID(),
	      title: "Replace Selection",
	      bodyMarkdown: "Intro paragraph.\n\nOld paragraph.\n\nTail paragraph.",
	      updatedAt: oldUpdatedAt
	    )
    let nsText = draft.bodyMarkdown as NSString
    let selection = nsText.range(of: "Old paragraph.")

    let result = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        "\nNew paragraph from AI.\n",
        to: draft,
        mode: .replaceSelection,
        selectionRange: selection
      )
    )

    XCTAssertEqual(
      result.draft.bodyMarkdown,
      "Intro paragraph.\n\nNew paragraph from AI.\n\nTail paragraph."
    )
    XCTAssertEqual(result.action, .replacedSelection)
    XCTAssertEqual(result.appliedTextCharacterCount, "New paragraph from AI.".count)
    XCTAssertGreaterThan(result.draft.updatedAt, draft.updatedAt)
  }

	  func testReplaceBodyUsesAssistantContentAsEntireMarkdownBody() throws {
	    let draft = ArticleDraft(
	      siteProfileID: UUID(),
	      title: "Replace Body",
	      bodyMarkdown: "# Old\n\nOld body.",
	      updatedAt: oldUpdatedAt
	    )

    let result = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        "\n# New\n\nFull AI body.\n",
        to: draft,
        mode: .replaceBody
      )
    )

    XCTAssertEqual(result.draft.bodyMarkdown, "# New\n\nFull AI body.")
    XCTAssertEqual(result.action, .replacedBody)
    XCTAssertEqual(result.appliedTextCharacterCount, "# New\n\nFull AI body.".count)
    XCTAssertGreaterThan(result.draft.updatedAt, draft.updatedAt)
  }

  func testReplaceSelectionRequiresNonEmptySelection() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Empty Selection",
      bodyMarkdown: "Keep this body."
    )

    let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      "Replacement",
      to: draft,
      mode: .replaceSelection,
      selectionRange: NSRange(location: 0, length: 0)
    )

    XCTAssertNil(result)
  }

	  func testReplaceSelectionRejectsInvalidRange() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Invalid Selection",
      bodyMarkdown: "Keep this body."
    )

    let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      "Replacement",
      to: draft,
      mode: .replaceSelection,
      selectionRange: NSRange(location: 10_000, length: 20)
    )

    XCTAssertNil(result)
  }

  func testActiveEditorSelectionValidatesCurrentDraftText() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Current Selection",
      bodyMarkdown: "Intro paragraph.\n\nFocused paragraph.\n\nTail paragraph."
    )
    let source = draft.bodyMarkdown as NSString
    let range = source.range(of: "Focused paragraph.")
    let selection = ActiveEditorSelection(
      draftID: draft.id,
      range: range,
      selectedText: source.substring(with: range),
      bodyUTF16Count: source.length
    )

    XCTAssertEqual(selection.validatedRange(in: draft), range)

    var editedDraft = draft
    editedDraft.bodyMarkdown = "Intro paragraph.\n\nChanged paragraph.\n\nTail paragraph."
    XCTAssertNil(selection.validatedRange(in: editedDraft))

    var otherDraft = draft
    otherDraft.id = UUID()
    XCTAssertNil(selection.validatedRange(in: otherDraft))
  }

  func testApplyAssistantContentReturnsNilForEmptyReply() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Empty Reply",
      bodyMarkdown: "Keep this body."
    )

    let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      " \n ",
      to: draft
    )

    XCTAssertNil(result)
	  }

	  private var oldUpdatedAt: Date {
	    Date(timeIntervalSince1970: 1_700_000_000)
	  }
}
