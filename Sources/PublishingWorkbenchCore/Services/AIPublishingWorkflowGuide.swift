import Foundation

public struct AIPublishingWorkflowGuide: Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var description: String
  public var systemImage: String
  public var prompts: [AIPublishingQuickPrompt]

  public init(
    id: String,
    title: String,
    description: String,
    systemImage: String,
    prompts: [AIPublishingQuickPrompt]
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.systemImage = systemImage
    self.prompts = prompts
  }

  public var actionPreview: String {
    prompts
      .prefix(4)
      .map(\.displayName)
      .joined(separator: " · ")
  }

  public static let featuredGuides: [AIPublishingWorkflowGuide] = [
    AIPublishingWorkflowGuide(
      id: "idea-to-draft",
      title: "从想法到初稿",
      description: "先比较角度，再生成大纲、正文结构和 TL;DR。",
      systemImage: "lightbulb",
      prompts: [.angleCompare, .outline, .continueWriting, .tldr]
    ),
    AIPublishingWorkflowGuide(
      id: "draft-to-finished-article",
      title: "初稿补完成稿",
      description: "补开头、过渡、结尾和 FAQ，让草稿更完整。",
      systemImage: "doc.text.magnifyingglass",
      prompts: [.titleIdeas, .continueWriting, .faq, .readerQuestions, .tldr]
    ),
    AIPublishingWorkflowGuide(
      id: "complete-article-workbench",
      title: "完整成稿工作台",
      description: "从角度、大纲、正文补料到结尾，一次整理成完整写作路径。",
      systemImage: "square.and.pencil",
      prompts: [.angleCompare, .outline, .continueWriting, .stepGuide, .checklist, .tldr]
    ),
    AIPublishingWorkflowGuide(
      id: "technical-explainer-kit",
      title: "技术文章增强",
      description: "补步骤、图示、术语解释和事实边界，适合工程笔记。",
      systemImage: "hammer",
      prompts: [.stepGuide, .mermaid, .glossary, .factBoundary, .readerReview]
    ),
    AIPublishingWorkflowGuide(
      id: "draft-evidence-kit",
      title: "正文补料工具",
      description: "补示例、步骤、代码和 Mermaid 图示，让文章更可操作。",
      systemImage: "list.bullet.clipboard",
      prompts: [.stepGuide, .checklist, .mermaid, .glossary, .readerReview]
    ),
    AIPublishingWorkflowGuide(
      id: "structure-upgrade",
      title: "结构升级",
      description: "把大纲扩成正文，补结构建议、反方观点和案例分析。",
      systemImage: "arrow.up.arrow.down.square",
      prompts: [.outline, .structurePlan, .counterpoint, .caseStudy, .readerQuestions]
    ),
    AIPublishingWorkflowGuide(
      id: "evidence-backed-draft",
      title: "证据驱动写作",
      description: "找内容缺口、事实边界和来源需求，再补写可确认的正文结构。",
      systemImage: "exclamationmark.magnifyingglass",
      prompts: [.contentGap, .factBoundary, .sourceChecklist, .outline, .readerReview]
    ),
    AIPublishingWorkflowGuide(
      id: "selection-rewrite",
      title: "选区润色改写",
      description: "对当前段落做语气、语法、翻译和读者友好改写。",
      systemImage: "text.magnifyingglass",
      prompts: [.tone, .grammar, .translateChinese, .translateEnglish, .localizationDraft]
    ),
    AIPublishingWorkflowGuide(
      id: "selection-to-structure",
      title: "选区整理成结构",
      description: "把选区整理成摘要、清单、结构建议和读者追问。",
      systemImage: "list.bullet.rectangle",
      prompts: [.tone, .tldr, .checklist, .structurePlan, .readerQuestions]
    ),
    AIPublishingWorkflowGuide(
      id: "front-matter-pack",
      title: "标题与 Front Matter",
      description: "生成标题、摘要、双语元数据和稳定发布字段候选。",
      systemImage: "rectangle.and.pencil.and.ellipsis",
      prompts: [.titleIdeas, .frontMatterPack, .bilingualMetadata, .tagIdeas]
    ),
    AIPublishingWorkflowGuide(
      id: "front-matter-details",
      title: "路径与摘要细化",
      description: "补稳定 slug、列表摘要和标签细节，适合发布前收尾。",
      systemImage: "number",
      prompts: [.slugIdeas, .summary, .tagIdeas]
    ),
    AIPublishingWorkflowGuide(
      id: "bilingual-publish-metadata",
      title: "双语发布元数据",
      description: "生成中英文标题、摘要、标签和社交描述，适合双语站点发布前审阅。",
      systemImage: "character.bubble",
      prompts: [.bilingualMetadata, .titleIdeas, .summary, .tagIdeas, .slugIdeas]
    ),
    AIPublishingWorkflowGuide(
      id: "bilingual-release-kit",
      title: "双语发布套件",
      description: "把正文、元数据和分发摘要串成双语发布前检查流程。",
      systemImage: "character.book.closed",
      prompts: [.bilingualMetadata, .localizationDraft, .translateChinese, .translateEnglish, .crossPlatformAnnouncement]
    ),
    AIPublishingWorkflowGuide(
      id: "publish-readiness",
      title: "发布前 AI 审稿",
      description: "集中检查发布阻塞、隐私、SEO、内链、图片和 SSG 风险。",
      systemImage: "checkmark.shield",
      prompts: [.publishReview, .privacyCheck, .seo, .internalLinks, .imagePrivacy, .ssgChecklist]
    ),
    AIPublishingWorkflowGuide(
      id: "evidence-and-reader-review",
      title: "事实与读者校对",
      description: "标出缺口、事实边界、来源清单和读者理解风险。",
      systemImage: "person.text.rectangle",
      prompts: [.contentGap, .factBoundary, .sourceChecklist, .readerReview]
    ),
    AIPublishingWorkflowGuide(
      id: "seo-link-image-audit",
      title: "SEO、链接与图片体检",
      description: "检查 SEO 可读性、链接质量和图片隐私风险。",
      systemImage: "chart.line.text.clipboard",
      prompts: [.seo, .linkAudit, .imagePrivacy]
    ),
    AIPublishingWorkflowGuide(
      id: "link-image-publish-pack",
      title: "链接图片发布包",
      description: "集中处理内链、外链、图片隐私、alt/caption 和发布素材。",
      systemImage: "link.badge.plus",
      prompts: [.internalLinks, .linkAudit, .imagePrivacy, .imageCaptions, .publishAssetPack]
    ),
    AIPublishingWorkflowGuide(
      id: "image-publishing-assistant",
      title: "图片发布助手",
      description: "处理图片 alt/caption、隐私风险、封面提示词和发布素材。",
      systemImage: "photo.on.rectangle.angled",
      prompts: [.imageCaptions, .imagePrivacy, .coverPrompt, .publishAssetPack]
    ),
    AIPublishingWorkflowGuide(
      id: "publish-recovery-assistant",
      title: "发布失败恢复助手",
      description: "把发布失败上下文整理成排查顺序、保护本地草稿的修复计划和复发预防。",
      systemImage: "wrench.and.screwdriver",
      prompts: [.publishRecoveryPlan, .publishReview, .ssgChecklist, .factBoundary, .sourceChecklist]
    ),
    AIPublishingWorkflowGuide(
      id: "distribution-pack",
      title: "发布素材生成",
      description: "生成图片文案、发布素材包、社交分享和封面提示词。",
      systemImage: "megaphone",
      prompts: [.imageCaptions, .publishAssetPack, .socialShare, .coverPrompt]
    ),
    AIPublishingWorkflowGuide(
      id: "multi-channel-distribution",
      title: "多渠道分发",
      description: "生成摘录卡片、发布说明、Newsletter 摘要和跨平台发布摘要。",
      systemImage: "rectangle.3.group.bubble",
      prompts: [.pullQuotes, .publishNote, .releaseSummary, .crossPlatformAnnouncement, .shortVideoScript]
    ),
    AIPublishingWorkflowGuide(
      id: "site-maintenance-assistant",
      title: "站点内容维护助手",
      description: "串起旧文升级、系列规划、内容缺口、内链建议和更新说明。",
      systemImage: "wrench.and.screwdriver",
      prompts: [.oldArticleRefresh, .seriesPlan, .contentGap, .internalLinks, .updateNote]
    ),
    AIPublishingWorkflowGuide(
      id: "refresh-and-series-plan",
      title: "旧文与系列维护",
      description: "规划系列文章、旧文更新、更新说明和评论回复。",
      systemImage: "clock.arrow.2.circlepath",
      prompts: [.seriesPlan, .oldArticleRefresh, .updateNote, .commentReply]
    ),
  ]
}
