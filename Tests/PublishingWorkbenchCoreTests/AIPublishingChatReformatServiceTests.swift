import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatReformatServiceTests: XCTestCase {
  func testDetectsDirectReformatRequestsWithoutTreatingQuestionsAsCommands() {
    XCTAssertTrue(AIPublishingChatReformatService.isReformatRequest("帮我重新排版"))
    XCTAssertTrue(AIPublishingChatReformatService.isReformatRequest("请重新排版当前文章"))
    XCTAssertTrue(AIPublishingChatReformatService.isReformatRequest("把当前文章重新整理一下格式"))
    XCTAssertFalse(AIPublishingChatReformatService.isReformatRequest("如何重新排版当前文章？"))
    XCTAssertFalse(AIPublishingChatReformatService.isReformatRequest("请告诉我如何重新排版当前文章"))
    XCTAssertFalse(AIPublishingChatReformatService.isReformatRequest("帮我润色这段文字"))
  }

  func testInstructionIncludesCompleteBodyAndStrictPreservationRules() throws {
    let body = """
      # 标题

      第一段。

      [文档](https://example.com/docs)

      ```swift
      let value = 1
      ```
      """
    let instruction = try XCTUnwrap(
      AIPublishingChatReformatService.instruction(for: makeDraft(body: body))
    )

    XCTAssertTrue(instruction.contains(body))
    XCTAssertTrue(instruction.contains("完整返回重新排版后的 Markdown 正文"))
    XCTAssertTrue(instruction.contains("完整保留代码块内容、链接目标、图片路径"))
    XCTAssertTrue(instruction.contains("不能只返回节选"))
    XCTAssertTrue(instruction.contains("<repopress_source_body>"))
  }

  func testPrepareReplyBuildsDeterministicReplaceBodyPlan() throws {
    let original = """
      # 标题

      第一段包含需要保留的事实。

      [文档](https://example.com/docs)

      ```swift
      let value = 1
      ```
      """
    let replacement = """
      # 标题

      第一段包含需要保留的事实。

      - [文档](https://example.com/docs)

      ```swift
      let value = 1
      ```
      """
    let request = makeRequest(body: original)
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "```markdown\n\(replacement)\n```",
      knowledgeCitations: [
        KnowledgeCitation(
          id: "K1",
          documentID: UUID(),
          chunkID: UUID(),
          title: "不应写入排版结果",
          locator: "测试",
          excerpt: "不应参与仅调整排版的任务。"
        )
      ]
    )

    let prepared = try XCTUnwrap(
      AIPublishingChatReformatService.prepareReply(message, request: request)
    )
    let plan = try XCTUnwrap(prepared.automationPlan)
    let step = try XCTUnwrap(plan.steps.first)

    XCTAssertEqual(step.command, .replaceBody)
    XCTAssertEqual(step.arguments.draftID, request.draft.id)
    XCTAssertEqual(step.arguments.expectedDraftUpdatedAt, request.draft.updatedAt)
    XCTAssertEqual(step.arguments.content, replacement)
    XCTAssertFalse(prepared.allowsDraftAppend)
    XCTAssertTrue(prepared.knowledgeCitations.isEmpty)
    XCTAssertTrue(prepared.content.contains("预览差异"))
  }

  func testPrepareReplyBlocksIncompleteReplacementAndDisablesAppend() throws {
    let original = String(repeating: "这是必须完整保留的正文内容。", count: 40)
    let request = makeRequest(body: original)
    let message = AIPublishingChatMessage(role: .assistant, content: "已经重新排版完成。")

    let prepared = try XCTUnwrap(
      AIPublishingChatReformatService.prepareReply(message, request: request)
    )

    XCTAssertNil(prepared.automationPlan)
    XCTAssertFalse(prepared.allowsDraftAppend)
    XCTAssertTrue(prepared.content.contains("已阻止替换"))
  }

  func testOldEncodedMessageDefaultsToAllowingDraftAppend() throws {
    let data = Data(
      """
      {
        "id":"\(UUID().uuidString)",
        "role":"assistant",
        "content":"普通回复"
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(AIPublishingChatMessage.self, from: data)

    XCTAssertTrue(decoded.allowsDraftAppend)
  }

  func testAssistantRequestSendsFullProtectedBodyAndReturnsReplacePlan() async throws {
    let original = """
      # 原始标题

      这是需要完整保留的第一段。

      [项目文档](https://example.com/project)
      """
    let replacement = """
      # 原始标题

      这是需要完整保留的第一段。

      - [项目文档](https://example.com/project)
      """
    let response: [String: Any] = [
      "model": "local-test",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": replacement,
          ]
        ]
      ],
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: response),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let request = makeRequest(body: original)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-test",
      requiresAPIKey: false
    )

    let reply = try await service.reply(to: request, config: config, apiKey: nil)

    let recordedRequest = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    XCTAssertTrue(sentText.contains(original))
    XCTAssertTrue(sentText.contains("受保护任务"))
    XCTAssertTrue(sentText.contains("不能只返回节选"))
    XCTAssertEqual(reply.automationPlan?.steps.first?.command, .replaceBody)
    XCTAssertEqual(reply.automationPlan?.steps.first?.arguments.content, replacement)
    XCTAssertFalse(reply.allowsDraftAppend)
  }

  private func makeRequest(body: String) -> AIPublishingChatRequest {
    let draft = makeDraft(body: body)
    return AIPublishingChatRequest(
      draft: draft,
      profile: .defaultProfile,
      messages: [
        AIPublishingChatMessage(role: .user, content: "帮我重新排版")
      ]
    )
  }

  private func makeDraft(body: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "重新排版测试",
      slug: "reformat-test",
      bodyMarkdown: body,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}
