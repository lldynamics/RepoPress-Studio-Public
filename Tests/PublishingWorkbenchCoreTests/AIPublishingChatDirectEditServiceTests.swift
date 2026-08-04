import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatDirectEditServiceTests: XCTestCase {
  func testDetectsCommandsButNotQuestions() {
    XCTAssertEqual(
      AIPublishingChatDirectEditService.kind(for: "请帮我校对当前文章"),
      .proofreadArticle
    )
    XCTAssertEqual(
      AIPublishingChatDirectEditService.kind(for: "帮我生成摘要并写入"),
      .generateSummary
    )
    XCTAssertNil(
      AIPublishingChatDirectEditService.kind(for: "请告诉我怎么校对当前文章")
    )
  }

  func testSelectionCommandBuildsGuardedBodyReplacement() throws {
    let body = "第一段。\n\nThis is test."
    let selected = "This is test."
    let location = (body as NSString).range(of: selected).location
    let request = makeRequest(
      body: body,
      message: "请帮我把这段翻译成中文",
      selection: ActiveEditorSelection(
        draftID: fixedDraftID,
        range: NSRange(location: location, length: (selected as NSString).length),
        selectedText: selected,
        bodyUTF16Count: (body as NSString).length
      )
    )

    let prepared = try XCTUnwrap(
      AIPublishingChatDirectEditService.prepareReply(
        AIPublishingChatMessage(role: .assistant, content: "这是一段测试。"),
        request: request
      )
    )

    XCTAssertEqual(prepared.automationPlan?.steps.first?.command, .replaceBody)
    XCTAssertEqual(
      prepared.automationPlan?.steps.first?.arguments.content,
      "第一段。\n\n这是一段测试。"
    )
    XCTAssertFalse(prepared.allowsDraftAppend)
  }

  func testSummaryCommandCreatesMetadataPreview() throws {
    let request = makeRequest(
      body: String(repeating: "正文内容。", count: 20),
      message: "请帮我生成摘要并写入"
    )
    let summary = "这是一条忠实概括正文内容、可用于文章列表和搜索结果展示的简短摘要。"

    let prepared = try XCTUnwrap(
      AIPublishingChatDirectEditService.prepareReply(
        AIPublishingChatMessage(role: .assistant, content: summary),
        request: request
      )
    )

    let step = try XCTUnwrap(prepared.automationPlan?.steps.first)
    XCTAssertEqual(step.command, .updateMetadata)
    XCTAssertEqual(step.arguments.metadataField, .summary)
    XCTAssertEqual(step.arguments.value, summary)
  }

  private let fixedDraftID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  private func makeRequest(
    body: String,
    message: String,
    selection: ActiveEditorSelection? = nil
  ) -> AIPublishingChatRequest {
    let draft = ArticleDraft(
      id: fixedDraftID,
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "测试文章",
      slug: "test",
      bodyMarkdown: body,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    return AIPublishingChatRequest(
      draft: draft,
      profile: .defaultProfile,
      messages: [AIPublishingChatMessage(role: .user, content: message)],
      editorSelection: selection
    )
  }
}
