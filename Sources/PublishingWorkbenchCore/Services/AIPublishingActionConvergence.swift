import Foundation

/// Stable, user-facing AI action families. Legacy action kinds remain available
/// for saved prompts and old workflows, while new entry points use these families.
public enum AIPublishingActionConvergence: Hashable, Sendable {
  case publishAssetPack(AIPublishingAssetPackConfiguration)
  case rewriteSelection(AIPublishingRewriteConfiguration)
  case contentReview(AIPublishingReviewConfiguration)

  public var canonicalActionKind: AIPublishingActionKind {
    switch self {
    case .publishAssetPack:
      return .draftPublishAssetPack
    case .rewriteSelection:
      return .rewriteSelection
    case .contentReview:
      return .publishingReadiness
    }
  }

  public var displayName: String {
    switch self {
    case .publishAssetPack:
      return "生成发布资产包"
    case .rewriteSelection:
      return "改写选区"
    case .contentReview:
      return "内容审查"
    }
  }

  public var systemImage: String {
    switch self {
    case .publishAssetPack:
      return "shippingbox"
    case .rewriteSelection:
      return "wand.and.stars"
    case .contentReview:
      return "checkmark.shield"
    }
  }
}

public enum AIPublishingAssetKind: String, CaseIterable, Hashable, Identifiable, Sendable {
  case frontMatter
  case socialShare
  case pullQuotes
  case publishNote
  case newsletterSummary
  case coverImagePrompt
  case crossPlatformAnnouncement
  case shortVideoScript
  case imageAltCaptions

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .frontMatter:
      return "Front Matter"
    case .socialShare:
      return "社交分享"
    case .pullQuotes:
      return "可引用摘录"
    case .publishNote:
      return "发布说明"
    case .newsletterSummary:
      return "Newsletter 摘要"
    case .coverImagePrompt:
      return "封面图提示词"
    case .crossPlatformAnnouncement:
      return "跨平台发布摘要"
    case .shortVideoScript:
      return "短视频口播稿"
    case .imageAltCaptions:
      return "图片 Alt/Caption"
    }
  }

  public var promptInstruction: String {
    switch self {
    case .frontMatter:
      return "生成标题、slug、summary/description 和 tags 候选，并列出需要作者确认的字段；不要直接修改 front matter。"
    case .socialShare:
      return "生成短社交文案、长社交文案和 3 个可选开头；不要编造反馈、数据或外部验证。"
    case .pullQuotes:
      return "提炼 6 到 10 条可引用摘录，附适用渠道、原文依据位置和是否需要人工确认；不要制造更强结论。"
    case .publishNote:
      return "生成发布说明、3 到 5 条变更要点和一个克制的 commit message 候选；不要编造未体现的改动。"
    case .newsletterSummary:
      return "生成 Newsletter 一句话导读、3 条要点、邮件开头短段落和克制 CTA；不要编造读者反馈或阅读数据。"
    case .coverImagePrompt:
      return "生成技术说明、工作流场景、抽象概念和极简信息图 4 个封面图提示词；避免虚构真实产品画面。"
    case .crossPlatformAnnouncement:
      return "生成网站列表页摘要、RSS 摘要、社交短文、较长社交说明和 commit message 候选；保持具体、克制。"
    case .shortVideoScript:
      return "生成 15 秒、30 秒和 60 秒三个短视频口播稿版本，每个包含开场句、核心要点和结尾引导；不要编造演示画面或数据。"
    case .imageAltCaptions:
      return "根据文件名、引用位置和正文上下文生成图片 alt/caption 建议；不能假装看到了未发送的图片。"
    }
  }

  public static var defaultSelection: Set<Self> {
    Set(allCases)
  }
}

public struct AIPublishingAssetPackConfiguration: Hashable, Sendable {
  public var assets: Set<AIPublishingAssetKind>

  public init(assets: Set<AIPublishingAssetKind> = AIPublishingAssetKind.defaultSelection) {
    self.assets = assets
  }

  public var normalizedAssets: [AIPublishingAssetKind] {
    let selected = assets.isEmpty ? AIPublishingAssetKind.defaultSelection : assets
    return AIPublishingAssetKind.allCases.filter { selected.contains($0) }
  }
}

public enum AIPublishingRewriteOperation: String, CaseIterable, Hashable, Identifiable, Sendable {
  case rewrite
  case polish
  case expand
  case condense
  case simplify
  case summarize
  case removeRedundancy

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .rewrite:
      return "改写"
    case .polish:
      return "润色"
    case .expand:
      return "扩写"
    case .condense:
      return "压缩"
    case .simplify:
      return "简化"
    case .summarize:
      return "摘要"
    case .removeRedundancy:
      return "删减冗余"
    }
  }

  public var systemImage: String {
    switch self {
    case .rewrite:
      return "arrow.triangle.2.circlepath"
    case .polish:
      return "wand.and.stars"
    case .expand:
      return "text.append"
    case .condense:
      return "scissors"
    case .simplify:
      return "text.badge.minus"
    case .summarize:
      return "doc.text.below.ecg"
    case .removeRedundancy:
      return "scissors.badge.ellipsis"
    }
  }

  public var promptInstruction: String {
    switch self {
    case .rewrite:
      return "保持原意和事实边界，输出可直接替换选区的 Markdown。"
    case .polish:
      return "改善语句、衔接和节奏，尽量不改变原意，输出可直接替换选区的 Markdown。"
    case .expand:
      return "补足必要解释、过渡和上下文，但不新增正文没有依据的事实，输出可直接替换选区的 Markdown。"
    case .condense:
      return "删除绕远表达，保留关键事实、限制条件、代码、链接和 Markdown 结构，输出可直接替换选区的 Markdown。"
    case .simplify:
      return "降低术语密度和理解门槛，保留事实、代码、链接和 Markdown 结构，输出可直接替换选区的 Markdown。"
    case .summarize:
      return "压缩为清晰摘要，保留关键事实、结论和限制条件，输出可直接替换选区的 Markdown。"
    case .removeRedundancy:
      return "删除重复、口水话和冗余表达，保留判断依据、代码、链接和 Markdown 结构，输出可直接替换选区的 Markdown。"
    }
  }
}

public enum AIPublishingRewriteStyle: String, CaseIterable, Hashable, Identifiable, Sendable {
  case balanced
  case readerFriendly
  case formal
  case casual
  case technical

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .balanced:
      return "自然"
    case .readerFriendly:
      return "读者友好"
    case .formal:
      return "正式"
    case .casual:
      return "轻松"
    case .technical:
      return "技术"
    }
  }

  public var promptInstruction: String {
    switch self {
    case .balanced:
      return "语气自然、清楚、克制，适合个人网站发布。"
    case .readerFriendly:
      return "减少跳跃表达，增强衔接和可读性，照顾非专家读者。"
    case .formal:
      return "语气正式、克制，适合公开发布，避免夸张和营销化表达。"
    case .casual:
      return "语气轻松自然，但仍保持准确并适合个人网站发布。"
    case .technical:
      return "强化术语准确性、步骤边界和工程语境，面向技术读者。"
    }
  }
}

public struct AIPublishingRewriteConfiguration: Hashable, Sendable {
  public var operation: AIPublishingRewriteOperation
  public var style: AIPublishingRewriteStyle

  public init(
    operation: AIPublishingRewriteOperation = .rewrite,
    style: AIPublishingRewriteStyle = .balanced
  ) {
    self.operation = operation
    self.style = style
  }
}

public enum AIPublishingReviewCheck: String, CaseIterable, Hashable, Identifiable, Sendable {
  case contentGaps
  case unsupportedClaims
  case privacy
  case linkQuality
  case imagePrivacy
  case ssgCompatibility
  case seoReadability
  case readerClarity
  case technicalAccuracy

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .contentGaps:
      return "内容缺口"
    case .unsupportedClaims:
      return "事实边界"
    case .privacy:
      return "公开隐私"
    case .linkQuality:
      return "链接质量"
    case .imagePrivacy:
      return "图片隐私"
    case .ssgCompatibility:
      return "SSG 兼容"
    case .seoReadability:
      return "SEO 与可读性"
    case .readerClarity:
      return "读者清晰度"
    case .technicalAccuracy:
      return "技术准确性"
    }
  }

  public var promptInstruction: String {
    switch self {
    case .contentGaps:
      return "检查内容缺口，并按缺口、影响、需要补充的证据或段落、建议插入位置输出。"
    case .unsupportedClaims:
      return "标出可能缺少来源、数字或结论无依据、因果跳跃和效果承诺过强的表述。"
    case .privacy:
      return "检查密钥、内网地址、个人隐私、客户信息、未公开业务数据、调试路径和私密路径。"
    case .linkQuality:
      return "检查链接或引用位置的风险、人工确认方式和建议改法；不要声称已经访问外部网页。"
    case .imagePrivacy:
      return "检查图片引用、文件名、路径和上下文可能暴露的个人、客户、账号、token 或私密信息；不假装看到了图片画面。"
    case .ssgCompatibility:
      return "检查 Hexo、Hugo、Zola、Astro、Jekyll 常见 front matter、摘要、图片路径、短代码和 Markdown 语法风险。"
    case .seoReadability:
      return "检查标题、摘要、首屏、结构层级、关键词自然度和读者理解门槛；不要承诺搜索排名。"
    case .readerClarity:
      return "检查读者可能卡住的位置、缺少的前提、跳跃段落、术语解释和过渡建议。"
    case .technicalAccuracy:
      return "检查技术表述、风险类型、需要验证的证据和保守改写；不要假装运行过代码、命令或测试。"
    }
  }

  public static var defaultSelection: Set<Self> {
    Set(allCases)
  }
}

public struct AIPublishingReviewConfiguration: Hashable, Sendable {
  public var checks: Set<AIPublishingReviewCheck>

  public init(checks: Set<AIPublishingReviewCheck> = AIPublishingReviewCheck.defaultSelection) {
    self.checks = checks
  }

  public var normalizedChecks: [AIPublishingReviewCheck] {
    let selected = checks.isEmpty ? AIPublishingReviewCheck.defaultSelection : checks
    return AIPublishingReviewCheck.allCases.filter { selected.contains($0) }
  }
}
