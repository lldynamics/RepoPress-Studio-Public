import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatEnhancementIntegrationTests: XCTestCase {
  func testProofreadReplyBecomesValidatedStructuredReview() throws {
    let draft = makeDraft(body: "错字")
    let request = AIPublishingChatRequest(
      draft: draft,
      profile: .defaultProfile,
      messages: [
        AIPublishingChatMessage(role: .user, content: "请帮我校对当前文章")
      ]
    )
    let json = """
      {"schemaVersion":1,"changes":[{"id":"c1","range":{"location":0,"length":2},"originalText":"错字","replacementText":"正字","reason":"修正用词","category":"spelling","confidence":0.9}]}
      """

    let prepared = try XCTUnwrap(
      AIPublishingChatStructuredEditService.prepareReply(
        AIPublishingChatMessage(role: .assistant, content: json),
        request: request
      )
    )

    XCTAssertEqual(prepared.structuredEditPayload?.document.changes.count, 1)
    XCTAssertEqual(
      prepared.structuredEditPayload?.sourceContentFingerprint,
      draft.repositoryContentFingerprint
    )
    XCTAssertNil(prepared.automationPlan)
    XCTAssertFalse(prepared.allowsDraftAppend)
  }

  func testSelectionRangesAreShiftedIntoWholeDraftCoordinates() throws {
    let body = "前文\nbad\n后文"
    let selected = "bad"
    let selectedRange = (body as NSString).range(of: selected)
    let draft = makeDraft(body: body)
    let request = AIPublishingChatRequest(
      draft: draft,
      profile: .defaultProfile,
      messages: [
        AIPublishingChatMessage(role: .user, content: "请帮我润色这段")
      ],
      editorSelection: ActiveEditorSelection(
        draftID: draft.id,
        range: selectedRange,
        selectedText: selected,
        bodyUTF16Count: (body as NSString).length
      )
    )
    let json = """
      {"schemaVersion":1,"changes":[{"id":"c1","range":{"location":0,"length":3},"originalText":"bad","replacementText":"better","reason":"表达更清晰","category":"clarity","confidence":0.8}]}
      """

    let prepared = try XCTUnwrap(
      AIPublishingChatStructuredEditService.prepareReply(
        AIPublishingChatMessage(role: .assistant, content: json),
        request: request
      )
    )

    XCTAssertEqual(
      prepared.structuredEditPayload?.document.changes.first?.range.location,
      selectedRange.location
    )
  }

  func testWholeArticleTranslationCreatesOnlyANewDraftPlan() throws {
    let draft = makeDraft(body: "# 标题\n\n正文")
    let request = AIPublishingChatRequest(
      draft: draft,
      profile: .defaultProfile,
      messages: [
        AIPublishingChatMessage(
          role: .user,
          content: "请帮我将当前文章全文翻译为英文，并创建关联新草稿"
        )
      ]
    )
    let json = """
      {"title":"Title","summary":"Summary","bodyMarkdown":"# Title\\n\\nBody","slug":"title-en"}
      """

    let prepared = try XCTUnwrap(
      AIPublishingChatTranslationDraftService.prepareReply(
        AIPublishingChatMessage(role: .assistant, content: json),
        request: request
      )
    )
    let plan = try XCTUnwrap(prepared.translationDraftPlan)

    XCTAssertEqual(plan.sourceDraftID, draft.id)
    XCTAssertNotEqual(plan.translatedDraft.id, draft.id)
    XCTAssertTrue(plan.translatedDraft.draft)
    XCTAssertEqual(plan.translatedDraft.status, .draft)
    XCTAssertNil(plan.translatedDraft.repositoryPath)
  }

  func testNewMessageEnhancementsRemainBackwardCompatibleWithCodable() throws {
    let legacy = """
      {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","role":"assistant","content":"ok","contextMode":"site","createdAt":0}
      """
    let message = try JSONDecoder().decode(
      AIPublishingChatMessage.self,
      from: Data(legacy.utf8)
    )

    XCTAssertTrue(message.contextReferences.isEmpty)
    XCTAssertNil(message.structuredEditPayload)
    XCTAssertNil(message.translationDraftPlan)
  }

  private func makeDraft(body: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "测试",
      slug: "test",
      bodyMarkdown: body,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}
