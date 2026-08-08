import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIPublishingAssistantServiceTests: XCTestCase {
  func testRewritePromptUsesSelectedTextAndPublishingContext() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "AI Article",
      slug: "ai-article",
      tags: ["AI"],
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .rewriteSelection,
        draft: draft,
        profile: profile,
        selectedText: "selected text",
        preflightIssues: [
          PreflightIssue(severity: .warning, title: "正文偏短", message: "body short")
        ]
      )
    )

    XCTAssertTrue(prompt.contains("选中文本："))
    XCTAssertTrue(prompt.contains("selected text"))
    XCTAssertTrue(prompt.contains("发布检查："))
    XCTAssertTrue(prompt.contains("正文偏短"))
  }

  func testSelectionEditingActionsExposeStableDisplayNames() {
    XCTAssertEqual(AIPublishingActionKind.continueArticle.displayName, "续写正文")
    XCTAssertEqual(AIPublishingActionKind.draftOpening.displayName, "生成开头")
    XCTAssertEqual(AIPublishingActionKind.sharpenOpeningSelection.displayName, "优化开头段")
    XCTAssertEqual(AIPublishingActionKind.draftOpeningHooks.displayName, "生成开头钩子")
    XCTAssertEqual(AIPublishingActionKind.suggestArticleOutline.displayName, "生成大纲")
    XCTAssertEqual(AIPublishingActionKind.expandOutlineToDraft.displayName, "按大纲扩写")
    XCTAssertEqual(AIPublishingActionKind.draftArticleTLDR.displayName, "生成 TL;DR")
    XCTAssertEqual(AIPublishingActionKind.draftArticleFAQ.displayName, "生成 FAQ")
    XCTAssertEqual(AIPublishingActionKind.draftReaderQuestions.displayName, "生成读者问题")
    XCTAssertEqual(AIPublishingActionKind.draftTransitionSection.displayName, "生成过渡段")
    XCTAssertEqual(AIPublishingActionKind.draftExampleSection.displayName, "生成示例小节")
    XCTAssertEqual(AIPublishingActionKind.draftTutorialVersion.displayName, "改成教程版")
    XCTAssertEqual(AIPublishingActionKind.draftChecklistSection.displayName, "生成检查清单")
    XCTAssertEqual(AIPublishingActionKind.draftTroubleshootingSection.displayName, "生成故障排查")
    XCTAssertEqual(AIPublishingActionKind.draftCodeExample.displayName, "生成代码示例")
    XCTAssertEqual(AIPublishingActionKind.draftGlossary.displayName, "生成术语表")
    XCTAssertEqual(AIPublishingActionKind.draftReferencesSection.displayName, "生成参考资料清单")
    XCTAssertEqual(AIPublishingActionKind.draftInterviewQA.displayName, "生成访谈问答")
    XCTAssertEqual(AIPublishingActionKind.reorganizeStructure.displayName, "结构重排建议")
    XCTAssertEqual(AIPublishingActionKind.draftCounterpointSection.displayName, "生成反方观点")
    XCTAssertEqual(AIPublishingActionKind.draftCaseStudySection.displayName, "生成案例小节")
    XCTAssertEqual(AIPublishingActionKind.extractArticleKeyPoints.displayName, "提取要点")
    XCTAssertEqual(AIPublishingActionKind.extractArticleActionItems.displayName, "提取行动项")
    XCTAssertEqual(AIPublishingActionKind.polishSelection.displayName, "润色选中文本")
    XCTAssertEqual(AIPublishingActionKind.expandSelection.displayName, "扩写选中文本")
    XCTAssertEqual(AIPublishingActionKind.continueAfterSelection.displayName, "续写选区后文")
    XCTAssertEqual(AIPublishingActionKind.condenseSelection.displayName, "压缩选中文本")
    XCTAssertEqual(AIPublishingActionKind.removeRedundancySelection.displayName, "删减选区冗余")
    XCTAssertEqual(AIPublishingActionKind.checklistSelection.displayName, "选区转清单")
    XCTAssertEqual(AIPublishingActionKind.comparisonTableSelection.displayName, "选区转对比表")
    XCTAssertEqual(AIPublishingActionKind.explainSelection.displayName, "解释选中文本")
    XCTAssertEqual(AIPublishingActionKind.simplifySelection.displayName, "降低理解门槛")
    XCTAssertEqual(AIPublishingActionKind.summarizeSelection.displayName, "选区摘要")
    XCTAssertEqual(AIPublishingActionKind.translateSelectionToChinese.displayName, "选区翻译中文")
    XCTAssertEqual(AIPublishingActionKind.translateSelectionToEnglish.displayName, "选区翻译英文")
    XCTAssertEqual(AIPublishingActionKind.draftBilingualRewrite.displayName, "选区双语改写")
    XCTAssertEqual(AIPublishingActionKind.fixSelectionGrammar.displayName, "修正选区语法")
    XCTAssertEqual(AIPublishingActionKind.rewriteSelectionReaderFriendly.displayName, "读者友好改写")
    XCTAssertEqual(AIPublishingActionKind.rewriteSelectionFormal.displayName, "正式语气改写")
    XCTAssertEqual(AIPublishingActionKind.rewriteSelectionCasual.displayName, "轻松语气改写")
    XCTAssertEqual(AIPublishingActionKind.rewriteSelectionTechnical.displayName, "技术语气改写")
    XCTAssertEqual(AIPublishingActionKind.draftBilingualMetadata.displayName, "中英元数据候选")
    XCTAssertEqual(AIPublishingActionKind.suggestTitles.displayName, "标题建议")
    XCTAssertEqual(AIPublishingActionKind.suggestSlug.displayName, "Slug 建议")
    XCTAssertEqual(AIPublishingActionKind.suggestSummary.displayName, "摘要建议")
    XCTAssertEqual(AIPublishingActionKind.suggestTags.displayName, "Tags 建议")
    XCTAssertEqual(AIPublishingActionKind.draftFrontMatterPack.displayName, "Front Matter 套餐")
    XCTAssertEqual(AIPublishingActionKind.draftSourceChecklist.displayName, "来源补充清单")
    XCTAssertEqual(AIPublishingActionKind.flagUnsupportedClaims.displayName, "事实边界提醒")
    XCTAssertEqual(AIPublishingActionKind.auditLinkQuality.displayName, "链接质量检查")
    XCTAssertEqual(AIPublishingActionKind.auditImagePrivacy.displayName, "图片隐私检查")
    XCTAssertEqual(AIPublishingActionKind.reviewSSGCompatibility.displayName, "SSG 兼容检查")
    XCTAssertEqual(AIPublishingActionKind.reviewReaderClarity.displayName, "读者清晰度检查")
    XCTAssertEqual(AIPublishingActionKind.reviewTechnicalAccuracy.displayName, "技术准确性检查")
    XCTAssertEqual(AIPublishingActionKind.draftPullQuotes.displayName, "可引用摘录")
    XCTAssertEqual(AIPublishingActionKind.draftPublishNote.displayName, "发布说明")
    XCTAssertEqual(AIPublishingActionKind.draftNewsletterSummary.displayName, "Newsletter 摘要")
    XCTAssertEqual(AIPublishingActionKind.draftCrossPlatformAnnouncement.displayName, "跨平台发布摘要")
    XCTAssertEqual(AIPublishingActionKind.draftShortVideoScript.displayName, "短视频口播稿")
    XCTAssertEqual(AIPublishingActionKind.draftUpdateNote.displayName, "更新说明")
    XCTAssertEqual(AIPublishingActionKind.draftCommentReply.displayName, "评论回复草稿")
  }

  func testSelectionEditingPromptsStayScopedToSelectedMarkdown() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Actions",
      slug: "selection-actions",
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()
    let actions: [AIPublishingActionKind] = [
      .polishSelection,
      .expandSelection,
      .continueAfterSelection,
      .sharpenOpeningSelection,
      .condenseSelection,
      .removeRedundancySelection,
      .checklistSelection,
      .comparisonTableSelection,
      .explainSelection,
      .simplifySelection,
      .summarizeSelection,
      .translateSelectionToChinese,
      .translateSelectionToEnglish,
      .draftBilingualRewrite,
      .fixSelectionGrammar,
      .rewriteSelectionReaderFriendly,
      .rewriteSelectionFormal,
      .rewriteSelectionCasual,
      .rewriteSelectionTechnical,
    ]

    for action in actions {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile,
          selectedText: "selected **Markdown** with `code` and [link](https://example.com)"
        )
      )

      XCTAssertTrue(prompt.contains("选中文本："), action.rawValue)
      XCTAssertTrue(prompt.contains("selected **Markdown**"), action.rawValue)
      XCTAssertTrue(prompt.contains("Markdown"), action.rawValue)
      XCTAssertTrue(prompt.contains("不"), action.rawValue)
      XCTAssertTrue(prompt.contains("没有选中文本时"), action.rawValue)
    }
  }

  func testArticleDraftActionsUseCurrentArticleContextWithoutSelection() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Article Context",
      slug: "article-context",
      tags: ["publishing", "ai"],
      summary: "A focused publishing workflow.",
      bodyMarkdown: "The article explains a local-first publishing workflow."
    )
    let service = AIPublishingAssistantService()
    let actions: [AIPublishingActionKind] = [
      .continueArticle,
      .draftOpening,
      .draftOpeningHooks,
      .draftFullArticle,
      .suggestArticleOutline,
      .compareWritingAngles,
      .expandOutlineToDraft,
      .draftConclusion,
      .draftArticleTLDR,
      .draftArticleFAQ,
      .draftReaderQuestions,
      .draftTransitionSection,
      .draftExampleSection,
      .draftStepByStepGuide,
      .draftTutorialVersion,
      .draftChecklistSection,
      .draftTroubleshootingSection,
      .draftCodeExample,
      .draftMermaidDiagram,
      .draftGlossary,
      .draftReferencesSection,
      .draftInterviewQA,
      .reorganizeStructure,
      .draftCounterpointSection,
      .draftCaseStudySection,
      .extractArticleKeyPoints,
      .extractArticleActionItems,
    ]

    for action in actions {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile
        )
      )

      XCTAssertTrue(prompt.contains("当前文章："), action.rawValue)
      XCTAssertTrue(prompt.contains("Article Context"), action.rawValue)
      XCTAssertTrue(prompt.contains("A focused publishing workflow."), action.rawValue)
      XCTAssertTrue(prompt.contains("The article explains"), action.rawValue)
      XCTAssertTrue(prompt.contains("不要"), action.rawValue)
      XCTAssertFalse(prompt.contains("选中文本："), action.rawValue)
    }
  }

  func testMobileInspiredDraftSectionPromptsKeepEvidenceBoundaries() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Draft Section Actions",
      slug: "draft-section-actions",
      summary: "Evidence-aware AI drafting.",
      bodyMarkdown: "This article has enough context to draft bounded sections."
    )
    let service = AIPublishingAssistantService()
    let expectations: [(AIPublishingActionKind, String)] = [
      (.draftOpening, "阅读收益"),
      (.expandOutlineToDraft, "不要编造外部事实"),
      (.draftReaderQuestions, "## 读者可能会问"),
      (.draftTransitionSection, "过渡段"),
      (.draftExampleSection, "待补充"),
      (.draftTutorialVersion, "待确认"),
      (.draftChecklistSection, "- [ ]"),
      (.draftTroubleshootingSection, "待确认"),
      (.draftCodeExample, "不要编造可运行性"),
      (.draftGlossary, "术语表"),
      (.draftReferencesSection, "不要编造真实链接"),
      (.draftInterviewQA, "访谈式问答"),
      (.reorganizeStructure, "不要直接重写全文"),
      (.draftCounterpointSection, "不适用场景"),
      (.draftCaseStudySection, "假设场景"),
    ]

    for (action, requiredText) in expectations {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile
        )
      )

      XCTAssertTrue(prompt.contains(requiredText), action.rawValue)
      XCTAssertTrue(prompt.contains("Draft Section Actions"), action.rawValue)
      XCTAssertTrue(prompt.contains("编造"), action.rawValue)
    }
  }

  func testMobileSelectionExpansionPromptsStayScopedToSelection() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Expansions",
      slug: "selection-expansions",
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()
    let expectations: [(AIPublishingActionKind, String)] = [
      (.sharpenOpeningSelection, "优化"),
      (.draftBilingualRewrite, "中英文两个版本"),
      (.draftBilingualRewrite, "译法提醒"),
    ]

    for (action, requiredText) in expectations {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile,
          selectedText: "selected **Markdown** with `code` and [link](https://example.com)"
        )
      )

      XCTAssertTrue(prompt.contains("选中文本："), action.rawValue)
      XCTAssertTrue(prompt.contains("selected **Markdown**"), action.rawValue)
      XCTAssertTrue(prompt.contains(requiredText), action.rawValue)
      XCTAssertTrue(prompt.contains("没有选中文本时"), action.rawValue)
      XCTAssertTrue(prompt.contains("不"), action.rawValue)
    }
  }

  func testBilingualMetadataPromptReturnsCandidateReportOnly() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Bilingual Metadata",
      slug: "bilingual-metadata",
      tags: ["AI", "publishing"],
      summary: "A draft that needs bilingual publishing metadata.",
      bodyMarkdown: "The article explains how AI helps prepare metadata for a personal site."
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .draftBilingualMetadata,
        draft: draft,
        profile: profile
      )
    )

    XCTAssertTrue(prompt.contains("## 中英元数据候选"))
    XCTAssertTrue(prompt.contains("中文标题 3 个"))
    XCTAssertTrue(prompt.contains("英文摘要 2 条"))
    XCTAssertTrue(prompt.contains("社交描述"))
    XCTAssertTrue(prompt.contains("不要新增 front matter"))
    XCTAssertTrue(prompt.contains("不要直接改正文或元数据"))
    XCTAssertTrue(prompt.contains("Bilingual Metadata"))
  }

  func testMobileFrontMatterPromptsExposeGranularMetadataActions() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Granular Metadata",
      slug: "granular-metadata",
      tags: ["AI", "publishing"],
      summary: "A draft that needs precise metadata.",
      bodyMarkdown: "The article explains how mobile-style AI metadata helpers prepare a personal site post."
    )
    let service = AIPublishingAssistantService()
    let expectations: [(AIPublishingActionKind, String)] = [
      (.suggestTitles, "5 个标题候选"),
      (.suggestSlug, "kebab-case"),
      (.suggestSummary, "60 到 160"),
      (.suggestTags, "3 到 8"),
      (.draftFrontMatterPack, "## Front Matter 套餐"),
    ]

    for (action, requiredText) in expectations {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile
        )
      )

      XCTAssertTrue(prompt.contains(requiredText), action.rawValue)
      XCTAssertTrue(prompt.contains("Granular Metadata"), action.rawValue)
      XCTAssertTrue(prompt.contains("当前文章："), action.rawValue)
      XCTAssertTrue(prompt.contains("front matter"), action.rawValue)
      XCTAssertTrue(prompt.contains("不"), action.rawValue)
    }
  }

  func testMobilePublishingReviewPromptsDoNotInventExternalProof() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Publishing Review Actions",
      slug: "publishing-review-actions",
      summary: "Review AI actions for publication.",
      bodyMarkdown: "This article mentions a link, a static site generator, and a technical claim."
    )
    let service = AIPublishingAssistantService()
    let expectations: [(AIPublishingActionKind, String)] = [
      (.draftSourceChecklist, "不要编造真实链接"),
      (.flagUnsupportedClaims, "不要联网查证"),
      (.auditLinkQuality, "不要声称已经访问外部网页"),
      (.auditImagePrivacy, "不要假装看到了图片真实画面"),
      (.reviewSSGCompatibility, "Hexo、Hugo、Zola、Astro、Jekyll"),
      (.reviewReaderClarity, "读者可能卡住的位置"),
      (.reviewTechnicalAccuracy, "不要假装运行过代码"),
      (.draftPullQuotes, "不要制造更强结论"),
      (.draftPublishNote, "commit message"),
      (.draftNewsletterSummary, "不要编造用户反馈"),
      (.draftCrossPlatformAnnouncement, "RSS 摘要"),
      (.draftShortVideoScript, "15 秒"),
      (.draftUpdateNote, "不要编造版本号"),
      (.draftCommentReply, "## 评论回复草稿"),
    ]

    for (action, requiredText) in expectations {
      let prompt = service.prompt(
        for: AIPublishingActionRequest(
          kind: action,
          draft: draft,
          profile: profile
        )
      )

      XCTAssertTrue(prompt.contains(requiredText), action.rawValue)
      XCTAssertTrue(prompt.contains("Publishing Review Actions"), action.rawValue)
      XCTAssertTrue(prompt.contains("当前文章："), action.rawValue)
    }
  }

  func testContinueAfterSelectionPromptReturnsInsertionOnly() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Actions",
      slug: "selection-actions",
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .continueAfterSelection,
        draft: draft,
        profile: profile,
        selectedText: "selected **Markdown**"
      )
    )

    XCTAssertTrue(prompt.contains("插入到选区后面"))
    XCTAssertTrue(prompt.contains("不重复选中文本"))
    XCTAssertTrue(prompt.contains("selected **Markdown**"))
  }

  func testExplainSelectionPromptReturnsInsertionOnly() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Actions",
      slug: "selection-actions",
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .explainSelection,
        draft: draft,
        profile: profile,
        selectedText: "selected **Markdown**"
      )
    )

    XCTAssertTrue(prompt.contains("插入到选区后面"))
    XCTAssertTrue(prompt.contains("不重复选中文本"))
    XCTAssertTrue(prompt.contains("selected **Markdown**"))
  }

  func testComparisonTablePromptDoesNotInventMissingCells() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Actions",
      slug: "selection-actions",
      bodyMarkdown: "Original body"
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .comparisonTableSelection,
        draft: draft,
        profile: profile,
        selectedText: "A is faster. B is cheaper."
      )
    )

    XCTAssertTrue(prompt.contains("Markdown 对比表"))
    XCTAssertTrue(prompt.contains("待确认"))
    XCTAssertTrue(prompt.contains("不编造事实"))
  }

  func testPromptIncludesMacPublishingWorkflowContext() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "AI Context",
      slug: "ai-context",
      bodyMarkdown: "Body long enough for a publishing assistant context test."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: [
        PublishFileDiff(path: "content/posts/ai-context.md", kind: .markdown, status: .modified),
        PublishFileDiff(path: "static/images/cover.jpg", kind: .image, status: .added),
      ],
      issues: [
        PreflightIssue(severity: .warning, title: "本地分支落后远端", message: "先拉取远端")
      ]
    )
    let previewPlan = LocalSitePreviewPlan(
      siteKind: .zola,
      rootPath: "/tmp/site",
      executablePath: "/usr/bin/env",
      arguments: ["zola", "serve", "--drafts"],
      command: "cd \"/tmp/site\" && zola serve --drafts",
      previewURL: URL(string: "http://127.0.0.1:1111")!,
      notes: ["包含草稿预览参数 --drafts。"]
    )
    let imageReport = ImageWorkbenchReport(
      draftID: draft.id,
      items: [
        ImageWorkbenchItem(
          attachmentID: UUID(),
          originalFilename: "cover.jpg",
          relativePublishPath: "/images/2026/cover.jpg",
          repositoryPath: "static/images/2026/cover.jpg",
          sourceFilePath: "/tmp/cover.jpg",
          byteSize: 1200,
          dimensions: ImageDimensions(width: 1200, height: 630),
          fileExists: true,
          isCover: true,
          isReferencedInMarkdown: true,
          missingAltText: false,
          missingCaption: true,
          canOptimizeJPEG: true
        )
      ],
      coverStatus: ImageCoverPublishStatus(
        state: .ready,
        frontMatterFieldPath: "extra.og_preview_img",
        originalFilename: "cover.jpg",
        relativePublishPath: "/images/2026/cover.jpg",
        repositoryPath: "static/images/2026/cover.jpg",
        sourceFilePath: "/tmp/cover.jpg",
        fileExists: true
      ),
      issues: [
        ImageWorkbenchIssue(severity: .info, title: "缺少 caption", message: "cover.jpg 还没有图片说明。")
      ]
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .pullRequestDescription,
        draft: draft,
        profile: profile,
        publishPackage: package,
        workflowContext: AIPublishingWorkflowContext(
          publishPreview: preview,
          localSitePreviewPlan: previewPlan,
          imageReport: imageReport
        )
      )
    )

    XCTAssertTrue(prompt.contains("Mac 发布上下文："))
    XCTAssertTrue(prompt.contains("本地 diff：2 个待写入变化。"))
    XCTAssertTrue(prompt.contains("Markdown 修改：content/posts/ai-context.md"))
    XCTAssertTrue(prompt.contains("本地预览：Zola http://127.0.0.1:1111"))
    XCTAssertTrue(prompt.contains("命令：cd \"/tmp/site\" && zola serve --drafts"))
    XCTAssertTrue(prompt.contains("图片检查：1 张图片，缺 alt 0，源图缺失 0，可压缩 JPEG 1。"))
    XCTAssertTrue(prompt.contains("封面：封面可发布"))
    XCTAssertTrue(prompt.contains("Front Matter：extra.og_preview_img"))
    XCTAssertTrue(prompt.contains("Diff 问题："))
  }

  func testTitleSummaryPromptCanUseSelectedText() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection Summary",
      slug: "selection-summary",
      bodyMarkdown: "Full body should not be the only source."
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .titleSummaryTags,
        draft: draft,
        profile: profile,
        selectedText: "Selected section for summary."
      )
    )

    XCTAssertTrue(prompt.contains("选中的 Markdown 文本"))
    XCTAssertTrue(prompt.contains("Selected section for summary."))
  }

  func testPublishingReadinessPromptUsesMacWorkbenchContext() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Readiness",
      slug: "readiness",
      tags: ["Mac", "Publish"],
      summary: "Prepare a post with local publish context.",
      bodyMarkdown: "# Readiness\n\nA body that should be included as a short excerpt."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: [
        PublishFileDiff(path: "content/posts/readiness.md", kind: .markdown, status: .added)
      ],
      issues: []
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .publishingReadiness,
        draft: draft,
        profile: profile,
        preflightIssues: [
          PreflightIssue(severity: .warning, title: "摘要偏短", message: "建议补充摘要。")
        ],
        publishPackage: package,
        workflowContext: AIPublishingWorkflowContext(publishPreview: preview)
      )
    )

    XCTAssertTrue(prompt.contains("发布准备建议"))
    XCTAssertTrue(prompt.contains("发布前最需要处理的三件事"))
    XCTAssertTrue(prompt.contains("图片/封面与公开风险注意项"))
    XCTAssertTrue(prompt.contains("Mac 发布上下文："))
    XCTAssertTrue(prompt.contains("本地 diff：1 个待写入变化。"))
    XCTAssertTrue(prompt.contains("摘要偏短"))
    XCTAssertTrue(prompt.contains("# Readiness"))
  }

  func testPromptIncludesProfileAIWritingStyle() {
    var profile = SiteProfile.defaultProfile
    profile.resolvedAIWritingStyle = AIWritingStyleConfig(preset: .technicalNote)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Style Context",
      slug: "style-context",
      bodyMarkdown: "正文需要按照技术笔记风格输出。"
    )
    let service = AIPublishingAssistantService()

    let prompt = service.prompt(
      for: AIPublishingActionRequest(
        kind: .titleSummaryTags,
        draft: draft,
        profile: profile
      )
    )

    XCTAssertTrue(prompt.contains("AI 写作风格："))
    XCTAssertTrue(prompt.contains("准确、结构清晰"))
    XCTAssertTrue(prompt.contains("需要复现步骤、判断取舍或理解实现细节的技术读者"))
    XCTAssertTrue(prompt.contains("优先使用技术栈、问题域和具体工具名"))
  }

  func testPublishingReadinessUsesHighQualityTaskModel() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "gpt-4.1",
        "choices": [
          {
            "message": {"role":"assistant","content":"发布前审稿完成。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Publish Review",
      slug: "publish-review",
      bodyMarkdown: "用于发布前审稿的正文。"
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: false
    )

    let result = try await service.perform(
      AIPublishingActionRequest(kind: .publishingReadiness, draft: draft, profile: profile),
      config: config,
      apiKey: nil
    )

    XCTAssertEqual(result.content, "发布前审稿完成。")
    XCTAssertEqual(result.providerName, "自定义")
    XCTAssertEqual(result.model, "gpt-4.1")
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "gpt-4.1-mini")
  }

  func testRequiresAPIKeyForRemoteProvider() async {
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(
        transport: RecordingAIChatTransport(data: Data(), statusCode: 200)
      )
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Title", slug: "title")

    await XCTAssertThrowsErrorAsync(
      try await service.perform(
        AIPublishingActionRequest(kind: .privacyReview, draft: draft, profile: profile),
        config: profile.aiProviderConfig,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIPublishingAssistantError, .missingAPIKey)
    }
  }

  func testChatReplyIncludesCurrentArticleContextAndConversationHistory() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "local-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"可以，把摘要先压缩到 80 字以内。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Mac AI Chat",
      slug: "mac-ai-chat",
      tags: ["AI", "Mac"],
      summary: "Use AI to discuss the current article.",
      bodyMarkdown: "# Mac AI Chat\n\n正文需要更像发布说明。"
    )
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-test",
      requiresAPIKey: false
    )

    let result = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "帮我看摘要是否太长")
        ],
        preflightIssues: [
          PreflightIssue(severity: .warning, title: "摘要偏长", message: "建议压缩。")
        ],
        publishPackage: PublishPackageBuilder().build(draft: draft, profile: profile),
        relatedSuggestions: [
          SiteRelationSuggestion(
            sourceDraftID: draft.id,
            sourceTitle: draft.title,
            targetDraftID: UUID(),
            targetTitle: "iOS AI Chat",
            targetPath: "posts/ios-ai-chat.md",
            sharedLabels: ["AI", "发布"],
            reason: "同属 AI 写作工作流，可作为站内延伸阅读。"
          )
        ]
      ),
      config: config,
      apiKey: nil
    )

    XCTAssertEqual(result.role, AIPublishingChatRole.assistant)
    XCTAssertTrue(result.content.contains("摘要"))
    XCTAssertEqual(result.model, "local-test")
    XCTAssertEqual(result.contextMode, .site)

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let messages = try XCTUnwrap(payload?["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("文章讨论助手"))
    XCTAssertTrue(sentText.contains("不得展示思考、推理、权衡、草稿或内部决策过程"))
    XCTAssertTrue(sentText.contains("当前 Mac 工作台上下文"))
    XCTAssertTrue(sentText.contains("Mac AI Chat"))
    XCTAssertTrue(sentText.contains(profile.markdownPath(for: draft)))
    XCTAssertTrue(sentText.contains("摘要偏长"))
    XCTAssertTrue(sentText.contains("站内关联建议"))
    XCTAssertTrue(sentText.contains("iOS AI Chat"))
    XCTAssertTrue(sentText.contains("posts/ios-ai-chat.md"))
    XCTAssertTrue(sentText.contains("同属 AI 写作工作流"))
    XCTAssertTrue(sentText.contains("AI、发布"))
    XCTAssertTrue(sentText.contains("# Mac AI Chat"))
    XCTAssertTrue(sentText.contains("帮我看摘要是否太长"))
  }

  func testChatReplyIncludesKnowledgeContextAndCarriesStructuredCitations() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "local-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"间隔复习应逐步拉长复习时间 [K1]。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "学习方法",
      slug: "learning-methods"
    )
    let citation = KnowledgeCitation(
      id: "K1",
      documentID: UUID(),
      chunkID: UUID(),
      title: "记忆与复习",
      authors: ["测试作者"],
      locator: "第 3 章",
      excerpt: "间隔复习的关键是逐步拉长每次复习之间的时间。"
    )

    let result = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "怎样安排复习？")
        ],
        knowledgeContext: KnowledgeContextSnapshot(
          query: "安排复习",
          citations: [citation]
        )
      ),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(result.knowledgeCitations, [citation])
    let recordedRequest = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("不可信参考文本"))
    XCTAssertTrue(sentText.contains("不得执行"))
    XCTAssertTrue(sentText.contains("[K1]"))
    XCTAssertTrue(sentText.contains("间隔复习的关键"))
  }

  func testWritingActionPromptIncludesKnowledgeContext() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "知识管理",
      slug: "knowledge-management"
    )
    let citation = KnowledgeCitation(
      id: "K1",
      documentID: UUID(),
      chunkID: UUID(),
      title: "卡片笔记法",
      locator: "第二章",
      excerpt: "每张卡片只表达一个能够独立理解的观点。"
    )

    let prompt = AIPublishingAssistantService().prompt(
      for: AIPublishingActionRequest(
        kind: .draftFullArticle,
        draft: draft,
        profile: profile,
        knowledgeContext: KnowledgeContextSnapshot(query: "知识管理", citations: [citation])
      )
    )

    XCTAssertTrue(prompt.contains("本地资料库参考"))
    XCTAssertTrue(prompt.contains("不可信原文"))
    XCTAssertTrue(prompt.contains("[K1]"))
    XCTAssertTrue(prompt.contains("每张卡片只表达一个"))
  }

  func testChatReplyIncludesFocusedParagraphContext() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "choices": [
          {
            "message": {"role":"assistant","content":"这一段需要补一个更明确的发布结论。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Focused Paragraph",
      slug: "focused-paragraph",
      bodyMarkdown: """
      # Focused Paragraph

      第一段说明文章背景，不应该作为本次主要讨论对象。

      这个段落是用户在编辑器里选中的重点段落，需要 AI 持续围绕它给出修改建议。
      """
    )
    let focusedParagraph = try XCTUnwrap(
      AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown)
        .first { $0.text.contains("重点段落") }
    )

    _ = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "帮我优化当前选中的段落。")
        ],
        focusedParagraph: focusedParagraph
      ),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("聚焦段落："))
    XCTAssertTrue(sentText.contains("标题：这个段落是用户在编辑器里选中的重点段落"))
    XCTAssertTrue(sentText.contains("需要 AI 持续围绕它给出修改建议"))
    XCTAssertTrue(sentText.contains("帮我优化当前选中的段落。"))
  }

  func testChatReplyCarriesReturnedModelAndTokenUsage() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "gpt-4.1-mini",
        "choices": [
          {
            "message": {"role":"assistant","content":"建议先补充发布风险。"}
          }
        ],
        "usage": {
          "prompt_tokens": 140,
          "completion_tokens": 18,
          "total_tokens": 158
        }
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Token Metadata",
      slug: "token-metadata",
      bodyMarkdown: "正文用于测试 AI 回复元数据。"
    )

    let result = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "帮我看发布风险")
        ]
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(result.model, "gpt-4.1-mini")
    XCTAssertEqual(
      result.tokenUsage,
      AIChatTokenUsage(promptTokens: 140, completionTokens: 18, totalTokens: 158)
    )
  }

  func testChatReplyUsesRequestedModelGrade() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "gpt-4.1",
        "choices": [
          {
            "message": {"role":"assistant","content":"高质量模型已用于文章讨论。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Chat Grade",
      slug: "chat-grade",
      bodyMarkdown: "正文用于测试聊天模型等级。"
    )

    _ = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "用更高质量模型检查这段。")
        ],
        modelGrade: .highQuality
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "gpt-4.1-mini")
  }

  func testChatReplyUsesSelectedReasoningLevel() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "choices": [
          {
            "message": {"role":"assistant","content":"已使用标准思考。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Chat Reasoning",
      slug: "chat-reasoning",
      bodyMarkdown: "正文用于测试聊天思考级别。"
    )

    _ = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [AIPublishingChatMessage(role: .user, content: "请简要检查。")],
        reasoningLevel: .standard
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertNil(payload["reasoning_effort"])
  }

  func testChatReplyUsesSelectedCustomModel() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "choices": [
          {
            "message": {"role":"assistant","content":"自定义模型已用于文章讨论。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Custom Chat Model",
      slug: "custom-chat-model",
      bodyMarkdown: "正文用于测试自定义聊天模型。"
    )

    let result = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "用自定义模型检查这段。")
        ],
        modelGrade: .custom,
        selectedModel: "  sitekeeper-custom-chat-model  "
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(result.model, "sitekeeper-custom-chat-model")
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "sitekeeper-custom-chat-model")
  }

  func testChatStreamReplyUsesSelectedModelAndPublishesDeltas() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"流式"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"回复。"},"finish_reason":"stop"}],"#
          + #""usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#,
        "",
      ]
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Streaming Chat",
      slug: "streaming-chat",
      bodyMarkdown: "正文用于测试流式聊天模型。"
    )

    let replyStream = try await service.streamReply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "用流式回复检查这段。")
        ],
        modelGrade: .custom,
        selectedModel: "stream-chat-model"
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(replyStream.initialMessage.role, .assistant)
    XCTAssertEqual(replyStream.initialMessage.content, "")
    XCTAssertEqual(replyStream.initialMessage.model, "stream-chat-model")

    var streamedContent = ""
    var finalUsage: AIChatTokenUsage?
    for try await update in replyStream.updates {
      streamedContent += update.contentDelta
      finalUsage = update.tokenUsage ?? finalUsage
      if update.isFinished {
        break
      }
    }

    XCTAssertEqual(streamedContent, "流式回复。")
    XCTAssertEqual(finalUsage?.totalTokens, 14)
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "stream-chat-model")
    XCTAssertEqual(payload["stream"] as? Bool, true)
  }

  func testGeneralChatReplyOmitsCurrentArticleAndPublishingContext() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "local-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"可以，下面是一个通用回答。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Private Article Context",
      slug: "private-article-context",
      summary: "这段摘要不应该进入通用聊天。",
      bodyMarkdown: "这篇文章正文不应该进入通用聊天上下文。"
    )

    let result = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "帮我解释一个通用 Swift 问题。")
        ],
        contextMode: .general,
        preflightIssues: [
          PreflightIssue(severity: .warning, title: "私有发布问题", message: "不应发送。")
        ],
        publishPackage: PublishPackageBuilder().build(draft: draft, profile: profile),
        relatedSuggestions: [
          SiteRelationSuggestion(
            sourceDraftID: draft.id,
            sourceTitle: draft.title,
            targetDraftID: UUID(),
            targetTitle: "Private Related Article",
            targetPath: "posts/private-related.md",
            sharedLabels: ["private"],
            reason: "通用聊天不应发送这条站内建议。"
          )
        ]
      ),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    XCTAssertEqual(result.role, .assistant)
    XCTAssertEqual(result.contextMode, .general)

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("通用 AI 对话助手"))
    XCTAssertTrue(sentText.contains("不得展示思考、推理、权衡、草稿或内部决策过程"))
    XCTAssertTrue(sentText.contains("帮我解释一个通用 Swift 问题。"))
    XCTAssertFalse(sentText.contains("当前 Mac 工作台上下文"))
    XCTAssertFalse(sentText.contains("Private Article Context"))
    XCTAssertFalse(sentText.contains("这篇文章正文不应该进入通用聊天上下文"))
    XCTAssertFalse(sentText.contains("私有发布问题"))
    XCTAssertFalse(sentText.contains("站内关联建议"))
    XCTAssertFalse(sentText.contains("Private Related Article"))
    XCTAssertFalse(sentText.contains("posts/private-related.md"))
  }

  func testGenericChatStreamUsesContextEnvelopeAndPublishesDeltas() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"通用"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"回复"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let explicitReference = AIContextReference(
      kind: .knowledgeEntry,
      resourceID: UUID().uuidString,
      displayName: "用户选择的资料",
      characterCount: 8
    )
    let replyStream = try await service.streamReply(
      to: AIChatRequest(
        messages: [
          AIPublishingChatMessage(role: .user, content: "回答一个开放问题")
        ],
        context: AIContextAssembler.generalEnvelope(
          explicitContextReferences: [explicitReference],
          explicitContextPrompt: "<explicit_knowledge_entry>明确资料</explicit_knowledge_entry>"
        )
      ),
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    var content = ""
    for try await update in replyStream.updates {
      content += update.contentDelta
      if update.isFinished { break }
    }

    XCTAssertEqual(content, "通用回复")
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    XCTAssertTrue(sentText.contains("明确资料"))
    XCTAssertFalse(sentText.contains("当前 Mac 工作台上下文"))
  }

  func testChatReplySendsUserImageAttachmentsAsContentParts() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "vision-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"这张图可以作为封面，但需要补 alt。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "AI Image Context",
      slug: "ai-image-context",
      bodyMarkdown: "正文。"
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "vision-test",
      requiresAPIKey: false
    )
    let attachment = AIChatImageAttachment(
      filename: "cover.png",
      mimeType: "image/png",
      data: Data("image-bytes".utf8)
    )

    _ = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(
            role: .user,
            content: "帮我检查这张封面图。",
            imageAttachments: [attachment]
          )
        ],
        publishPackage: PublishPackageBuilder().build(draft: draft, profile: profile)
      ),
      config: config,
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(messages.last)
    let parts = try XCTUnwrap(userMessage["content"] as? [[String: Any]])

    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0]["type"] as? String, "text")
    XCTAssertEqual(parts[0]["text"] as? String, "帮我检查这张封面图。")
    XCTAssertEqual(parts[1]["type"] as? String, "image_url")
    let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
    XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,aW1hZ2UtYnl0ZXM=")
  }

  func testChatReplyAllowsImageOnlyUserMessage() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "vision-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"我看到了这张图片。"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Image Only", slug: "image-only")
    let attachment = AIChatImageAttachment(
      filename: "diagram.png",
      mimeType: "image/png",
      data: Data("image-only".utf8)
    )

    _ = try await service.reply(
      to: AIPublishingChatRequest(
        draft: draft,
        profile: profile,
        messages: [
          AIPublishingChatMessage(role: .user, content: "", imageAttachments: [attachment])
        ]
      ),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "vision-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(messages.last)
    let parts = try XCTUnwrap(userMessage["content"] as? [[String: Any]])

    XCTAssertEqual(parts.count, 1)
    XCTAssertEqual(parts[0]["type"] as? String, "image_url")
    let imageURL = try XCTUnwrap(parts[0]["image_url"] as? [String: Any])
    XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,aW1hZ2Utb25seQ==")
  }



  func testChatMessageDecodesLegacyRecordsWithoutImageAttachments() throws {
    let message = AIPublishingChatMessage(
      role: .user,
      content: "帮我检查标题"
    )
    let encoded = try JSONEncoder.workbench.encode(message)
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "imageAttachments")
    let legacyData = try JSONSerialization.data(withJSONObject: payload)

    let decoded = try JSONDecoder.workbench.decode(AIPublishingChatMessage.self, from: legacyData)

    XCTAssertEqual(decoded.id, message.id)
    XCTAssertEqual(decoded.role, .user)
    XCTAssertEqual(decoded.content, "帮我检查标题")
    XCTAssertEqual(decoded.contextMode, .site)
    XCTAssertTrue(decoded.imageAttachments.isEmpty)
  }

  func testChatReplyRejectsEmptyUserMessage() async {
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(
        transport: RecordingAIChatTransport(data: Data(), statusCode: 200)
      )
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Title", slug: "title")

    await XCTAssertThrowsErrorAsync(
      try await service.reply(
        to: AIPublishingChatRequest(
          draft: draft,
          profile: profile,
          messages: [
            AIPublishingChatMessage(role: .user, content: "   ")
          ]
        ),
        config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "local", requiresAPIKey: false),
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIPublishingAssistantError, .emptyChatMessage)
    }
  }

  func testMetadataSuggestionParsesStructuredResponseAndIncludesContext() async throws {
    let responseContent = """
    TITLE:
    - Mac AI 发布助手
    - 用 AI 检查个人网站文章

    SLUG:
    - mac-ai-publishing-assistant
    - personal-site-ai-review

    SUMMARY:
    用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认。

    TAGS:
    - Mac
    - AI
    - Publishing
    """
    let responsePayload: [String: Any] = [
      "model": "local-test",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": responseContent,
          ],
        ],
      ],
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: responsePayload),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Mac AI",
      slug: "mac-ai",
      tags: ["Tool"],
      summary: "Old summary",
      bodyMarkdown: "# Mac AI\n\n这篇文章介绍 Mac 版 AI 发布助手。"
    )
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-test",
      requiresAPIKey: false
    )

    let suggestion = try await service.suggestMetadata(
      for: AIPublishingActionRequest(
        kind: .titleSummaryTags,
        draft: draft,
        profile: profile,
        preflightIssues: [
          PreflightIssue(severity: .warning, title: "缺少封面", message: "建议补封面。")
        ],
        publishPackage: PublishPackageBuilder().build(draft: draft, profile: profile)
      ),
      config: config,
      apiKey: nil
    )

    XCTAssertEqual(suggestion.titles, ["Mac AI 发布助手", "用 AI 检查个人网站文章"])
    XCTAssertEqual(suggestion.slugs, ["mac-ai-publishing-assistant", "personal-site-ai-review"])
    XCTAssertEqual(suggestion.summary, "用 Mac 版发布控制台生成可落地的标题、路径、摘要和标签建议，发布前仍由作者确认")
    XCTAssertEqual(suggestion.tags, ["Mac", "AI", "Publishing"])

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let messages = try XCTUnwrap(payload?["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("front matter 编辑助手"))
    XCTAssertTrue(sentText.contains("TITLE:"))
    XCTAssertTrue(sentText.contains("SLUG:"))
    XCTAssertTrue(sentText.contains("Mac AI"))
    XCTAssertTrue(sentText.contains(profile.markdownPath(for: draft)))
    XCTAssertTrue(sentText.contains("缺少封面"))
  }

  func testMetadataSuggestionThrowsWhenResponseHasNoApplicableFields() async {
    let responsePayload: [String: Any] = [
      "model": "local-test",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": "没有足够信息。",
          ],
        ],
      ],
    ]
    let responseData = try! JSONSerialization.data(withJSONObject: responsePayload)
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(
        transport: RecordingAIChatTransport(data: responseData, statusCode: 200)
      )
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Title", slug: "title")

    await XCTAssertThrowsErrorAsync(
      try await service.suggestMetadata(
        for: AIPublishingActionRequest(kind: .titleSummaryTags, draft: draft, profile: profile),
        config: AIProviderConfig(preset: .local, baseURL: "http://127.0.0.1:11434/v1", model: "local", requiresAPIKey: false),
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? AIPublishingAssistantError, .emptyMetadataSuggestion)
    }
  }

  func testImageTextSuggestionParsesJSONAndIncludesImageContext() async throws {
    let attachmentID = UUID()
    let draftID = UUID()
    let target = AIPublishingImageTextTarget(
      id: attachmentID.uuidString,
      draftID: draftID,
      attachmentID: attachmentID,
      draftTitle: "图片发布",
      markdownPath: "content/posts/image-publishing.md",
      articleSummary: "介绍图片发布工作流。",
      articleExcerpt: "正文里有一张流程截图。",
      filename: "workflow.png",
      imagePath: "/images/2026/workflow.png",
      existingAlt: "",
      existingCaption: "",
      isCover: false,
      isReferencedInMarkdown: true
    )
    let responsePayload: [String: Any] = [
      "model": "local-test",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": """
            {"items":[{"id":"\(attachmentID.uuidString)","alt_text":"用于说明图片发布工作流的截图","caption":"图片工作台检查发布前图片字段。","reason":"结合文章摘要和文件路径生成。"}]}
            """,
          ],
        ],
      ],
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: responsePayload),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-test",
      requiresAPIKey: false
    )

    let suggestions = try await service.suggestImageText(
      for: [target],
      profile: SiteProfile.defaultProfile,
      config: config,
      apiKey: nil
    )

    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions[0].attachmentID, attachmentID)
    XCTAssertEqual(suggestions[0].altText, "用于说明图片发布工作流的截图")
    XCTAssertEqual(suggestions[0].caption, "图片工作台检查发布前图片字段。")

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let messages = try XCTUnwrap(payload?["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")

    XCTAssertTrue(sentText.contains("图片无障碍和 SEO 编辑助手"))
    XCTAssertTrue(sentText.contains("workflow.png"))
    XCTAssertTrue(sentText.contains("/images/2026/workflow.png"))
    XCTAssertTrue(sentText.contains("content/posts/image-publishing.md"))
    XCTAssertTrue(sentText.contains(attachmentID.uuidString))
  }

  func testImageTextSuggestionSendsSelectedImageAsVisionContent() async throws {
    let attachmentID = UUID()
    let target = AIPublishingImageTextTarget(
      id: attachmentID.uuidString,
      draftID: UUID(),
      attachmentID: attachmentID,
      draftTitle: "施工记录",
      markdownPath: "content/posts/site-log.md",
      articleSummary: "记录现场施工过程。",
      articleExcerpt: "图片展示现场安全检查。",
      filename: "safety-check.png",
      imagePath: "/images/safety-check.png",
      existingAlt: "",
      existingCaption: "",
      isCover: false,
      isReferencedInMarkdown: true
    )
    let responsePayload: [String: Any] = [
      "model": "local-test",
      "choices": [[
        "message": [
          "role": "assistant",
          "content": """
          {"items":[{"id":"\(attachmentID.uuidString)","alt":"施工现场安全检查记录","caption":"","reason":"根据实际画面生成。"}]}
          """,
        ]
      ]],
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: responsePayload),
      statusCode: 200
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let image = AIChatImageAttachment(
      filename: "safety-check.png",
      mimeType: "image/png",
      data: Data([0x89, 0x50, 0x4E, 0x47])
    )

    _ = try await service.suggestImageText(
      for: [target],
      visionInputs: [
        AIPublishingImageTextVisionInput(
          targetID: target.id,
          attachment: image
        )
      ],
      profile: .defaultProfile,
      config: AIProviderConfig(
        preset: .local,
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-test",
        requiresAPIKey: false
      ),
      apiKey: nil
    )

    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(messages.last)
    let content = try XCTUnwrap(userMessage["content"] as? [[String: Any]])

    XCTAssertTrue(content.contains {
      ($0["type"] as? String) == "text"
        && ($0["text"] as? String)?.contains(target.id) == true
    })
    XCTAssertTrue(content.contains {
      guard ($0["type"] as? String) == "image_url",
            let imageURL = $0["image_url"] as? [String: Any],
            let url = imageURL["url"] as? String else {
        return false
      }
      return url.hasPrefix("data:image/png;base64,")
    })
  }

  func testConvergedAssetPackPromptUsesOnlySelectedAssets() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Converged publishing",
      slug: "converged-publishing",
      bodyMarkdown: "本文介绍发布流程。"
    )
    let convergence = AIPublishingActionConvergence.publishAssetPack(
      AIPublishingAssetPackConfiguration(assets: [.socialShare, .newsletterSummary])
    )
    let prompt = AIPublishingAssistantService().prompt(
      for: AIPublishingActionRequest(
        kind: convergence.canonicalActionKind,
        draft: draft,
        profile: profile,
        convergence: convergence
      )
    )

    XCTAssertTrue(prompt.contains("社交分享"))
    XCTAssertTrue(prompt.contains("Newsletter 摘要"))
    XCTAssertFalse(prompt.contains("封面图提示词"))
    XCTAssertFalse(prompt.contains("短视频口播稿"))
  }

  func testConvergedRewritePromptCarriesOperationAndFiveStyleParameter() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Converged rewrite",
      slug: "converged-rewrite",
      bodyMarkdown: "原始正文。"
    )
    let convergence = AIPublishingActionConvergence.rewriteSelection(
      AIPublishingRewriteConfiguration(operation: .condense, style: .technical)
    )
    let prompt = AIPublishingAssistantService().prompt(
      for: AIPublishingActionRequest(
        kind: convergence.canonicalActionKind,
        draft: draft,
        profile: profile,
        convergence: convergence,
        selectedText: "需要压缩的选区。"
      )
    )

    XCTAssertTrue(prompt.contains("压缩"))
    XCTAssertTrue(prompt.contains("技术"))
    XCTAssertTrue(prompt.contains("需要压缩的选区。"))
    XCTAssertTrue(prompt.contains("保留代码、链接和 Markdown 结构"))
  }

  func testConvergedReviewPromptUsesSelectedChecks() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Converged review",
      slug: "converged-review",
      bodyMarkdown: "文章包含一个链接和技术说明。"
    )
    let convergence = AIPublishingActionConvergence.contentReview(
      AIPublishingReviewConfiguration(checks: [.privacy, .technicalAccuracy])
    )
    let prompt = AIPublishingAssistantService().prompt(
      for: AIPublishingActionRequest(
        kind: convergence.canonicalActionKind,
        draft: draft,
        profile: profile,
        convergence: convergence
      )
    )

    XCTAssertTrue(prompt.contains("公开隐私"))
    XCTAssertTrue(prompt.contains("技术准确性"))
    XCTAssertFalse(prompt.contains("SEO 与可读性"))
    XCTAssertFalse(prompt.contains("SSG 兼容"))
  }
}
