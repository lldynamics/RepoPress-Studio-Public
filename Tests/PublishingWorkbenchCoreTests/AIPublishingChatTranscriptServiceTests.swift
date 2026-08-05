import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatTranscriptServiceTests: XCTestCase {
  func testMessageDisplayContentIncludesImageAttachmentNames() {
    let message = AIPublishingChatMessage(
      role: .user,
      content: "帮我看图。",
      imageAttachments: [
        AIChatImageAttachment(filename: "cover.png", mimeType: "image/png", data: Data("cover".utf8)),
        AIChatImageAttachment(filename: "inline.jpg", mimeType: "image/jpeg", data: Data("inline".utf8)),
      ]
    )

    let displayContent = AIPublishingChatMessageCompositionService.displayContent(for: message)

    XCTAssertEqual(displayContent, "帮我看图。\n\n已附加图片：cover.png, inline.jpg")
  }

  func testMessageDisplayContentUsesAttachmentLineForImageOnlyMessage() {
    let message = AIPublishingChatMessage(
      role: .user,
      content: " \n ",
      imageAttachments: [
        AIChatImageAttachment(filename: "diagram.png", mimeType: "image/png", data: Data("image".utf8))
      ]
    )

    let displayContent = AIPublishingChatMessageCompositionService.displayContent(for: message)

    XCTAssertEqual(displayContent, "已附加图片：diagram.png")
  }

  func testMarkdownTranscriptIncludesConversationMetadataAndMessages() {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "AI Transcript",
      slug: "ai-transcript",
      bodyMarkdown: "正文不需要进入导出头部。"
    )
    let messages = [
      AIPublishingChatMessage(
        role: .user,
        content: "帮我检查摘要。",
        imageAttachments: [
          AIChatImageAttachment(
            filename: "cover.png",
            mimeType: "image/png",
            data: Data("image".utf8)
          ),
        ],
        createdAt: Date(timeIntervalSince1970: 0)
      ),
      AIPublishingChatMessage(
        role: .assistant,
        content: "摘要可以再压缩。",
        model: "deepseek-v4-pro",
        tokenUsage: AIChatTokenUsage(promptTokens: 10, completionTokens: 6, totalTokens: 16),
        createdAt: Date(timeIntervalSince1970: 60)
      ),
    ]

    let transcript = AIPublishingChatTranscriptService.markdownTranscript(
      messages: messages,
      draft: draft,
      contextMode: .site,
      contextSummary: "主站 · content/posts/ai-transcript.md",
      modelSummary: "高质量 · deepseek-v4-pro",
      exportedAt: Date(timeIntervalSince1970: 120)
    )

    XCTAssertTrue(transcript.contains("# AI 对话记录"))
    XCTAssertTrue(transcript.contains("- 对话：帮我检查摘要。"))
    XCTAssertTrue(transcript.contains("- 文章：AI Transcript"))
    XCTAssertTrue(transcript.contains("- Slug：ai-transcript"))
    XCTAssertTrue(transcript.contains("- 上下文模式：站点上下文"))
    XCTAssertTrue(transcript.contains("- 上下文摘要：主站 · content/posts/ai-transcript.md"))
    XCTAssertTrue(transcript.contains("- 模型：高质量 · deepseek-v4-pro"))
    XCTAssertTrue(transcript.contains("- 导出时间：1970-01-01T00:02:00Z"))
    XCTAssertTrue(transcript.contains("- 消息数：2"))
    XCTAssertTrue(transcript.contains("## 你 · 1970-01-01T00:00:00Z"))
    XCTAssertTrue(transcript.contains("帮我检查摘要。"))
    XCTAssertTrue(transcript.contains("- cover.png（image/png，5 bytes）"))
    XCTAssertTrue(transcript.contains("## AI · 1970-01-01T00:01:00Z"))
    XCTAssertTrue(transcript.contains("模型：deepseek-v4-pro · Token：16 tokens · 输入 10 · 输出 6"))
    XCTAssertTrue(transcript.contains("摘要可以再压缩。"))
  }

  func testMarkdownTranscriptReturnsEmptyForEmptyConversation() {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "Empty", slug: "empty")

    let transcript = AIPublishingChatTranscriptService.markdownTranscript(
      messages: [
        AIPublishingChatMessage(role: .user, content: " \n ")
      ],
      draft: draft,
      contextMode: .general,
      exportedAt: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(transcript, "")
  }

  func testMarkdownTranscriptUsesExplicitConversationTitleWhenProvided() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Original",
      slug: "original"
    )

    let transcript = AIPublishingChatTranscriptService.markdownTranscript(
      messages: [
        AIPublishingChatMessage(role: .user, content: "第一条用户消息")
      ],
      draft: draft,
      contextMode: .general,
      conversationTitle: "发布前问答",
      exportedAt: Date(timeIntervalSince1970: 0)
    )

    XCTAssertTrue(transcript.contains("- 对话：发布前问答"))
    XCTAssertTrue(transcript.contains("- 上下文摘要：通用聊天"))
  }

}
