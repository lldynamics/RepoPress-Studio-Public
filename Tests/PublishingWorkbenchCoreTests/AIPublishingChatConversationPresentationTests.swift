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

  func testContextSummaryMatchesSiteAndGeneralModes() {
    let profile = SiteProfile(name: "主站")
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "发布检查",
      slug: "publish-check"
    )

    let siteSummary = AIPublishingChatConversationPresentation.contextSummary(
      profile: profile,
      draft: draft,
      contextMode: .site
    )
    let paragraphSummary = AIPublishingChatConversationPresentation.contextSummary(
      profile: profile,
      draft: draft,
      contextMode: .site,
      selectedParagraphTitle: "正文第 2 段"
    )
    let generalSummary = AIPublishingChatConversationPresentation.contextSummary(
      profile: profile,
      draft: draft,
      contextMode: .general
    )

    XCTAssertTrue(siteSummary.contains("主站"))
    XCTAssertTrue(siteSummary.contains("publish-check.md"))
    XCTAssertEqual(paragraphSummary, "主站 · 发布检查 · 正文第 2 段")
    XCTAssertEqual(generalSummary, "通用聊天 · 不读取当前文章或发布上下文")
  }

  func testContextDetailsExposeMobileStyleRetrievalBasisAndParagraphPreview() {
    let profile = SiteProfile(name: "主站")
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "发布检查",
      slug: "publish-check",
      bodyMarkdown: "第一段正文。"
    )
    let publicPeer = ArticleDraft(
      siteProfileID: profile.id,
      title: "公开文章",
      slug: "public-peer",
      visibility: .public
    )
    let privatePeer = ArticleDraft(
      siteProfileID: profile.id,
      title: "私密文章",
      slug: "private-peer",
      visibility: .private
    )
    let paragraph = AIPublishingChatDraftParagraph(
      id: "0-8",
      title: "正文第 1 段",
      text: "  这是一段会进入 AI 上下文预览的正文。  ",
      range: NSRange(location: 0, length: 8)
    )

    let siteDetails = AIPublishingChatConversationPresentation.contextDetails(
      profile: profile,
      draft: draft,
      visibleDrafts: [draft, publicPeer, privatePeer],
      contextMode: .site,
      selectedParagraph: paragraph,
      relatedSuggestionCount: 2
    )
    let generalDetails = AIPublishingChatConversationPresentation.contextDetails(
      profile: profile,
      draft: draft,
      visibleDrafts: [draft, publicPeer, privatePeer],
      contextMode: .general,
      relatedSuggestionCount: 2
    )

    XCTAssertEqual(siteDetails.title, "发布检查")
    XCTAssertEqual(siteDetails.retrievalBasis, "当前段落 + 当前文章 + 用户问题")
    XCTAssertEqual(siteDetails.publicCandidateCount, 1)
    XCTAssertEqual(siteDetails.relatedSuggestionCount, 2)
    XCTAssertEqual(siteDetails.selectedParagraphTitle, "正文第 1 段")
    XCTAssertEqual(siteDetails.selectedParagraphPreview, "这是一段会进入 AI 上下文预览的正文。")
    XCTAssertEqual(generalDetails.retrievalBasis, "当前对话消息")
    XCTAssertEqual(generalDetails.relatedSuggestionCount, 0)
    XCTAssertNil(generalDetails.selectedParagraphPreview)
  }

  func testModelSummaryUsesResolvedCustomModel() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )

    let summary = AIPublishingChatConversationPresentation.modelSummary(
      grade: .custom,
      config: config,
      selectedModel: "custom-reasoner"
    )

    XCTAssertEqual(summary, "自定义 · custom-reasoner")
  }

  func testConfigurationIssueMatchesMobileChatReadiness() {
    let remoteConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )
    let localConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-model",
      requiresAPIKey: false
    )
    XCTAssertEqual(
      AIPublishingChatConversationPresentation.configurationIssue(
        config: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: false),
        grade: .standard,
        selectedModel: ""
      ),
      "AI API Key 未保存，请先到设置里保存当前 Profile 的 API Key。"
    )
    XCTAssertNil(
      AIPublishingChatConversationPresentation.configurationIssue(
        config: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: true),
        grade: .standard,
        selectedModel: ""
      )
    )
    XCTAssertNil(
      AIPublishingChatConversationPresentation.configurationIssue(
        config: localConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: false),
        grade: .standard,
        selectedModel: ""
      )
    )
    XCTAssertEqual(
      AIPublishingChatConversationPresentation.configurationIssue(
        config: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: true),
        grade: .custom,
        selectedModel: " "
      ),
      "AI 模型名称为空，请先选择模型等级或填写模型名。"
    )
  }

  func testSendReadinessMatchesMobileChatGuards() {
    let remoteConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )
    let openAINoKeyConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: false
    )

    let ready = AIPublishingChatConversationPresentation.sendReadiness(
      inputText: "  帮我检查摘要  ",
      selectedImageCount: 0,
      isSending: false,
      config: remoteConfig,
      aiTokenAvailability: KeychainTokenAvailability(hasToken: true),
      grade: .standard,
      selectedModel: ""
    )
    XCTAssertTrue(ready.canSend)
    XCTAssertEqual(ready.trimmedInput, "帮我检查摘要")
    XCTAssertNil(ready.configurationIssue)
    XCTAssertNil(ready.imageAttachmentIssue)

    let running = AIPublishingChatConversationPresentation.sendReadiness(
      inputText: "帮我检查摘要",
      selectedImageCount: 0,
      isSending: true,
      config: remoteConfig,
      aiTokenAvailability: KeychainTokenAvailability(hasToken: true),
      grade: .standard,
      selectedModel: ""
    )
    XCTAssertFalse(running.canSend)

    let missingKey = AIPublishingChatConversationPresentation.sendReadiness(
      inputText: "帮我检查摘要",
      selectedImageCount: 0,
      isSending: false,
      config: remoteConfig,
      aiTokenAvailability: KeychainTokenAvailability(hasToken: false),
      grade: .standard,
      selectedModel: ""
    )
    XCTAssertFalse(missingKey.canSend)
    XCTAssertEqual(
      missingKey.configurationIssue,
      "AI API Key 未保存，请先到设置里保存当前 Profile 的 API Key。"
    )

    let noKeyRequired = AIPublishingChatConversationPresentation.sendReadiness(
      inputText: "帮我检查摘要",
      selectedImageCount: 0,
      isSending: false,
      config: openAINoKeyConfig,
      aiTokenAvailability: KeychainTokenAvailability(hasToken: false),
      grade: .standard,
      selectedModel: ""
    )
    XCTAssertTrue(noKeyRequired.canSend)
    XCTAssertNil(noKeyRequired.configurationIssue)
  }

  func testImageImportPresentationSelectsImportedImagesWithinRemainingSlots() {
    let presentation = AIPublishingChatImageAttachmentPresentation.importPresentation(
      importedCount: 2,
      availableSelectionSlots: 3
    )

    XCTAssertEqual(presentation.importedCount, 2)
    XCTAssertEqual(presentation.selectedCount, 2)
    XCTAssertEqual(presentation.skippedSelectionCount, 0)
    XCTAssertEqual(presentation.message, "已添加 2 张图片到当前文章，可随本次问题发送给 AI。")
  }

  func testImageImportPresentationReportsSkippedImagesWhenImportExceedsRemainingSlots() {
    let presentation = AIPublishingChatImageAttachmentPresentation.importPresentation(
      importedCount: 5,
      availableSelectionSlots: 2
    )

    XCTAssertEqual(presentation.importedCount, 5)
    XCTAssertEqual(presentation.selectedCount, 2)
    XCTAssertEqual(presentation.skippedSelectionCount, 3)
    XCTAssertEqual(presentation.message, "已添加 5 张图片到当前文章；本次已选 2 张，另有 3 张因最多 4 张限制未附加。")
  }

  func testImageImportPresentationReportsOversizedImagesSeparately() {
    let sizeLimitText = AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()
    let presentation = AIPublishingChatImageAttachmentPresentation.importPresentation(
      importedCount: 4,
      selectableImportedCount: 2,
      availableSelectionSlots: 1
    )

    XCTAssertEqual(presentation.importedCount, 4)
    XCTAssertEqual(presentation.selectedCount, 1)
    XCTAssertEqual(presentation.skippedSelectionCount, 1)
    XCTAssertEqual(presentation.skippedSizeCount, 2)
    XCTAssertEqual(
      presentation.message,
      "已添加 4 张图片到当前文章；本次已选 1 张，另有 1 张因最多 4 张限制未附加，2 张超过 \(sizeLimitText)，未附加给 AI。"
    )
  }

  func testImageImportPresentationHandlesNoRemainingSlotsAndEmptyImports() {
    let noSlots = AIPublishingChatImageAttachmentPresentation.importPresentation(
      importedCount: 3,
      availableSelectionSlots: 0
    )

    XCTAssertEqual(noSlots.selectedCount, 0)
    XCTAssertEqual(noSlots.skippedSelectionCount, 3)
    XCTAssertEqual(noSlots.message, "已添加 3 张图片到当前文章；本次已选 0 张，另有 3 张因最多 4 张限制未附加。")

    let empty = AIPublishingChatImageAttachmentPresentation.importPresentation(
      importedCount: -1,
      availableSelectionSlots: -2
    )

    XCTAssertEqual(empty.importedCount, 0)
    XCTAssertEqual(empty.selectedCount, 0)
    XCTAssertEqual(empty.skippedSelectionCount, 0)
    XCTAssertEqual(empty.message, "没有可添加的图片文件。")
  }

  func testImageAttachmentMaximumSelectionMessageMatchesMobileLimit() {
    XCTAssertEqual(
      AIPublishingChatImageAttachmentPresentation.maximumSelectionMessage(),
      "一次最多附加 4 张图片给 AI。"
    )
    XCTAssertEqual(AIPublishingChatImageAttachmentPresentation.maxAttachmentBytes, 8 * 1_024 * 1_024)
    XCTAssertTrue(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText().contains("8.4"))
    XCTAssertTrue(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText().contains("MB"))
  }

  func testMessageActionAvailabilityMatchesMobileImageOnlyMessageActions() {
    let imageOnlyMessage = AIPublishingChatMessage(
      role: .user,
      content: " \n ",
      imageAttachments: [
        AIChatImageAttachment(filename: "cover.png", mimeType: "image/png", data: Data("image".utf8))
      ]
    )

    let imageOnlyAvailability = AIPublishingChatMessageActionAvailabilityService.availability(
      for: imageOnlyMessage,
      isSending: false,
      configurationIssue: nil,
      hasSelectedDraft: true
    )

    XCTAssertTrue(imageOnlyAvailability.canCopy)
    XCTAssertTrue(imageOnlyAvailability.canQuote)
    XCTAssertFalse(imageOnlyAvailability.canRegenerate)
    XCTAssertFalse(imageOnlyAvailability.canApplyToArticle)

    let assistantReply = AIPublishingChatMessage(
      role: .assistant,
      content: "可以把摘要缩短到 120 字以内。",
      contextMode: .site
    )
    let assistantAvailability = AIPublishingChatMessageActionAvailabilityService.availability(
      for: assistantReply,
      isSending: false,
      configurationIssue: nil,
      hasSelectedDraft: true
    )

    XCTAssertTrue(assistantAvailability.canCopy)
    XCTAssertTrue(assistantAvailability.canQuote)
    XCTAssertTrue(assistantAvailability.canRegenerate)
    XCTAssertTrue(assistantAvailability.canApplyToArticle)

    let blockedRegeneration = AIPublishingChatMessageActionAvailabilityService.availability(
      for: assistantReply,
      isSending: false,
      configurationIssue: "AI API Key 未保存",
      hasSelectedDraft: true
    )

    XCTAssertFalse(blockedRegeneration.canRegenerate)
    XCTAssertTrue(blockedRegeneration.canApplyToArticle)
  }
}
