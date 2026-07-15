import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreAIPromptTests: XCTestCase {
  func testAIEntryOpensInspectorAssistantBesideWritingWorkspace() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    XCTAssertFalse(store.isAIPublishingAssistantPresented)
    store.setInspectorPresented(false)

    _ = store.openAIChatWorkspace(for: draft.id)

    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertTrue(store.isInspectorPresented)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertEqual(store.aiChatDraftID, draft.id)

    store.selectSection(.contentHealth)

    XCTAssertFalse(store.isAIPublishingAssistantPresented)

    store.showAIPublishingAssistant(for: draft.id)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.selectedSection, .writing)

    store.selectDraft(nil)

    XCTAssertFalse(store.isAIPublishingAssistantPresented)

    store.selectSection(.ai)

    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
  }

  func testAIEntryCanCarryQuickPromptIntoInspectorAssistant() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    _ = store.openAIChatWorkspace(for: draft.id, quickPrompt: .frontMatterPack)

    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertEqual(store.aiChatDraftID, draft.id)
    XCTAssertEqual(store.pendingAIQuickPrompt, .frontMatterPack)
    XCTAssertEqual(store.consumePendingAIQuickPrompt(), .frontMatterPack)
    XCTAssertNil(store.pendingAIQuickPrompt)
    XCTAssertNil(store.consumePendingAIQuickPrompt())
  }

  func testAIChatCustomPromptsPersistAndCanBeDeleted() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )

    let saved = try XCTUnwrap(
      store.saveAIChatCustomPrompt(
        title: "发布前检查",
        prompt: "帮我按发布前清单检查当前文章。"
      )
    )

    XCTAssertEqual(store.aiChatCustomPrompts.map(\.id), [saved.id])
    XCTAssertEqual(store.aiChatCustomPrompts.first?.title, "发布前检查")
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )

    XCTAssertEqual(reloaded.aiChatCustomPrompts.map(\.id), [saved.id])

    reloaded.deleteAIChatCustomPrompt(saved.id)

    XCTAssertTrue(reloaded.aiChatCustomPrompts.isEmpty)
    XCTAssertEqual(reloaded.aiChatMessage, "已删除自定义提示。")
  }

  func testAIChatBranchArchivesOriginalConversationAndTruncatesAtSelectedMessage() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    let first = AIPublishingChatMessage(role: .user, content: "第一问")
    let second = AIPublishingChatMessage(role: .assistant, content: "第一答")
    let third = AIPublishingChatMessage(role: .user, content: "第二问")
    let fourth = AIPublishingChatMessage(role: .assistant, content: "第二答")
    store.setAIChatMessages([first, second, third, fourth])

    store.branchAIChatConversation(after: second.id, draft: draft)

    XCTAssertEqual(store.aiChatMessages.map(\.id), [first.id, second.id])
    XCTAssertEqual(store.aiChatArchivedConversations.count, 1)
    XCTAssertEqual(store.aiChatArchivedConversations.first?.messages.map(\.id), [first.id, second.id, third.id, fourth.id])
    XCTAssertEqual(store.aiChatMessage, "已从所选消息创建分支，原对话已存入历史。")
  }

  func testAIChatModelSelectionUsesMobileModelCandidatesAndDefaultReset() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    _ = store.openAIChatWorkspace(for: draft.id)
    store.setAIChatModelGrade(.highQuality)

    XCTAssertEqual(store.aiChatModelGrade, .highQuality)
    XCTAssertEqual(store.aiChatSelectedModel, "deepseek-v4-pro")

    store.setAIChatCustomModel("custom-chat-model")

    XCTAssertEqual(store.aiChatModelGrade, .custom)
    XCTAssertEqual(store.aiChatSelectedModel, "custom-chat-model")

    store.resetAIChatModelToProfileDefault()

    XCTAssertEqual(store.aiChatModelGrade, .standard)
    XCTAssertEqual(store.aiChatSelectedModel, "deepseek-v4-flash")
  }

  func testCopiedPublishingPromptIncludesSameMacWorkflowContextAsAIActions() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    let prompt = store.publishingAIPrompt(for: draft)

    XCTAssertTrue(prompt.contains("发布准备建议"))
    XCTAssertTrue(prompt.contains("Mac 发布上下文："))
    XCTAssertTrue(prompt.contains("本地 diff："))
    XCTAssertTrue(prompt.contains("本地预览："))
    XCTAssertTrue(prompt.contains("图片检查："))
    XCTAssertTrue(prompt.contains("PR/MR 描述草稿"))
  }

  func testCopiedPublishingPromptIncludesRemoteSamePathRisk() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "AI Remote Risk",
      slug: "ai-remote-risk",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so the AI prompt test focuses on remote same-path publishing risk."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(status: "M", path: "content/posts/ai-remote-risk.md", kind: .modified)
      ],
      preflightIssues: []
    ))

    let prompt = store.publishingAIPrompt(for: draft)

    XCTAssertTrue(prompt.contains("远端同路径变更"))
    XCTAssertTrue(prompt.contains("content/posts/ai-remote-risk.md"))
  }

  func testPublishingContextPromptSummarizesMacWorkbenchStateForChatComposer() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let profile = store.profile(for: draft)

    let prompt = AIPublishingChatPromptTemplateService.publishingContextPrompt(
      for: draft,
      profile: profile,
      issues: store.preflightIssues(for: draft),
      package: store.publishingPackage(for: draft),
      imageReport: store.imageWorkbenchReport(for: draft)
    )

    XCTAssertTrue(prompt.contains("[发布上下文]"))
    XCTAssertTrue(prompt.contains("站点：\(profile.name)"))
    XCTAssertTrue(prompt.contains("发布路径：\(profile.markdownPath(for: draft))"))
    XCTAssertTrue(prompt.contains("发布文件"))
    XCTAssertTrue(prompt.contains("发布检查"))
    XCTAssertTrue(prompt.contains("图片检查"))
    XCTAssertTrue(prompt.contains("封面状态"))
    XCTAssertTrue(prompt.contains("不要编造已经完成的线上验证"))
  }

  func testAIChatRejectsImageAttachmentsWhenActiveProviderDoesNotSupportVision() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let attachment = AIChatImageAttachment(
      filename: "cover.png",
      mimeType: "image/png",
      data: Data("image".utf8)
    )

    let reply = await store.sendAIChatMessage(
      "帮我看图。",
      draft: draft,
      imageAttachments: [attachment]
    )

    XCTAssertNil(reply)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(
      store.aiChatMessage,
      "DeepSeek 当前接口不支持图片输入，请切换到支持视觉输入的 OpenAI-compatible 模型。"
    )
  }

  func testQuickPromptLibraryCoversMobilePublishingCapabilityGroups() {
    let sections = AIPublishingQuickPrompt.capabilitySections
    let sectionGroups = Set(sections.map(\.group))
    let sectionPrompts = Set(sections.flatMap(\.prompts))

    XCTAssertGreaterThanOrEqual(AIPublishingQuickPrompt.allCases.count, 45)
    XCTAssertEqual(sectionGroups, Set(AIPublishingQuickPromptGroup.allCases))
    XCTAssertEqual(sectionPrompts, Set(AIPublishingQuickPrompt.allCases))
    XCTAssertTrue(AIPublishingQuickPrompt.allCases.contains(.slugIdeas))
    XCTAssertTrue(AIPublishingQuickPrompt.allCases.contains(.tagIdeas))
    XCTAssertTrue(AIPublishingQuickPrompt.allCases.contains(.publishNote))
    XCTAssertTrue(AIPublishingQuickPrompt.allCases.contains(.crossPlatformAnnouncement))
    XCTAssertTrue(AIPublishingQuickPrompt.allCases.contains(.shortVideoScript))
    XCTAssertTrue(sections.allSatisfy { !$0.prompts.isEmpty })
    XCTAssertEqual(
      AIPublishingQuickPrompt.featuredCapabilitySections.flatMap(\.prompts),
      AIPublishingQuickPrompt.primaryPrompts
    )
    XCTAssertEqual(AIPublishingQuickPrompt.inspectorPrompts, AIPublishingQuickPrompt.primaryPrompts)
  }

  func testWritingDashboardPromptsMirrorMobileAIEntryActions() {
    XCTAssertEqual(
      AIPublishingQuickPrompt.writingDashboardPrompts,
      [
        .continueWriting,
        .outline,
        .titleIdeas,
        .tone,
        .grammar,
        .translateChinese,
        .translateEnglish,
        .frontMatterPack,
        .publishReview,
        .internalLinks,
        .imageCaptions,
        .publishAssetPack,
        .seriesPlan,
      ]
    )

    let summary = AIPublishingDashboardPromptService.summary()

    XCTAssertEqual(summary.prompts, AIPublishingQuickPrompt.writingDashboardPrompts)
    XCTAssertEqual(summary.promptCount, AIPublishingQuickPrompt.writingDashboardPrompts.count)
    XCTAssertTrue(summary.summaryText.contains("续写"))
    XCTAssertTrue(summary.summaryText.contains("发布素材包"))
    XCTAssertTrue(summary.summaryText.contains("系列选题"))
  }

  func testQuickPromptsPreservePublishingSafetyBoundaries() {
    XCTAssertTrue(AIPublishingQuickPrompt.internalLinks.prompt.contains("不要编造不存在的真实路径"))
    XCTAssertTrue(AIPublishingQuickPrompt.factBoundary.prompt.contains("不要联网核验"))
    XCTAssertTrue(AIPublishingQuickPrompt.sourceChecklist.prompt.contains("不要编造真实链接"))
    XCTAssertTrue(AIPublishingQuickPrompt.imagePrivacy.prompt.contains("不要假装看到了图片内容"))
    XCTAssertTrue(AIPublishingQuickPrompt.slugIdeas.prompt.contains("kebab-case"))
    XCTAssertTrue(AIPublishingQuickPrompt.tagIdeas.prompt.contains("3 到 8"))
    XCTAssertTrue(AIPublishingQuickPrompt.publishNote.prompt.contains("commit message"))
    XCTAssertTrue(AIPublishingQuickPrompt.crossPlatformAnnouncement.prompt.contains("RSS 摘要"))
    XCTAssertTrue(AIPublishingQuickPrompt.shortVideoScript.prompt.contains("15 秒"))
    XCTAssertTrue(AIPublishingQuickPrompt.ssgChecklist.prompt.contains("Hexo"))
    XCTAssertTrue(AIPublishingQuickPrompt.ssgChecklist.prompt.contains("Hugo"))
    XCTAssertTrue(AIPublishingQuickPrompt.ssgChecklist.prompt.contains("Zola"))
    XCTAssertTrue(AIPublishingQuickPrompt.ssgChecklist.prompt.contains("Astro"))
    XCTAssertTrue(AIPublishingQuickPrompt.ssgChecklist.prompt.contains("Jekyll"))
  }

  func testPromptLibraryExposesMobileInspiredEditorActionsAcrossGroups() {
    XCTAssertGreaterThanOrEqual(AIPublishingActionKind.promptLibraryActions.count, 40)
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftFullArticle))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftOpening))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.sharpenOpeningSelection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.expandOutlineToDraft))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftReaderQuestions))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftTransitionSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftExampleSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftTutorialVersion))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftChecklistSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftTroubleshootingSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftCodeExample))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftGlossary))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftReferencesSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftInterviewQA))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.reorganizeStructure))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftCounterpointSection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftCaseStudySection))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftBilingualRewrite))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.suggestTitles))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.suggestSlug))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.suggestSummary))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.suggestTags))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftFrontMatterPack))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftBilingualMetadata))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftSourceChecklist))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.flagUnsupportedClaims))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.auditLinkQuality))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.auditImagePrivacy))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.reviewSSGCompatibility))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.reviewReaderClarity))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.reviewTechnicalAccuracy))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftImageAltCaptions))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftContentRefreshPlan))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftNewsletterSummary))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftPublishNote))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftCrossPlatformAnnouncement))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftShortVideoScript))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftUpdateNote))
    XCTAssertTrue(AIPublishingActionKind.promptLibraryActions.contains(.draftCommentReply))

    let groups = Set(AIPublishingActionKind.promptLibraryActions.map(\.promptLibraryGroup))

    XCTAssertEqual(groups, Set(AIPublishingQuickPromptGroup.allCases))

    let distributionSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "素材"
    )
    XCTAssertTrue(
      visiblePromptLibraryActions(distributionSnapshot).contains(.draftPublishAssetPack)
    )

    let writingSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .writing,
      searchText: "故障排查"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(writingSnapshot),
      [.draftTroubleshootingSection]
    )

    let glossarySnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .writing,
      searchText: "术语表"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(glossarySnapshot),
      [.draftGlossary]
    )

    let structureSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .writing,
      searchText: "结构重排"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(structureSnapshot),
      [.reorganizeStructure]
    )

    let bilingualRewriteSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .editing,
      searchText: "中英文两个版本"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(bilingualRewriteSnapshot),
      [.draftBilingualRewrite]
    )

    let maintenanceSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .maintenance,
      searchText: "旧文"
    )
    XCTAssertTrue(
      visiblePromptLibraryActions(maintenanceSnapshot).contains(.draftContentRefreshPlan)
    )

    let publishingSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .publishing,
      searchText: "中英"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(publishingSnapshot),
      [.draftBilingualMetadata]
    )

    let frontMatterSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .publishing,
      searchText: "Front Matter 套餐"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(frontMatterSnapshot),
      [.draftFrontMatterPack]
    )

    let factBoundarySnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .publishing,
      searchText: "事实边界"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(factBoundarySnapshot),
      [.flagUnsupportedClaims]
    )

    let imagePrivacySnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .publishing,
      searchText: "图片隐私"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(imagePrivacySnapshot),
      [.auditImagePrivacy]
    )

    let ssgSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .publishing,
      searchText: "Jekyll"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(ssgSnapshot),
      [.reviewSSGCompatibility]
    )

    let newsletterSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "一句话导读"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(newsletterSnapshot),
      [.draftNewsletterSummary]
    )

    let crossPlatformSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "跨平台发布摘要"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(crossPlatformSnapshot),
      [.draftCrossPlatformAnnouncement]
    )

    let commentReplySnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .maintenance,
      searchText: "评论回复"
    )
    XCTAssertEqual(
      visiblePromptLibraryActions(commentReplySnapshot),
      [.draftCommentReply]
    )
  }

  func testPromptLibraryRecommendationsFollowDraftAndSelectionContext() {
    let bodyDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "发布工作台",
      summary: "把文章发布流程收束到桌面端。",
      bodyMarkdown: "正文已经有足够内容，可以继续写、补摘要并做发布前检查。"
    )

    let bodyRecommendation = AIPublishingActionRecommendationService.recommendation(draft: bodyDraft)
    XCTAssertEqual(
      bodyRecommendation.actions,
      [
        .continueArticle,
        .draftArticleTLDR,
        .suggestArticleOutline,
        .suggestTitles,
        .draftFrontMatterPack,
        .publishingReadiness,
        .reviewSEOReadability,
        .suggestInternalLinks,
      ]
    )
    XCTAssertEqual(bodyRecommendation.preferredScope, .all)

    let selectedTextRecommendation = AIPublishingActionRecommendationService.recommendation(
      selectedText: "这段文字需要改写。",
      draft: bodyDraft
    )
    XCTAssertEqual(
      selectedTextRecommendation.actions,
      AIPublishingWritingActionCatalog.selectedTextRecommendedEditorActions.map(\.kind)
    )
    XCTAssertEqual(selectedTextRecommendation.preferredScope, .editing)

    let seedDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "只有标题",
      summary: "先从标题和摘要扩展。",
      bodyMarkdown: "   "
    )
    XCTAssertEqual(
      AIPublishingActionRecommendationService.recommendation(draft: seedDraft).actions,
      [.draftOpening, .draftFullArticle, .suggestArticleOutline, .suggestTitles, .suggestSummary, .suggestTags]
    )

    let emptyDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: " ",
      summary: " ",
      bodyMarkdown: "\n"
    )
    XCTAssertEqual(
      AIPublishingActionRecommendationService.recommendation(draft: emptyDraft).actions,
      [.draftOpening, .draftFullArticle, .suggestArticleOutline, .suggestTitles]
    )
  }

  func testPromptLibrarySnapshotPromotesRecommendedActionsAndWorkflowGuides() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "AI 工作流",
      summary: "验证推荐动作。",
      bodyMarkdown: "正文已经存在，应该优先展示续写、摘要、标题和发布检查。"
    )

    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "",
      draft: draft
    )

    XCTAssertEqual(snapshot.recommendation?.title, "推荐动作")
    XCTAssertTrue(snapshot.recommendation?.actions.contains(.continueArticle) == true)
    XCTAssertTrue(snapshot.recommendation?.actions.contains(.publishingReadiness) == true)
    XCTAssertEqual(
      snapshot.recommendedWorkflowGuides.map(\.id),
      ["idea-to-draft", "selection-rewrite", "publish-readiness", "distribution-pack"]
    )
    XCTAssertFalse(snapshot.editorActionSections.flatMap(\.actions).contains(.continueArticle))
    XCTAssertFalse(snapshot.workflowGuides.map(\.id).contains("idea-to-draft"))

    let editingSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .editing,
      searchText: "",
      selectedText: "需要润色的选区",
      draft: draft
    )
    XCTAssertEqual(
      editingSnapshot.recommendation?.actions,
      AIPublishingWritingActionCatalog.selectedTextRecommendedEditorActions.map(\.kind)
    )
    XCTAssertEqual(
      editingSnapshot.recommendedWorkflowGuides.map(\.id),
      ["selection-rewrite", "selection-to-structure", "bilingual-release-kit"]
    )
    XCTAssertFalse(editingSnapshot.editorActionSections.flatMap(\.actions).contains(.polishSelection))

    let searchSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "pullRequestDescription",
      draft: draft
    )
    XCTAssertNil(searchSnapshot.recommendation)
    XCTAssertTrue(searchSnapshot.recommendedWorkflowGuides.isEmpty)
    XCTAssertEqual(searchSnapshot.editorActionSections.flatMap(\.actions), [.pullRequestDescription])
  }

  func testWritingActionCatalogFeedsMacEditorEntryPoints() {
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.selectionActions.map(\.kind).contains(.rewriteSelection)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.selectionActions.map(\.kind).contains(.sharpenOpeningSelection)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.selectionActions.map(\.kind).contains(.draftBilingualRewrite)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.draftFullArticle)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.expandOutlineToDraft)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.draftChecklistSection)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.draftCodeExample)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.draftGlossary)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.reorganizeStructure)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.writingActions.map(\.kind).contains(.draftReferencesSection)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.reviewSEOReadability)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.suggestTitles)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.draftFrontMatterPack)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.draftBilingualMetadata)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.flagUnsupportedClaims)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.auditImagePrivacy)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.publishingActions.map(\.kind).contains(.reviewTechnicalAccuracy)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.distributionActions.map(\.kind).contains(.draftPublishAssetPack)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.distributionActions.map(\.kind).contains(.draftNewsletterSummary)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.distributionActions.map(\.kind).contains(.draftPublishNote)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.distributionActions.map(\.kind).contains(.draftCrossPlatformAnnouncement)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.distributionActions.map(\.kind).contains(.draftShortVideoScript)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.maintenanceActions.map(\.kind).contains(.draftContentRefreshPlan)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.maintenanceActions.map(\.kind).contains(.draftUpdateNote)
    )
    XCTAssertTrue(
      AIPublishingWritingActionCatalog.maintenanceActions.map(\.kind).contains(.draftCommentReply)
    )

    let articleActionKinds = Set(AIPublishingWritingActionCatalog.articleActions.map(\.kind))

    XCTAssertTrue(articleActionKinds.isSuperset(of: Set(AIPublishingWritingActionCatalog.writingActions.map(\.kind))))
    XCTAssertTrue(articleActionKinds.isSuperset(of: Set(AIPublishingWritingActionCatalog.publishingActions.map(\.kind))))
    XCTAssertTrue(articleActionKinds.isSuperset(of: Set(AIPublishingWritingActionCatalog.distributionActions.map(\.kind))))
    XCTAssertTrue(articleActionKinds.isSuperset(of: Set(AIPublishingWritingActionCatalog.maintenanceActions.map(\.kind))))
    XCTAssertTrue(AIPublishingWritingActionCatalog.articleActions.allSatisfy { !$0.systemImage.isEmpty })
  }

  func testApplyAIMetadataSuggestionUpdatesCurrentDraftFields() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    var updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(field: .title, value: "  AI 生成标题  ", draft: draft)
    )
    XCTAssertEqual(updated.title, "AI 生成标题")
    XCTAssertEqual(store.drafts.first { $0.id == draft.id }?.title, "AI 生成标题")
    XCTAssertEqual(store.aiActionMessage, "已应用 AI 标题建议。")

    updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(field: .slug, value: "  AI Generated Slug.md  ", draft: updated)
    )
    XCTAssertEqual(updated.slug, "ai-generated-slug")

    updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(field: .summary, value: "  这是一段 AI 生成的摘要，用于检查写回行为。  ", draft: updated)
    )
    XCTAssertEqual(updated.summary, "这是一段 AI 生成的摘要，用于检查写回行为。")

    updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(
        field: .tags,
        value: " #SwiftUI, AI，SwiftUI、发布 ",
        draft: updated
      )
    )
    XCTAssertEqual(updated.tags, ["SwiftUI", "AI", "发布"])
  }

  func testApplyAIMetadataSuggestionRejectsEmptyValues() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    XCTAssertNil(store.applyAIMetadataSuggestion(field: .summary, value: "   ", draft: draft))
    XCTAssertEqual(store.drafts.first { $0.id == draft.id }?.summary, draft.summary)
    XCTAssertEqual(store.aiActionMessage, "AI 摘要建议为空，未应用。")
  }

  func testApplyAllAIMetadataSuggestionsUpdatesChangedFields() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let suggestion = AIPublishingMetadataSuggestion(
      titles: ["  AI 批量标题  ", "备用标题"],
      slugs: ["  AI Batch Slug.markdown  "],
      summary: "  AI 批量摘要  ",
      tags: ["#SwiftUI", "AI，发布", "SwiftUI"]
    )

    let updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(suggestion, draft: draft)
    )

    XCTAssertEqual(updated.title, "AI 批量标题")
    XCTAssertEqual(updated.slug, "ai-batch-slug")
    XCTAssertEqual(updated.summary, "AI 批量摘要")
    XCTAssertEqual(updated.tags, ["SwiftUI", "AI", "发布"])
    XCTAssertEqual(
      store.aiActionMessage,
      "已应用 AI 元数据建议：标题、Slug、摘要、Tags。"
    )
  }

  func testApplyAllAIMetadataSuggestionsSkipsUnchangedFields() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let suggestion = AIPublishingMetadataSuggestion(
      titles: [draft.title],
      slugs: [draft.slug],
      summary: draft.summary,
      tags: draft.tags
    )

    XCTAssertNil(store.applyAIMetadataSuggestion(suggestion, draft: draft))
    XCTAssertEqual(
      store.aiActionMessage,
      "AI 元数据建议没有可应用的新内容。"
    )
  }

  func testMetadataActionSuggestionFactoryParsesGranularAndFrontMatterActions() {
    XCTAssertTrue(AIPublishingActionKind.suggestTitles.producesMetadataSuggestion)
    XCTAssertTrue(AIPublishingActionKind.suggestSlug.producesMetadataSuggestion)
    XCTAssertTrue(AIPublishingActionKind.suggestSummary.producesMetadataSuggestion)
    XCTAssertTrue(AIPublishingActionKind.suggestTags.producesMetadataSuggestion)
    XCTAssertTrue(AIPublishingActionKind.draftFrontMatterPack.producesMetadataSuggestion)
    XCTAssertTrue(AIPublishingActionKind.draftBilingualMetadata.producesMetadataSuggestion)
    XCTAssertFalse(AIPublishingActionKind.continueArticle.producesMetadataSuggestion)
    XCTAssertFalse(AIPublishingActionKind.publishingReadiness.producesMetadataSuggestion)

    let titleSuggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(
      from: AIPublishingActionResult(
        kind: .suggestTitles,
        content: """
        1. “Mac AI 发布助手”
        - Mac AI 发布助手
        - 用 AI 检查个人网站文章
        """
      )
    )
    XCTAssertEqual(titleSuggestion?.titles, ["Mac AI 发布助手", "用 AI 检查个人网站文章"])
    XCTAssertTrue(titleSuggestion?.slugs.isEmpty == true)

    let slugSuggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(
      from: AIPublishingActionResult(
        kind: .suggestSlug,
        content: """
        - Mac AI Publishing Assistant.md
        - personal-site-ai-review.markdown
        """
      )
    )
    XCTAssertEqual(slugSuggestion?.slugs, ["mac-ai-publishing-assistant", "personal-site-ai-review"])

    let summarySuggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(
      from: AIPublishingActionResult(
        kind: .suggestSummary,
        content: "“用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认。”"
      )
    )
    XCTAssertEqual(
      summarySuggestion?.summary,
      "用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认"
    )

    let tagSuggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(
      from: AIPublishingActionResult(
        kind: .suggestTags,
        content: "#Mac，AI, Publishing; AI"
      )
    )
    XCTAssertEqual(tagSuggestion?.tags, ["Mac", "AI", "Publishing"])

    let frontMatterPackSuggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(
      from: AIPublishingActionResult(
        kind: .draftFrontMatterPack,
        content: """
        ## Front Matter 套餐
        ### 标题候选 3 个
        - Mac AI 发布助手
        - 用 AI 检查个人网站文章

        ### slug 候选 3 个
        - mac-ai-publishing-assistant
        - personal-site-ai-review

        ### summary/description 候选 2 条
        - 用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认。

        ### tags 候选 5 到 8 个
        - Mac
        - AI
        - Publishing
        """
      )
    )
    XCTAssertEqual(frontMatterPackSuggestion?.titles.first, "Mac AI 发布助手")
    XCTAssertEqual(frontMatterPackSuggestion?.slugs.first, "mac-ai-publishing-assistant")
    XCTAssertEqual(
      frontMatterPackSuggestion?.summary,
      "用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认"
    )
    XCTAssertEqual(frontMatterPackSuggestion?.tags, ["Mac", "AI", "Publishing"])
  }

  func testActionAvailabilityUsesMobileContextRequirements() {
    let emptyDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: " ",
      summary: " ",
      bodyMarkdown: "\n"
    )
    let titleOnlyDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "只有标题",
      summary: " ",
      bodyMarkdown: "\n"
    )
    let bodyDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: " ",
      summary: " ",
      bodyMarkdown: "正文内容可以作为 AI 上下文。"
    )

    XCTAssertFalse(AIPublishingActionAvailabilityService.canRun(.polishSelection, draft: bodyDraft))
    XCTAssertTrue(
      AIPublishingActionAvailabilityService.canRun(
        .polishSelection,
        selectedText: "选中的正文",
        draft: emptyDraft
      )
    )

    XCTAssertFalse(AIPublishingActionAvailabilityService.canRun(.continueArticle, draft: titleOnlyDraft))
    XCTAssertTrue(AIPublishingActionAvailabilityService.canRun(.continueArticle, draft: bodyDraft))
    XCTAssertTrue(
      AIPublishingActionAvailabilityService.canRun(
        .continueArticle,
        selectedText: "选中的续写种子",
        draft: emptyDraft
      )
    )

    XCTAssertFalse(AIPublishingActionAvailabilityService.canRun(.draftArticleFAQ, draft: titleOnlyDraft))
    XCTAssertTrue(AIPublishingActionAvailabilityService.canRun(.draftArticleFAQ, draft: bodyDraft))

    XCTAssertFalse(AIPublishingActionAvailabilityService.canRun(.draftOpening, draft: emptyDraft))
    XCTAssertTrue(AIPublishingActionAvailabilityService.canRun(.draftOpening, draft: titleOnlyDraft))
    XCTAssertTrue(AIPublishingActionAvailabilityService.canRun(.suggestTitles, draft: titleOnlyDraft))
    XCTAssertTrue(AIPublishingActionAvailabilityService.canRun(.publishingReadiness, draft: titleOnlyDraft))

    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .polishSelection,
        draft: bodyDraft
      ),
      AIPublishingActionAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "需要先选择正文"
      )
    )
    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .continueArticle,
        draft: titleOnlyDraft
      ).unavailableReason,
      "需要选择正文或补充文章正文"
    )
    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .draftArticleFAQ,
        draft: titleOnlyDraft
      ).unavailableReason,
      "需要先补充文章正文"
    )
    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .suggestTitles,
        draft: titleOnlyDraft,
        isAIEnabled: false
      ),
      AIPublishingActionAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "需要先启用 AI"
      )
    )
    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .suggestTitles,
        draft: titleOnlyDraft,
        activeAction: .suggestTitles
      ),
      AIPublishingActionAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "AI 正在处理"
      )
    )
    XCTAssertEqual(
      AIPublishingActionAvailabilityService.presentation(
        for: .suggestTitles,
        draft: titleOnlyDraft
      ),
      AIPublishingActionAvailabilityPresentation(isEnabled: true)
    )
  }

  func testAIMetadataApplicationRecordPersistsAndRollsBackChangedFields() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let suggestion = AIPublishingMetadataSuggestion(
      titles: ["可回滚标题"],
      slugs: ["rollback-title.md"],
      summary: "可回滚摘要",
      tags: ["AI", "回滚"]
    )

    let updated = try XCTUnwrap(
      store.applyAIMetadataSuggestion(suggestion, draft: draft)
    )
    let record = try XCTUnwrap(store.recentAIMetadataApplicationRecords(for: updated).first)

    XCTAssertEqual(record.draftID, draft.id)
    XCTAssertEqual(record.fields, [.title, .slug, .summary, .tags])
    XCTAssertEqual(record.previousTitle, draft.title)
    XCTAssertEqual(record.newTitle, "可回滚标题")
    XCTAssertEqual(record.previousSlug, draft.slug)
    XCTAssertEqual(record.newSlug, "rollback-title")
    XCTAssertEqual(record.previousSummary, draft.summary)
    XCTAssertEqual(record.newSummary, "可回滚摘要")
    XCTAssertEqual(record.previousTags, draft.tags)
    XCTAssertEqual(record.newTags, ["AI", "回滚"])
    await store.waitForPendingSave()

    let reloadedStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let reloadedDraft = try XCTUnwrap(reloadedStore.selectedDraft)
    XCTAssertEqual(reloadedStore.recentAIMetadataApplicationRecords(for: reloadedDraft).first?.id, record.id)

    let restored = try XCTUnwrap(
      reloadedStore.rollbackAIMetadataApplicationRecord(record)
    )
    XCTAssertEqual(restored.title, draft.title)
    XCTAssertEqual(restored.slug, draft.slug)
    XCTAssertEqual(restored.summary, draft.summary)
    XCTAssertEqual(restored.tags, draft.tags)
    XCTAssertEqual(
      reloadedStore.aiActionMessage,
      "已回滚 AI 元数据应用：标题、Slug、摘要、Tags。"
    )
  }

  func testAIMetadataApplicationRecordsBatchRollbackAndClear() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let titleSuggestion = AIPublishingMetadataSuggestion(
      titles: ["批量回滚标题"],
      summary: "批量回滚摘要"
    )
    let tagSuggestion = AIPublishingMetadataSuggestion(
      tags: ["AI", "批量回滚"]
    )

    let firstUpdate = try XCTUnwrap(store.applyAIMetadataSuggestion(titleSuggestion, draft: draft))
    let secondUpdate = try XCTUnwrap(store.applyAIMetadataSuggestion(tagSuggestion, draft: firstUpdate))
    let records = store.recentAIMetadataApplicationRecords(for: secondUpdate)

    XCTAssertEqual(records.count, 2)

    let result = store.rollbackAIMetadataApplicationRecords(records)

    XCTAssertEqual(result.requestedCount, 2)
    XCTAssertEqual(result.restoredCount, 2)
    XCTAssertEqual(result.skippedCount, 0)
    XCTAssertTrue(result.failures.isEmpty)
    let restored = try XCTUnwrap(store.selectedDraft)
    XCTAssertEqual(restored.title, draft.title)
    XCTAssertEqual(restored.summary, draft.summary)
    XCTAssertEqual(restored.tags, draft.tags)
    XCTAssertEqual(
      store.aiActionMessage,
      "AI 元数据批量回滚完成：恢复 2 条，跳过 0 条，失败 0 条。"
    )

    let repeatedResult = store.rollbackAIMetadataApplicationRecords(records)

    XCTAssertEqual(repeatedResult.restoredCount, 0)
    XCTAssertEqual(repeatedResult.skippedCount, 2)

    store.clearAIMetadataApplicationRecords(for: restored)

    XCTAssertTrue(store.recentAIMetadataApplicationRecords(for: restored).isEmpty)
    XCTAssertEqual(store.aiActionMessage, "已清空当前文章的 AI 应用记录。")
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func visiblePromptLibraryActions(
    _ snapshot: AIPublishingPromptLibrarySnapshot
  ) -> [AIPublishingActionKind] {
    snapshot.spotlightActionSections.flatMap(\.actions)
      + snapshot.editorActionSections.flatMap(\.actions)
  }
}
