import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatPromptTemplateServiceTests: XCTestCase {
  func testQuotedMessagePromptIncludesImageAttachmentNamesForImageOnlyMessage() {
    let message = AIPublishingChatMessage(
      role: .user,
      content: " \n ",
      imageAttachments: [
        AIChatImageAttachment(filename: "diagram.png", mimeType: "image/png", data: Data("image".utf8))
      ]
    )

    let prompt = AIPublishingChatPromptTemplateService.quotedMessagePrompt(for: message)

    XCTAssertTrue(prompt.contains("请基于下面这条用户消息继续讨论："))
    XCTAssertTrue(prompt.contains("> 已附加图片：diagram.png"))
  }

  func testArticleContextPromptBuildsExplicitCurrentArticleReference() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Mac AI Context",
      slug: "mac-ai-context",
      tags: ["AI", "Mac"],
      categories: ["Publishing"],
      summary: "Explain the Mac AI workspace context.",
      bodyMarkdown: "First paragraph.\n\nSecond paragraph with details."
    )

    let prompt = AIPublishingChatPromptTemplateService.articleContextPrompt(
      for: draft,
      profile: profile,
      maxBodyLength: 18
    )

    XCTAssertTrue(prompt.contains("[当前文章]"))
    XCTAssertTrue(prompt.contains("标题：Mac AI Context"))
    XCTAssertTrue(prompt.contains("Slug：mac-ai-context"))
    XCTAssertTrue(prompt.contains("Tags：AI, Mac"))
    XCTAssertTrue(prompt.contains("Categories：Publishing"))
    XCTAssertTrue(prompt.contains(profile.markdownPath(for: draft)))
    XCTAssertTrue(prompt.contains("First paragraph."))
    XCTAssertTrue(prompt.contains("...（已截断）"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
  }

  func testMaintenanceActionPromptBuildsActionableWorkbenchContext() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "旧文维护",
      slug: "old-maintenance",
      tags: ["维护"],
      categories: ["内容治理"],
      bodyMarkdown: "正文里有 [缺失链接](/missing-page/) 和 TODO。"
    )
    let item = MaintenanceActionItem(
      id: "link-old-maintenance",
      kind: .linkAudit,
      priority: .high,
      title: "修复链接：旧文维护",
      summary: "发现缺失内链。",
      detail: "目标 /missing-page/ 在当前站点不存在。",
      draftID: draft.id,
      targetPath: "/missing-page/",
      systemImage: "link.badge.plus"
    )

    let prompt = AIPublishingChatPromptTemplateService.maintenanceActionPrompt(
      for: item,
      draft: draft,
      profile: profile,
      maxBodyLength: 18
    )

    XCTAssertTrue(prompt.contains("[维护行动项]"))
    XCTAssertTrue(prompt.contains("类型：链接审计"))
    XCTAssertTrue(prompt.contains("优先级：高"))
    XCTAssertTrue(prompt.contains("修复链接：旧文维护"))
    XCTAssertTrue(prompt.contains("目标路径：/missing-page/"))
    XCTAssertTrue(prompt.contains("# 维护任务：修复链接：旧文维护"))
    XCTAssertTrue(prompt.contains("正文里有"))
    XCTAssertTrue(prompt.contains("...（已截断）"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
    XCTAssertTrue(prompt.contains("复查清单"))
  }

  func testReleaseRecoveryPromptBuildsRetryRollbackDecisionContext() {
    let profile = SiteProfile.defaultProfile
    let draftID = UUID()
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上提交失败：恢复测试",
      summary: "远端 commit 已写入，但部署检查离线。",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: draftID,
      draftTitle: "恢复测试",
      markdownPath: "content/posts/recovery-test.md",
      changedPaths: ["content/posts/recovery-test.md"],
      repositoryProvider: .github,
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    let deployment = DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: record.id,
      provider: .githubPages,
      level: .unknown,
      title: "GitHub Pages · 未知",
      message: "Actions API 暂时不可达。",
      siteURLText: "https://example.com",
      signals: [
        DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub API 未检查",
          message: "缺少状态响应。",
          urlText: "https://github.com/owner/site/actions"
        )
      ]
    )
    let entry = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [record.id: deployment]
    ).entries[0]
    let draft = ArticleDraft(
      id: draftID,
      siteProfileID: profile.id,
      title: "恢复测试",
      slug: "recovery-test",
      bodyMarkdown: "正文需要确认是否继续发布或回滚。"
    )

    let prompt = AIPublishingChatPromptTemplateService.releaseRecoveryPrompt(
      for: entry,
      package: entry.recoveryPackage,
      draft: draft,
      profile: profile,
      maxBodyLength: 12
    )

    XCTAssertTrue(prompt.contains("[发布记录]"))
    XCTAssertTrue(prompt.contains("状态：远端待确认"))
    XCTAssertTrue(prompt.contains("线上提交失败：恢复测试"))
    XCTAssertTrue(prompt.contains("Commit：abcdef12"))
    XCTAssertTrue(prompt.contains("https://github.com/owner/site/actions"))
    XCTAssertTrue(prompt.contains("content/posts/recovery-test.md"))
    XCTAssertTrue(prompt.contains("[恢复包原文]"))
    XCTAssertTrue(prompt.contains("...（已截断）"))
    XCTAssertTrue(prompt.contains("不要声称已经执行命令"))
    XCTAssertTrue(prompt.contains("可复制的处理清单"))
  }

  func testSEOSocialPreviewPromptBuildsMetadataAndSocialCardContext() {
    let profile = SiteProfile.defaultProfile
    let draftID = UUID()
    let targetID = UUID()
    let draft = ArticleDraft(
      id: draftID,
      siteProfileID: profile.id,
      title: "SEO 社交预览",
      slug: "seo-social-preview",
      tags: ["SEO", "Mac"],
      categories: ["个人网站"],
      summary: "这篇文章验证 SEO 社交预览可以交给 AI 继续优化。",
      bodyMarkdown: "# SEO 社交预览\n\n正文需要补充 Open Graph、Twitter/X 和关联文章建议。"
    )
    let snapshot = SEOSocialPreviewSnapshot(
      draftID: draftID,
      signature: "seo-signature",
      markdownPath: "content/posts/seo-social-preview.md",
      canonicalURLText: "https://example.com/seo-social-preview/",
      titleCharacterCount: 8,
      descriptionCharacterCount: 24,
      imagePath: "/images/seo-social.png",
      imageAltText: "SEO social card",
      shareHashtags: ["SEO", "Mac"],
      cards: [
        SEOSocialPreviewCard(
          kind: .openGraph,
          title: "SEO 社交预览",
          description: "Open Graph 摘要。",
          urlText: "https://example.com/seo-social-preview/",
          imagePath: "/images/seo-social.png",
          imageAltText: "SEO social card",
          siteName: profile.name
        ),
        SEOSocialPreviewCard(
          kind: .twitter,
          title: "SEO 社交预览",
          description: "Twitter 摘要。",
          urlText: "https://example.com/seo-social-preview/",
          imagePath: "/images/seo-social.png",
          imageAltText: "SEO social card",
          siteName: profile.name
        ),
      ],
      metaTags: [
        SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:title", content: "SEO 社交预览"),
        SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:card", content: "summary_large_image"),
      ],
      findings: [
        SEOAuditFinding(severity: .warning, title: "描述偏短", message: "摘要可以更具体。", field: "summary"),
      ]
    )
    let suggestion = SiteRelationSuggestion(
      sourceDraftID: draftID,
      sourceTitle: "SEO 社交预览",
      targetDraftID: targetID,
      targetTitle: "Mac SEO 内链",
      targetPath: "/mac-seo-links/",
      sharedLabels: ["SEO"],
      reason: "共享 SEO 标签，适合补充内链。"
    )

    let prompt = AIPublishingChatPromptTemplateService.seoSocialPreviewPrompt(
      snapshot: snapshot,
      draft: draft,
      profile: profile,
      relatedSuggestions: [suggestion],
      maxBodyLength: 18
    )

    XCTAssertTrue(prompt.contains("[平台就绪度]"))
    XCTAssertTrue(prompt.contains("[卡片预览]"))
    XCTAssertTrue(prompt.contains("Open Graph"))
    XCTAssertTrue(prompt.contains("Twitter/X"))
    XCTAssertTrue(prompt.contains("og:title"))
    XCTAssertTrue(prompt.contains("Hashtags：#SEO #Mac"))
    XCTAssertTrue(prompt.contains("SEO 社交预览 -> Mac SEO 内链"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
    XCTAssertTrue(prompt.contains("外部调试链接"))
    XCTAssertTrue(prompt.contains("...（已截断）"))
  }

  func testParagraphContextPromptBuildsFocusedArticleInstruction() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "段落上下文",
      slug: "paragraph-context",
      bodyMarkdown: "第一段正文很长。\n\n第二段正文更长。"
    )
    let paragraph = try XCTUnwrap(
      AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown).first
    )

    let prompt = AIPublishingChatPromptTemplateService.paragraphContextPrompt(
      for: paragraph,
      draft: draft,
      profile: profile,
      maxParagraphLength: 5
    )

    XCTAssertTrue(prompt.contains("[当前文章段落]"))
    XCTAssertTrue(prompt.contains("文章：段落上下文"))
    XCTAssertTrue(prompt.contains(profile.markdownPath(for: draft)))
    XCTAssertTrue(prompt.contains("段落：第一段正文很长。"))
    XCTAssertTrue(prompt.contains("第一段正文...（已截断）"))
    XCTAssertTrue(prompt.contains("不要默认改写整篇文章"))
  }

  func testWorkflowGuidePromptBuildsRunnableInstruction() {
    let guide = AIPublishingWorkflowGuide(
      id: "test-workflow",
      title: "发布前 AI 审稿",
      description: "集中检查发布阻塞、隐私和内链风险。",
      systemImage: "checkmark.shield",
      prompts: [.publishReview, .privacyCheck, .internalLinks]
    )

    let prompt = AIPublishingChatPromptTemplateService.workflowGuidePrompt(for: guide)

    XCTAssertTrue(prompt.contains("执行“发布前 AI 审稿”AI 工作流"))
    XCTAssertTrue(prompt.contains("目标：集中检查发布阻塞、隐私和内链风险。"))
    XCTAssertTrue(prompt.contains("1. 发布检查："))
    XCTAssertTrue(prompt.contains("2. 隐私检查："))
    XCTAssertTrue(prompt.contains("3. 内链建议："))
    XCTAssertTrue(prompt.contains("Front Matter"))
    XCTAssertTrue(prompt.contains("图片字段"))
    XCTAssertTrue(prompt.contains("发布素材"))
    XCTAssertTrue(prompt.contains("不要编造正文没有提供的事实"))
  }

  func testRelatedArticleSuggestionPromptBuildsInternalLinkInstruction() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Mac 发布工作流",
      slug: "mac-publishing",
      tags: ["Mac", "AI"],
      bodyMarkdown: "正文"
    )
    let suggestion = SiteRelationSuggestion(
      sourceDraftID: draft.id,
      sourceTitle: "Mac 发布工作流",
      targetDraftID: UUID(),
      targetTitle: "SEO 社交预览",
      targetPath: "/seo-social-preview/",
      sharedLabels: ["AI", "SEO"],
      reason: "共享 AI、SEO，正文还没有链接到目标文章。"
    )

    let prompt = AIPublishingChatPromptTemplateService.relatedArticleSuggestionPrompt(
      for: suggestion,
      draft: draft,
      profile: profile
    )

    XCTAssertTrue(prompt.contains("[建议关联文章]"))
    XCTAssertTrue(prompt.contains("标题：Mac 发布工作流"))
    XCTAssertTrue(prompt.contains("目标标题：SEO 社交预览"))
    XCTAssertTrue(prompt.contains("目标路径：/seo-social-preview/"))
    XCTAssertTrue(prompt.contains("共享标签/分类：AI、SEO"))
    XCTAssertTrue(prompt.contains("必须包含指向 /seo-social-preview/ 的链接"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
  }

  func testGeneralDraftReusePlanPromptBuildsCrossSiteRewriteInstruction() {
    var profile = SiteProfile.defaultProfile
    profile.name = "目标站点"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "跨站点复用副本",
      slug: "cross-site-copy",
      tags: ["工程"],
      summary: "目标站点摘要",
      bodyMarkdown: "正文包含旧站点上下文和 TODO，需要按目标站点改写。"
    )
    let plan = GeneralDraftReusePlan(
      sourceDraftID: UUID(),
      targetDraftID: draft.id,
      title: "跨站点复用副本",
      sourceProfileName: "通用库",
      targetProfileName: "目标站点",
      targetMarkdownPath: "content/posts/cross-site-copy.md",
      sourceRepositoryPath: "content/posts/original.md",
      targetSiteKind: .zola,
      attachmentCount: 2,
      missingAltTextCount: 1,
      missingCaptionCount: 1,
      riskLevel: .high,
      riskItems: ["正文包含旧站点上下文", "存在 TODO"],
      checklistItems: ["重查 front matter", "确认内链和图片路径"],
      generatedAt: Date(timeIntervalSince1970: 1_783_396_800)
    )

    let prompt = AIPublishingChatPromptTemplateService.generalDraftReusePlanPrompt(
      for: plan,
      draft: draft,
      profile: profile
    )

    XCTAssertTrue(prompt.contains("[目标草稿]"))
    XCTAssertTrue(prompt.contains("标题：跨站点复用副本"))
    XCTAssertTrue(prompt.contains("建议发布路径：content/posts/cross-site-copy.md"))
    XCTAssertTrue(prompt.contains("来源 Profile：通用库"))
    XCTAssertTrue(prompt.contains("原发布路径：content/posts/original.md"))
    XCTAssertTrue(prompt.contains("附件待补：alt 1 个，caption 1 个"))
    XCTAssertTrue(prompt.contains("- 正文包含旧站点上下文"))
    XCTAssertTrue(prompt.contains("- 重查 front matter"))
    XCTAssertTrue(prompt.contains("正文包含旧站点上下文和 TODO"))
    XCTAssertTrue(prompt.contains("输出建议的 Front Matter 调整"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
  }

  func testFeaturedWorkflowGuidesCoverPublishingAndMaintenancePaths() {
    let guides = AIPublishingWorkflowGuide.featuredGuides
    let guideIDs = guides.map(\.id)
    let uniqueGuideIDs = Set(guideIDs)

    XCTAssertEqual(guideIDs.count, uniqueGuideIDs.count)
    XCTAssertFalse(guides.isEmpty)
    XCTAssertTrue(guides.allSatisfy { !$0.title.isEmpty })
    XCTAssertTrue(guides.allSatisfy { !$0.description.isEmpty })
    XCTAssertTrue(guides.allSatisfy { !$0.prompts.isEmpty })

    let publishReadiness = try? XCTUnwrap(guides.first { $0.id == "publish-readiness" })
    XCTAssertEqual(
      publishReadiness?.prompts,
      [.publishReview, .privacyCheck, .seo, .internalLinks, .imagePrivacy, .ssgChecklist]
    )

    let expectedGuideIDs: Set<String> = [
      "idea-to-draft",
      "draft-to-finished-article",
      "complete-article-workbench",
      "technical-explainer-kit",
      "draft-evidence-kit",
      "structure-upgrade",
      "evidence-backed-draft",
      "selection-rewrite",
      "selection-to-structure",
      "front-matter-pack",
      "front-matter-details",
      "bilingual-publish-metadata",
      "bilingual-release-kit",
      "publish-readiness",
      "evidence-and-reader-review",
      "seo-link-image-audit",
      "link-image-publish-pack",
      "image-publishing-assistant",
      "publish-recovery-assistant",
      "distribution-pack",
      "multi-channel-distribution",
      "site-maintenance-assistant",
      "refresh-and-series-plan",
    ]
    XCTAssertTrue(Set(guideIDs).isSuperset(of: expectedGuideIDs))

    let frontMatterDetails = try? XCTUnwrap(guides.first { $0.id == "front-matter-details" })
    XCTAssertEqual(frontMatterDetails?.prompts, [.slugIdeas, .summary, .tagIdeas])

    let selectionRewrite = try? XCTUnwrap(guides.first { $0.id == "selection-rewrite" })
    XCTAssertEqual(
      selectionRewrite?.prompts,
      [.tone, .grammar, .translateChinese, .translateEnglish, .localizationDraft]
    )

    let selectionStructure = try? XCTUnwrap(guides.first { $0.id == "selection-to-structure" })
    XCTAssertEqual(selectionStructure?.prompts, [.tone, .tldr, .checklist, .structurePlan, .readerQuestions])

    let bilingualRelease = try? XCTUnwrap(guides.first { $0.id == "bilingual-release-kit" })
    XCTAssertEqual(
      bilingualRelease?.prompts,
      [.bilingualMetadata, .localizationDraft, .translateChinese, .translateEnglish, .crossPlatformAnnouncement]
    )

    let evidenceReview = try? XCTUnwrap(guides.first { $0.id == "evidence-and-reader-review" })
    XCTAssertEqual(evidenceReview?.prompts, [.contentGap, .factBoundary, .sourceChecklist, .readerReview])

    let multiChannel = try? XCTUnwrap(guides.first { $0.id == "multi-channel-distribution" })
    XCTAssertEqual(
      multiChannel?.prompts,
      [.pullQuotes, .publishNote, .releaseSummary, .crossPlatformAnnouncement, .shortVideoScript]
    )

    let maintenance = try? XCTUnwrap(guides.first { $0.id == "site-maintenance-assistant" })
    XCTAssertEqual(
      maintenance?.prompts,
      [.oldArticleRefresh, .seriesPlan, .contentGap, .internalLinks, .updateNote]
    )

    let refreshSeries = try? XCTUnwrap(guides.first { $0.id == "refresh-and-series-plan" })
    XCTAssertEqual(refreshSeries?.prompts, [.seriesPlan, .oldArticleRefresh, .updateNote, .commentReply])
  }

  func testPromptLibrarySnapshotFiltersPromptsByScopeAndSearch() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "图片"
    )

    XCTAssertTrue(snapshot.workflowGuides.contains { $0.id == "image-publishing-assistant" })
    XCTAssertEqual(snapshot.promptSections.map(\.group), [.distribution])
    XCTAssertTrue(snapshot.promptSections.flatMap(\.prompts).contains(.imageCaptions))
    XCTAssertFalse(snapshot.promptSections.flatMap(\.prompts).contains(.publishReview))
  }

  func testPromptLibrarySnapshotFindsCoverPromptByDisplayName() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "封面"
    )

    XCTAssertTrue(snapshot.workflowGuides.contains { $0.id == "image-publishing-assistant" })
    XCTAssertTrue(snapshot.promptSections.flatMap(\.prompts).contains(.coverPrompt))
  }

  func testPromptLibrarySnapshotMatchesRawPromptIdentifiers() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "publishRecoveryPlan"
    )

    XCTAssertEqual(snapshot.workflowGuides.map(\.id), ["publish-recovery-assistant"])
    XCTAssertEqual(snapshot.promptSections.flatMap(\.prompts), [.publishRecoveryPlan])
  }

  func testPromptLibrarySnapshotFindsMobileInspiredWorkflowGuides() {
    let frontMatterSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "路径与摘要细化"
    )
    XCTAssertEqual(frontMatterSnapshot.workflowGuides.map(\.id), ["front-matter-details"])

    let distributionSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "多渠道分发"
    )
    XCTAssertEqual(distributionSnapshot.workflowGuides.map(\.id), ["multi-channel-distribution"])

    let maintenanceSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .maintenance,
      searchText: "评论回复"
    )
    XCTAssertEqual(maintenanceSnapshot.workflowGuides.map(\.id), ["refresh-and-series-plan"])
    XCTAssertTrue(maintenanceSnapshot.promptSections.flatMap(\.prompts).contains(.commentReply))

    let slugPromptSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .writing,
      searchText: "slugIdeas"
    )
    XCTAssertEqual(slugPromptSnapshot.promptSections.flatMap(\.prompts), [.slugIdeas])

    let shortVideoPromptSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "短视频口播稿"
    )
    XCTAssertEqual(shortVideoPromptSnapshot.promptSections.flatMap(\.prompts), [.shortVideoScript])

    let selectionRewriteSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .editing,
      searchText: "选区润色改写"
    )
    XCTAssertEqual(selectionRewriteSnapshot.workflowGuides.map(\.id), ["selection-rewrite"])
  }

  func testPromptLibrarySnapshotIncludesEditorActionsByScopeAndSearch() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .editing,
      searchText: "选区"
    )

    XCTAssertEqual(snapshot.editorActionSections.map(\.group), [.editing])
    XCTAssertTrue(snapshot.spotlightActionSections.flatMap(\.actions).contains(.rewriteSelection))
    XCTAssertTrue(snapshot.editorActionSections.flatMap(\.actions).contains(.comparisonTableSelection))
    XCTAssertFalse(snapshot.editorActionSections.flatMap(\.actions).contains(.publishingReadiness))
  }

  func testPromptLibrarySnapshotBuildsMobileStyleSpotlightActions() {
    let distributionSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: ""
    )

    XCTAssertEqual(distributionSnapshot.spotlightActionSections.map(\.group), [.distribution])
    XCTAssertEqual(
      Array(distributionSnapshot.spotlightActionSections.flatMap(\.actions).prefix(4)),
      [.draftImageAltCaptions, .draftSocialShare, .draftPublishAssetPack, .draftPullQuotes]
    )
    XCTAssertFalse(
      distributionSnapshot.editorActionSections.flatMap(\.actions).contains(.draftImageAltCaptions)
    )

    let searchSnapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .distribution,
      searchText: "短视频"
    )

    XCTAssertEqual(searchSnapshot.spotlightActionSections.flatMap(\.actions), [.draftShortVideoScript])
    XCTAssertFalse(searchSnapshot.editorActionSections.flatMap(\.actions).contains(.draftShortVideoScript))
  }

  func testCapabilityCenterSnapshotExposesFeaturedAndAllEditorActions() {
    let featured = AIPublishingCapabilityCenterService.snapshot(mode: .featured)
    let all = AIPublishingCapabilityCenterService.snapshot(mode: .all)

    XCTAssertEqual(
      Set(featured.promptSections.flatMap(\.prompts)),
      Set(AIPublishingQuickPrompt.primaryPrompts)
    )
    XCTAssertEqual(
      Set(featured.editorActionSections.flatMap(\.actions)),
      Set(AIPublishingDefaultCapability.defaultActionKinds)
    )
    XCTAssertTrue(featured.editorActionSections.flatMap(\.actions).contains(.continueArticle))
    XCTAssertTrue(featured.editorActionSections.flatMap(\.actions).contains(.rewriteSelection))
    XCTAssertTrue(featured.editorActionSections.flatMap(\.actions).contains(.publishingReadiness))
    XCTAssertFalse(featured.editorActionSections.flatMap(\.actions).contains(.draftFullArticle))

    XCTAssertEqual(
      Set(all.promptSections.flatMap(\.prompts)),
      Set(AIPublishingQuickPrompt.allCases)
    )
    XCTAssertEqual(
      Set(all.editorActionSections.flatMap(\.actions)),
      Set(AIPublishingActionKind.promptLibraryActions)
    )
    XCTAssertGreaterThan(
      all.editorActionSections.flatMap(\.actions).count,
      featured.editorActionSections.flatMap(\.actions).count
    )
    XCTAssertEqual(all.editorActionSections.map(\.group), AIPublishingQuickPromptGroup.allCases)
  }

  func testPromptLibrarySpotlightActionsSkipVisibleRecommendations() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Mac AI 发布助手",
      bodyMarkdown: "正文已经存在，推荐区会优先展示续写、摘要、标题和发布检查。"
    )

    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "",
      draft: draft
    )
    let spotlightActions = snapshot.spotlightActionSections.flatMap(\.actions)

    XCTAssertTrue(snapshot.recommendation?.actions.contains(.continueArticle) == true)
    XCTAssertFalse(spotlightActions.contains(.continueArticle))
    XCTAssertFalse(spotlightActions.contains(.publishingReadiness))
    XCTAssertFalse(snapshot.editorActionSections.flatMap(\.actions).contains(.continueArticle))
  }

  func testPromptLibrarySnapshotMatchesRawEditorActionIdentifiers() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .all,
      searchText: "pullRequestDescription"
    )

    XCTAssertTrue(snapshot.promptSections.isEmpty)
    XCTAssertEqual(snapshot.editorActionSections.flatMap(\.actions), [.pullRequestDescription])
  }

  func testPromptLibrarySnapshotReportsEmptySearchResults() {
    let snapshot = AIPublishingPromptLibraryService.snapshot(
      selectedScope: .maintenance,
      searchText: "definitely-not-a-prompt"
    )

    XCTAssertFalse(snapshot.hasVisibleContent)
    XCTAssertTrue(snapshot.workflowGuides.isEmpty)
    XCTAssertTrue(snapshot.promptSections.isEmpty)
  }

  func testEditorActionPromptBuildsChatInstruction() {
    let prompt = AIPublishingChatPromptTemplateService.editorActionPrompt(for: .rewriteSelection)

    XCTAssertTrue(prompt.contains("围绕“改写选中文本”继续作为 AI 发布助手协作"))
    XCTAssertTrue(prompt.contains("场景：改写当前选区"))
    XCTAssertTrue(prompt.contains("请先要求我选中正文"))
    XCTAssertTrue(prompt.contains("正文、Front Matter、图片字段还是发布素材"))
    XCTAssertTrue(prompt.contains("不要声称已经修改文章"))
  }

  func testQuotedAssistantMessagePromptBuildsFollowUpInstruction() {
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "  第一行建议\n第二行建议  "
    )

    let prompt = AIPublishingChatPromptTemplateService.quotedMessagePrompt(for: message)

    XCTAssertTrue(prompt.contains("AI 回复"))
    XCTAssertTrue(prompt.contains("> 第一行建议"))
    XCTAssertTrue(prompt.contains("> 第二行建议"))
    XCTAssertTrue(prompt.contains("可应用到文章的 Markdown"))
  }

  func testQuotedUserMessagePromptTrimsAndTruncatesLongContent() {
    let message = AIPublishingChatMessage(role: .user, content: "  abcdef  ")

    let prompt = AIPublishingChatPromptTemplateService.quotedMessagePrompt(
      for: message,
      maxContentLength: 3
    )

    XCTAssertTrue(prompt.contains("用户消息"))
    XCTAssertTrue(prompt.contains("> abc...（已截断）"))
    XCTAssertFalse(prompt.contains("def"))
  }

  func testQuotedMessagePromptReturnsEmptyForEmptyContent() {
    let message = AIPublishingChatMessage(role: .assistant, content: " \n ")

    let prompt = AIPublishingChatPromptTemplateService.quotedMessagePrompt(for: message)

    XCTAssertEqual(prompt, "")
  }
}
