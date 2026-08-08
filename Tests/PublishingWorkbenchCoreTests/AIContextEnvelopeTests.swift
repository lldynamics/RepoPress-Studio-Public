import XCTest
@testable import PublishingWorkbenchCore

final class AIContextEnvelopeTests: XCTestCase {
  func testGeneralEnvelopeNeverIncludesImplicitArticleContext() {
    let reference = AIContextReference(
      kind: .specifiedArticle,
      resourceID: UUID().uuidString,
      displayName: "用户明确选择的文章",
      characterCount: 20
    )
    let envelope = AIContextEnvelope.general(
      explicitContextReferences: [reference],
      explicitContextPrompt: "<explicit_specified_article>用户明确选择的内容</explicit_specified_article>"
    )

    XCTAssertFalse(envelope.includesImplicitArticleContext)
    XCTAssertEqual(envelope.explicitContextReferences, [reference])
    XCTAssertEqual(envelope.transmissionSummary.items.count, 1)
  }

  func testGenericTransportMessagesContainOnlyGeneralAndExplicitContext() {
    let service = AIPublishingAssistantService()
    let request = AIChatRequest(
      messages: [
        AIPublishingChatMessage(role: .user, content: "如何学习 Swift？")
      ],
      context: .general(
        explicitContextPrompt: "<explicit_knowledge_entry>用户明确选择的资料</explicit_knowledge_entry>"
      )
    )

    let messages = service.chatMessages(for: request)
    let payload = messages.compactMap { message in
      if case let .text(text) = message.content { return text }
      return nil
    }.joined(separator: "\n")

    XCTAssertTrue(payload.contains("通用 AI 对话助手"))
    XCTAssertTrue(payload.contains("用户明确选择的资料"))
    XCTAssertFalse(payload.contains("当前 Mac 工作台上下文"))
    XCTAssertFalse(payload.contains("正文节选"))
  }
}
