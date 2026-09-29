import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatConversationPresentationTests: XCTestCase {
  func testDisplayTitleUsesFirstUserMessageBeforeDraftTitle() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "原文章标题",
      slug: "article"
    )
    let messages = [
      AIPublishingChatMessage(role: .assistant, content: "先给一个提示。"),
      AIPublishingChatMessage(role: .user, content: "  帮我检查这篇文章的发布风险  "),
    ]

    let title = AIPublishingChatConversationPresentation.displayTitle(
      messages: messages,
      draft: draft
    )

    XCTAssertEqual(title, "帮我检查这篇文章的发布风险")
  }

  func testDisplayTitleUsesExplicitConversationTitleBeforeMessages() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "原文章标题",
      slug: "article"
    )
    let messages = [
      AIPublishingChatMessage(role: .user, content: "帮我检查这篇文章的发布风险")
    ]

    let title = AIPublishingChatConversationPresentation.displayTitle(
      conversationTitle: "  发布前最终审稿  ",
      messages: messages,
      draft: draft
    )

    XCTAssertEqual(title, "发布前最终审稿")
  }

  func testDisplayTitleUsesImageAttachmentNamesForImageOnlyFirstUserMessage() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "原文章标题",
      slug: "article"
    )
    let messages = [
      AIPublishingChatMessage(
        role: .user,
        content: " \n ",
        imageAttachments: [
          AIChatImageAttachment(filename: "cover.png", mimeType: "image/png", data: Data("image".utf8))
        ]
      )
    ]

    let title = AIPublishingChatConversationPresentation.displayTitle(
      messages: messages,
      draft: draft
    )

    XCTAssertEqual(title, "已附加图片：cover.png")
  }

  func testDisplayTitleFallsBackToDraftTitleAndEmptyTitle() {
    let titledDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "原文章标题",
      slug: "article"
    )
    let untitledDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: " ",
      slug: "untitled"
    )

    XCTAssertEqual(
      AIPublishingChatConversationPresentation.displayTitle(messages: [], draft: titledDraft),
      "原文章标题"
    )
    XCTAssertEqual(
      AIPublishingChatConversationPresentation.displayTitle(messages: [], draft: untitledDraft),
      "AI 对话"
    )
  }

  func testTitleFromUserTextTruncatesLongFirstMessage() {
    let title = AIPublishingChatConversationPresentation.title(
      fromUserText: "请把这篇文章改成更适合个人网站发布的摘要和标题",
      fallbackTitle: "AI 对话",
      maxLength: 8
    )

    XCTAssertEqual(title, "请把这篇文章改成...")
  }
}
