import Foundation

public enum AIPublishingQuickPromptGroup: String, CaseIterable, Identifiable, Sendable {
  case writing
  case editing
  case publishing
  case distribution
  case maintenance

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .writing:
      return "写作生成"
    case .editing:
      return "选区编辑"
    case .publishing:
      return "发布检查"
    case .distribution:
      return "分发素材"
    case .maintenance:
      return "内容维护"
    }
  }

  public var detail: String {
    switch self {
    case .writing:
      return "从主题、草稿或选区生成后续正文、提纲和章节。"
    case .editing:
      return "对段落做润色、翻译、语气、语法和结构整理。"
    case .publishing:
      return "检查发布风险、SEO、隐私、链接和 SSG 兼容性。"
    case .distribution:
      return "生成分享文案、封面提示词、Newsletter 和发布摘要。"
    case .maintenance:
      return "规划系列文章、旧文更新、更新说明和读者回复。"
    }
  }

  public var systemImage: String {
    switch self {
    case .writing:
      return "square.and.pencil"
    case .editing:
      return "text.magnifyingglass"
    case .publishing:
      return "checkmark.shield"
    case .distribution:
      return "megaphone"
    case .maintenance:
      return "wrench.and.screwdriver"
    }
  }
}

public struct AIPublishingQuickPromptSection: Equatable, Identifiable, Sendable {
  public var group: AIPublishingQuickPromptGroup
  public var prompts: [AIPublishingQuickPrompt]

  public var id: AIPublishingQuickPromptGroup.ID {
    group.id
  }

  public init(
    group: AIPublishingQuickPromptGroup,
    prompts: [AIPublishingQuickPrompt]
  ) {
    self.group = group
    self.prompts = prompts
  }
}

public enum AIPublishingQuickPrompt: String, CaseIterable, Identifiable, Sendable {
  case continueWriting
  case outline
  case titleIdeas
  case slugIdeas
  case tagIdeas
  case frontMatterPack
  case bilingualMetadata
  case summary
  case contentGap
  case angleCompare
  case translateChinese
  case translateEnglish
  case grammar
  case tone
  case localizationDraft
  case seo
  case publishReview
  case privacyCheck
  case readerReview
  case factBoundary
  case sourceChecklist
  case internalLinks
  case linkAudit
  case imagePrivacy
  case ssgChecklist
  case publishRecoveryPlan
  case imageCaptions
  case coverPrompt
  case socialShare
  case publishAssetPack
  case pullQuotes
  case publishNote
  case crossPlatformAnnouncement
  case shortVideoScript
  case tldr
  case faq
  case readerQuestions
  case stepGuide
  case checklist
  case structurePlan
  case counterpoint
  case caseStudy
  case oldArticleRefresh
  case mermaid
  case glossary
  case releaseSummary
  case seriesPlan
  case updateNote
  case commentReply

  public var id: String { rawValue }

  public static let primaryPrompts = AIPublishingDefaultCapability.defaultQuickPrompts

  public static let writingDashboardPrompts = primaryPrompts

  public static let morePrompts: [AIPublishingQuickPrompt] = {
    let defaults = Set(AIPublishingDefaultCapability.defaultQuickPrompts)
    return allCases.filter { !defaults.contains($0) }
  }()

  public static let inspectorPrompts: [AIPublishingQuickPrompt] = primaryPrompts

  public static var featuredCapabilitySections: [AIPublishingQuickPromptSection] {
    sections(for: primaryPrompts)
  }

  public static var morePromptSections: [AIPublishingQuickPromptSection] {
    sections(for: morePrompts)
  }

  public static var capabilitySections: [AIPublishingQuickPromptSection] {
    sections(for: allCases)
  }

  private static func sections(for prompts: [AIPublishingQuickPrompt]) -> [AIPublishingQuickPromptSection] {
    AIPublishingQuickPromptGroup.allCases.compactMap { group in
      let groupedPrompts = prompts.filter { $0.group == group }
      guard !groupedPrompts.isEmpty else {
        return nil
      }
      return AIPublishingQuickPromptSection(group: group, prompts: groupedPrompts)
    }
  }

  public var group: AIPublishingQuickPromptGroup {
    switch self {
    case .continueWriting, .outline, .titleIdeas, .slugIdeas, .tagIdeas, .frontMatterPack, .summary,
      .contentGap, .angleCompare, .tldr, .faq, .readerQuestions, .stepGuide, .checklist,
      .structurePlan, .counterpoint, .caseStudy, .mermaid, .glossary:
      return .writing
    case .translateChinese, .translateEnglish, .grammar, .tone, .localizationDraft:
      return .editing
    case .seo, .publishReview, .privacyCheck, .readerReview, .factBoundary,
      .sourceChecklist, .internalLinks, .linkAudit, .imagePrivacy, .ssgChecklist, .publishRecoveryPlan,
      .bilingualMetadata:
      return .publishing
    case .imageCaptions, .coverPrompt, .socialShare, .publishAssetPack, .pullQuotes,
      .publishNote, .crossPlatformAnnouncement, .shortVideoScript, .releaseSummary:
      return .distribution
    case .oldArticleRefresh, .seriesPlan, .updateNote, .commentReply:
      return .maintenance
    }
  }

  public var displayName: String {
    switch self {
    case .continueWriting:
      return "续写"
    case .outline:
      return "大纲"
    case .titleIdeas:
      return "标题建议"
    case .slugIdeas:
      return "Slug 建议"
    case .tagIdeas:
      return "Tags 建议"
    case .frontMatterPack:
      return "元数据套装"
    case .bilingualMetadata:
      return "双语元数据"
    case .summary:
      return "摘要"
    case .contentGap:
      return "内容缺口"
    case .angleCompare:
      return "写作角度对比"
    case .translateChinese:
      return "翻译中文"
    case .translateEnglish:
      return "翻译英文"
    case .grammar:
      return "语法修正"
    case .tone:
      return "语气改写"
    case .localizationDraft:
      return "双语改写"
    case .seo:
      return "SEO 建议"
    case .publishReview:
      return "发布检查"
    case .privacyCheck:
      return "隐私检查"
    case .readerReview:
      return "读者校对"
    case .factBoundary:
      return "事实边界"
    case .sourceChecklist:
      return "来源清单"
    case .internalLinks:
      return "内链建议"
    case .linkAudit:
      return "链接体检"
    case .imagePrivacy:
      return "图片隐私检查"
    case .ssgChecklist:
      return "SSG 适配检查"
    case .publishRecoveryPlan:
      return "失败修复建议"
    case .imageCaptions:
      return "图片文案"
    case .coverPrompt:
      return "封面提示词"
    case .socialShare:
      return "分享文案"
    case .publishAssetPack:
      return "发布素材包"
    case .pullQuotes:
      return "摘录卡片"
    case .publishNote:
      return "发布说明"
    case .crossPlatformAnnouncement:
      return "跨平台摘要"
    case .shortVideoScript:
      return "短视频口播稿"
    case .tldr:
      return "TL;DR"
    case .faq:
      return "FAQ"
    case .readerQuestions:
      return "读者追问"
    case .stepGuide:
      return "步骤指南"
    case .checklist:
      return "检查清单"
    case .structurePlan:
      return "结构重组"
    case .counterpoint:
      return "反方观点"
    case .caseStudy:
      return "案例分析"
    case .oldArticleRefresh:
      return "旧文更新"
    case .mermaid:
      return "Mermaid 图示"
    case .glossary:
      return "术语表"
    case .releaseSummary:
      return "发布摘要"
    case .seriesPlan:
      return "系列选题"
    case .updateNote:
      return "更新说明"
    case .commentReply:
      return "评论回复"
    }
  }

  public var systemImage: String {
    switch self {
    case .continueWriting:
      return "text.append"
    case .outline:
      return "list.bullet.rectangle"
    case .titleIdeas:
      return "textformat.size"
    case .slugIdeas:
      return "number"
    case .tagIdeas:
      return "tag"
    case .frontMatterPack:
      return "rectangle.and.pencil.and.ellipsis"
    case .bilingualMetadata:
      return "character.bubble"
    case .summary:
      return "text.quote"
    case .contentGap:
      return "rectangle.badge.questionmark"
    case .angleCompare:
      return "arrow.triangle.branch"
    case .translateChinese, .translateEnglish:
      return "character.book.closed"
    case .grammar:
      return "checkmark.seal"
    case .tone:
      return "slider.horizontal.3"
    case .localizationDraft:
      return "character.cursor.ibeam"
    case .seo:
      return "magnifyingglass"
    case .publishReview:
      return "checkmark.shield"
    case .privacyCheck:
      return "lock.shield"
    case .readerReview:
      return "person.crop.circle.badge.questionmark"
    case .factBoundary:
      return "exclamationmark.magnifyingglass"
    case .sourceChecklist:
      return "doc.text.magnifyingglass"
    case .internalLinks:
      return "link.badge.plus"
    case .linkAudit:
      return "link"
    case .imagePrivacy:
      return "photo.badge.exclamationmark"
    case .ssgChecklist:
      return "doc.text.magnifyingglass"
    case .publishRecoveryPlan:
      return "wrench.and.screwdriver"
    case .imageCaptions:
      return "photo.on.rectangle.angled"
    case .coverPrompt:
      return "photo.artframe"
    case .socialShare:
      return "megaphone"
    case .publishAssetPack:
      return "shippingbox"
    case .pullQuotes:
      return "quote.bubble"
    case .publishNote:
      return "arrow.up.doc"
    case .crossPlatformAnnouncement:
      return "rectangle.3.group.bubble"
    case .shortVideoScript:
      return "play.rectangle"
    case .tldr:
      return "text.badge.checkmark"
    case .faq:
      return "questionmark.circle"
    case .readerQuestions:
      return "person.crop.circle.badge.questionmark"
    case .stepGuide:
      return "list.number"
    case .checklist:
      return "checklist.checked"
    case .structurePlan:
      return "arrow.up.arrow.down.square"
    case .counterpoint:
      return "scale.3d"
    case .caseStudy:
      return "doc.text.magnifyingglass"
    case .oldArticleRefresh:
      return "clock.arrow.2.circlepath"
    case .mermaid:
      return "point.3.connected.trianglepath.dotted"
    case .glossary:
      return "text.book.closed"
    case .releaseSummary:
      return "rectangle.3.group.bubble"
    case .seriesPlan:
      return "rectangle.stack.badge.plus"
    case .updateNote:
      return "clock.arrow.circlepath"
    case .commentReply:
      return "bubble.left.and.bubble.right"
    }
  }

  public var prompt: String {
    switch self {
    case .continueWriting:
      return "请基于当前文章上下文续写后续内容，延续原文语气，不重复已有段落，只返回可直接放进正文的 Markdown。"
    case .outline:
      return "请基于当前文章上下文生成一份可直接插入正文的 Markdown 大纲，包含 4 到 8 个二级或三级标题，并为每节给出一句写作要点。"
    case .titleIdeas:
      return "请基于当前文章上下文给我 5 个标题候选，每个标题要具体、清楚，并标注更适合搜索、个人记录还是技术笔记。"
    case .slugIdeas:
      return "请基于当前文章上下文给我 5 个 slug 候选。使用小写 kebab-case，只包含小写英文字母、数字和连字符；不要包含日期、文件扩展名、路径分隔符、编号或解释。"
    case .tagIdeas:
      return "请基于当前文章上下文给我 3 到 8 个 tags 候选。tags 要短、稳定、可复用，优先复用文章中的技术名词、项目名和主题名；不要使用编号、引号、Markdown 或解释。"
    case .frontMatterPack:
      return "请基于当前文章生成一套 Front Matter 候选：标题、slug、summary、tags、categories、封面 alt。按字段分组输出，说明每个建议适合的发布场景，不要直接改正文。"
    case .bilingualMetadata:
      return "请基于当前文章生成一套中英文元数据候选：中文标题、英文标题、中文摘要、英文摘要、社交描述和 5 个 tags。按字段分组输出，并说明哪些字段适合直接写入 Front Matter。"
    case .summary:
      return "请为当前文章生成 3 个摘要候选：一个适合列表页，一个适合 RSS，一个适合社交分享。保持克制，不要夸大。"
    case .contentGap:
      return "请检查当前文章还缺哪些内容，按“必须补”“建议补”“可不补”三组列出。重点看读者前置知识、步骤跳跃、示例不足、边界条件、图片/代码说明和结论是否清楚。"
    case .angleCompare:
      return "请基于当前文章主题给出 3 到 5 种写作角度对比，每种角度包含适合读者、核心问题、文章结构、风险和最适合的标题方向，帮助我决定这篇文章应该怎么写。"
    case .translateChinese:
      return "请把我接下来指定的段落或当前文章重点内容翻译成简体中文，保留 Markdown、代码、链接和专有名词；如果没有指定段落，请先询问我要翻译哪一段。"
    case .translateEnglish:
      return "请把我接下来指定的段落或当前文章重点内容翻译成自然英文，保留 Markdown、代码、链接和专有名词；如果没有指定段落，请先询问我要翻译哪一段。"
    case .grammar:
      return "请帮我修正指定段落的语法、拼写、标点和不通顺表达，尽量不改变原意；输出修改后的 Markdown，并用简短列表说明关键修改点。"
    case .tone:
      return "请把指定段落分别改写成三种语气：正式、轻松、技术说明。保留事实、代码、链接和 Markdown 结构，方便我选择后应用到文章。"
    case .localizationDraft:
      return "请把我指定的段落整理成中英文两个版本：中文要自然克制，英文要适合技术博客；保留 Markdown、代码、链接和专有名词，并列出不建议直译的表达。"
    case .seo:
      return "请基于当前文章给出 SEO 优化建议，包括标题、摘要、slug、关键词、内部链接和首屏可读性；只给可执行建议，不要生成营销式夸张文案。"
    case .publishReview:
      return "请做一次发布前检查，按“可发布”“需要修改”“建议优化”列出问题，重点看结构、标题、摘要、读者理解和发布阻塞点。"
    case .privacyCheck:
      return "请检查当前文章是否包含不适合公开发布的内容，包括 token、密钥、私密路径、个人联系方式、内部系统地址和敏感上下文；不要复述完整敏感值。"
    case .readerReview:
      return "请从第一次阅读的读者视角校对当前文章，找出跳步、术语未解释、前提缺失、例子不足和结论不清楚的地方，并给出可直接修改的建议。"
    case .factBoundary:
      return "请检查当前文章中可能需要来源、限定条件或事实边界说明的表述。不要联网核验，只标出需要补证据、补上下文或降确定性的句子。"
    case .sourceChecklist:
      return "请基于当前文章生成来源与引用清单：列出哪些结论、数字、工具说明、经验判断或外部资料需要补来源；每项给出建议来源类型、正文位置和可以暂时降级的表达方式。不要编造真实链接。"
    case .internalLinks:
      return "请基于当前文章生成站内链接建议，列出建议锚文本、适合插入的位置、可能关联的旧文主题或 slug 关键词；不要编造不存在的真实路径。"
    case .linkAudit:
      return "请基于当前文章做一次链接体检：检查内部链接锚文本是否清楚、外部链接是否需要上下文说明、是否有裸 URL、是否有可能失效或需要作者手动确认的链接。不要联网请求，只输出可执行检查清单。"
    case .imagePrivacy:
      return "请基于当前文章和图片引用检查图片发布风险：是否可能包含定位、个人信息、设备截图隐私、内部路径、未补 alt/caption 或不适合公开的画面。不要假装看到了图片内容，只根据正文和文件名给出需要人工确认的清单。"
    case .ssgChecklist:
      return "请按静态博客发布检查当前文章：Front Matter 字段、slug、分类标签、摘要、图片路径、内部链接、草稿状态和框架兼容风险。按 Hexo、Hugo、Zola、Astro、Jekyll 通用规则输出，不要直接改正文。"
    case .publishRecoveryPlan:
      return "请根据我提供的发布、同步或部署失败信息，整理可能原因、优先排查顺序、需要复制的命令或日志、以及不会破坏本地草稿的修复步骤。如果我还没有提供错误信息，请先告诉我需要贴哪些信息。"
    case .imageCaptions:
      return "请基于当前文章和图片上下文生成图片 alt 与 caption 建议。每条都要说明适合的插入位置，避免夸张描述，不要编造图片里没有的信息。"
    case .coverPrompt:
      return "请基于当前文章生成 5 个封面图或配图提示词。每个提示词要说明画面主体、风格、构图、避免出现的元素和适合的使用场景；不要生成营销海报式夸张文案。"
    case .socialShare:
      return "请基于当前文章生成 5 条社交分享文案：短句版、技术读者版、个人记录版、问题引导版和摘要版。保持真实克制，不要夸大效果。"
    case .publishAssetPack:
      return "请基于当前文章生成发布素材包：站内摘要、RSS 摘要、社交分享短文案、Newsletter 摘要、Git commit message 和发布检查一句话结论。保持具体、可复制，不要新增正文没有的事实。"
    case .pullQuotes:
      return "请从当前文章中提取 5 条适合做摘录卡片或社交卡片的短句，每条包含原句、可发布改写、适合配图方向和不应脱离上下文使用的提醒。"
    case .publishNote:
      return "请基于当前文章生成发布说明：一句发布摘要、3 到 5 条变更要点、一个简短 Git commit message 候选。不要凭空补充正文没有体现的改动，不要营销化。"
    case .crossPlatformAnnouncement:
      return "请基于当前文章生成跨平台发布摘要：网站列表页摘要、RSS 摘要、社交短文、较长社交说明和 Git commit message 候选。每个版本都要具体、克制，忠于文章内容。"
    case .shortVideoScript:
      return "请基于当前文章生成短视频口播稿，包含 15 秒、30 秒、60 秒三个版本。每个版本都要有开场句、核心要点和结尾引导；不要编造演示画面、用户反馈、数据或夸张承诺。"
    case .tldr:
      return "请基于当前文章生成一段 TL;DR，控制在 3 到 5 条要点内，放在文章开头也自然。只返回可直接插入正文的 Markdown。"
    case .faq:
      return "请基于当前文章生成一组 FAQ，包含 5 到 8 个真实读者可能会问的问题和简短回答。只返回可直接插入正文的 Markdown。"
    case .readerQuestions:
      return "请基于当前文章列出读者读完后最可能追问的 6 个问题，并指出每个问题适合补在正文的哪个位置。"
    case .stepGuide:
      return "请把当前文章内容整理成步骤指南，使用 Markdown 有序列表，补齐每一步的前置条件、操作结果和注意事项。"
    case .checklist:
      return "请基于当前文章生成一份可执行检查清单，按发布前、操作中、完成后三组列出，使用 Markdown 任务列表。"
    case .structurePlan:
      return "请审阅当前文章结构，给出重组方案：建议保留、合并、移动、删除和补写的小节。不要直接重写全文，输出一份可逐项应用的 Markdown 修改计划。"
    case .counterpoint:
      return "请基于当前文章补充一节反方观点或限制条件，指出当前结论在哪些场景下不适用、有哪些风险，以及作者应该如何限定表达。"
    case .caseStudy:
      return "请基于当前文章生成一个案例分析小节，包含场景、约束、做法、结果和可复用经验。不要编造具体公司、人物、价格或未出现的数据。"
    case .oldArticleRefresh:
      return "请把当前文章当作旧文做更新评估：列出过期风险、需要复查的事实、可补充的新小节、应更新的内部链接和发布更新说明。不要联网核验，只标出需要作者确认的点。"
    case .mermaid:
      return "请基于当前文章生成一个 Mermaid 图示，用来表达流程、状态或模块关系。只返回可直接插入 Markdown 的 mermaid 代码块，并附一行 alt 说明。"
    case .glossary:
      return "请从当前文章中提取关键术语，生成 Markdown 术语表。每个术语用一句话解释，避免编造文章里没有出现的概念。"
    case .releaseSummary:
      return "请基于当前文章生成一组发布摘要：网站摘要、RSS 摘要、社交平台短文案和 Git 提交说明。每条都要克制、具体、可直接复制。"
    case .seriesPlan:
      return "请把当前文章扩展成一个系列写作计划，给出 5 到 8 个后续选题、每篇的核心问题、适合的内部链接位置和建议发布顺序。"
    case .updateNote:
      return "请为当前文章生成更新说明，包含这次更新改了什么、为什么更新、读者需要重新关注的部分，以及可用于 Git 提交或发布日志的一句话摘要。"
    case .commentReply:
      return "请基于当前文章帮我起草读者评论回复。如果我还没有提供评论内容，请先询问要回复哪条评论；如果已提供评论，请保持礼貌、具体、不过度承诺。"
    }
  }
}

public struct AIPublishingDashboardPromptSummary: Equatable, Sendable {
  public var prompts: [AIPublishingQuickPrompt]
  public var summaryText: String

  public var promptCount: Int {
    prompts.count
  }

  public init(prompts: [AIPublishingQuickPrompt], summaryText: String) {
    self.prompts = prompts
    self.summaryText = summaryText
  }
}

public enum AIPublishingDashboardPromptService {
  public static func summary(
    prompts: [AIPublishingQuickPrompt] = AIPublishingQuickPrompt.writingDashboardPrompts
  ) -> AIPublishingDashboardPromptSummary {
    AIPublishingDashboardPromptSummary(
      prompts: prompts,
      summaryText: prompts.map(\.displayName).joined(separator: " · ")
    )
  }
}
