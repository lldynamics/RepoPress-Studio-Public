import Foundation

public enum AIPublishingChatPromptTemplateService {
  public static func articleContextPrompt(
    for draft: ArticleDraft,
    profile: SiteProfile,
    maxBodyLength: Int = 3_000
  ) -> String {
    let body = truncated(draft.bodyMarkdown.trimmedForPublishing, maxLength: maxBodyLength)
    let bodySection = body.isEmpty ? "正文为空。" : body

    return """
    请把下面内容作为当前文章上下文，继续帮我分析、改写或生成可应用的 Markdown。不要声称已经修改文章，不要编造上下文没有提供的事实。

    [当前文章]
    标题：\(draft.title.nilIfEmpty ?? "未设置")
    Slug：\(draft.slug.nilIfEmpty ?? "未设置")
    摘要：\(draft.summary.nilIfEmpty ?? "未设置")
    Tags：\(draft.tags.isEmpty ? "未设置" : draft.tags.joined(separator: ", "))
    Categories：\(draft.categories.isEmpty ? "未设置" : draft.categories.joined(separator: ", "))
    发布路径：\(profile.markdownPath(for: draft))

    正文节选：
    \(bodySection)
    """
  }

  public static func publishingContextPrompt(
    for draft: ArticleDraft,
    profile: SiteProfile,
    issues: [PreflightIssue],
    package: PublishPackage,
    imageReport: ImageWorkbenchReport
  ) -> String {
    let visibleIssues = issues
      .filter { $0.severity != .info }
      .prefix(8)
      .map { "- \($0.severity.displayName)：\($0.title) - \($0.message)" }
      .joined(separator: "\n")
    let fileLines = package.files
      .prefix(10)
      .map { "- \($0.kind.displayName)：\($0.repositoryPath)" }
      .joined(separator: "\n")

    return """
    请把下面内容作为当前文章的 Mac 发布上下文，帮我做发布前判断或生成发布素材。不要编造已经完成的线上验证。

    [发布上下文]
    站点：\(profile.name)（\(profile.siteKind.displayName)）
    文章：\(draft.title.nilIfEmpty ?? "未命名文章")
    发布路径：\(profile.markdownPath(for: draft))

    发布文件（\(package.files.count) 个）：
    \(fileLines.isEmpty ? "无发布文件。" : fileLines)

    发布检查：
    \(visibleIssues.isEmpty ? "无阻塞问题。" : visibleIssues)

    图片检查：
    - 图片数：\(imageReport.items.count)
    - 缺 alt：\(imageReport.missingAltTextCount)
    - 缺源图：\(imageReport.missingSourceCount)
    - 重复图片：\(imageReport.duplicateImageCount)
    - 可转 WebP：\(imageReport.webPConvertibleCount)
    - 可优化 SVG：\(imageReport.optimizableSVGCount)
    - 可缩放大图：\(imageReport.resizableImageCount)
    - 可压缩 JPEG：\(imageReport.optimizableJPEGCount)
    - 封面状态：\(imageReport.coverStatus.state.displayName)
    """
  }

  public static func paragraphContextPrompt(
    for paragraph: AIPublishingChatDraftParagraph,
    draft: ArticleDraft,
    profile: SiteProfile,
    maxParagraphLength: Int = 2_500
  ) -> String {
    let paragraphText = truncated(
      paragraph.text.trimmedForPublishing,
      maxLength: maxParagraphLength
    )

    return """
    请把下面段落作为当前重点上下文，优先围绕这段内容继续分析、改写或生成可应用的 Markdown。不要默认改写整篇文章，不要声称已经修改文章。

    [当前文章段落]
    文章：\(draft.title.nilIfEmpty ?? "未命名文章")
    发布路径：\(profile.markdownPath(for: draft))
    段落：\(paragraph.title)

    段落内容：
    \(paragraphText.isEmpty ? "段落内容为空。" : paragraphText)
    """
  }

  public static func editorActionPrompt(for action: AIPublishingActionKind) -> String {
    let selectionRequirement = action.requiresSelectedTextForBestResult
      ? "如果这个动作需要选区，而当前上下文没有明确选中文本，请先要求我选中正文或贴出要处理的段落。"
      : "如果当前文章信息不足，请先指出缺少哪些事实、选区、图片上下文或发布目标。"

    return """
    请基于当前文章上下文，围绕“\(action.displayName)”继续作为 AI 发布助手协作。

    场景：\(action.promptLibraryDescription)

    要求：
    1. 先判断这个动作能否直接完成，还是需要我补充选区、事实、图片上下文或发布目标。
    2. \(selectionRequirement)
    3. 如果可以直接生成，请输出可预览、可复制的 Markdown，并标明适合应用到正文、Front Matter、图片字段还是发布素材。
    4. 不要声称已经修改文章，不要编造正文没有提供的事实。
    """
  }

  public static func workflowGuidePrompt(for guide: AIPublishingWorkflowGuide) -> String {
    let actionList = guide.prompts
      .enumerated()
      .map { index, prompt in
        "\(index + 1). \(prompt.displayName)：\(prompt.prompt)"
      }
      .joined(separator: "\n")

    return """
    请基于当前文章上下文执行“\(guide.title)”AI 工作流。

    目标：\(guide.description)

    步骤：
    \(actionList)

    要求：
    1. 先判断哪些步骤可以直接完成，哪些需要我补充选区、事实、图片内容或发布目标。
    2. 输出要可预览、可复制，并标明哪些内容适合应用到文章正文、Front Matter、图片字段或发布素材。
    3. 不要直接声称已经修改文章，不要编造正文没有提供的事实。
    """
  }

  public static func relatedArticleSuggestionPrompt(
    for suggestion: SiteRelationSuggestion,
    draft: ArticleDraft,
    profile: SiteProfile
  ) -> String {
    let sharedLabels = suggestion.sharedLabels.isEmpty
      ? "未提供"
      : suggestion.sharedLabels.joined(separator: "、")

    return """
    请基于下面的站内关联文章建议，帮我为当前文章生成可直接放入正文的内链 Markdown。不要声称已经修改文章，不要编造正文没有提供的事实。

    [当前文章]
    标题：\(draft.title.nilIfEmpty ?? "未命名文章")
    发布路径：\(profile.markdownPath(for: draft))

    [建议关联文章]
    目标标题：\(suggestion.targetTitle)
    目标路径：\(suggestion.targetPath)
    共享标签/分类：\(sharedLabels)
    推荐原因：\(suggestion.reason)

    要求：
    1. 给出 2-3 个自然的插入位置或上下文场景。
    2. 每个方案提供一段可复制的 Markdown，必须包含指向 \(suggestion.targetPath) 的链接。
    3. 标出锚文本，不要写成生硬的“点击这里”。
    """
  }

  public static func maintenanceActionPrompt(
    for item: MaintenanceActionItem,
    draft: ArticleDraft,
    profile: SiteProfile,
    maxBodyLength: Int = 2_500
  ) -> String {
    let body = truncated(draft.bodyMarkdown.trimmedForPublishing, maxLength: maxBodyLength)
    let targetPath = item.targetPath?.nilIfEmpty ?? profile.markdownPath(for: draft)
    let detail = item.detail.trimmedForPublishing.nilIfEmpty ?? "未提供额外详情。"

    return """
    请基于下面的站点维护行动项，帮我给当前文章生成可执行的修复方案。不要声称已经修改文章，不要编造正文没有提供的事实。

    [当前文章]
    标题：\(draft.title.nilIfEmpty ?? "未命名文章")
    Slug：\(draft.slug.nilIfEmpty ?? "未设置")
    当前 Profile：\(profile.name)（\(profile.siteKind.displayName)）
    发布路径：\(profile.markdownPath(for: draft))

    [维护行动项]
    类型：\(item.kind.displayName)
    优先级：\(item.priority.displayName)
    标题：\(item.title)
    摘要：\(item.summary)
    详情：\(detail)
    目标路径：\(targetPath)

    [任务清单]
    \(item.clipboardMarkdown)

    [正文节选]
    \(body.isEmpty ? "正文为空。" : body)

    要求：
    1. 先判断这条维护任务是旧文刷新、链接修复、分类治理还是内链补充，并说明处理风险。
    2. 给出可直接应用到正文或 Front Matter 的 Markdown / 字段修改建议。
    3. 如果涉及链接或目标路径，明确应该检查的链接、锚文本和目标文章路径。
    4. 给出完成后的复查清单，包含预检、SEO/社交预览或发布后校验中需要重新确认的项目。
    """
  }

  public static func releaseRecoveryPrompt(
    for entry: ReleaseLedgerEntry,
    package: ReleaseRecoveryPackage,
    draft: ArticleDraft,
    profile: SiteProfile,
    maxBodyLength: Int = 2_500
  ) -> String {
    let body = truncated(draft.bodyMarkdown.trimmedForPublishing, maxLength: maxBodyLength)
    let nextActions = package.nextActions.isEmpty
      ? "恢复包没有列出下一步，请先根据状态判断。"
      : package.nextActions.map { "- \($0)" }.joined(separator: "\n")
    let changedPaths = package.changedPaths.isEmpty
      ? "未记录变更文件。"
      : package.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    let commandLines = package.commandLines.isEmpty
      ? "未提供可执行恢复命令。"
      : package.commandLines.map { "$ \($0)" }.joined(separator: "\n")

    return """
    请基于下面的发布恢复包，帮我判断这次发布应该重试、等待、修复还是回滚。不要声称已经执行命令、修改远端仓库或完成部署校验。

    [当前文章]
    标题：\(draft.title.nilIfEmpty ?? "未命名文章")
    Slug：\(draft.slug.nilIfEmpty ?? "未设置")
    当前 Profile：\(profile.name)（\(profile.siteKind.displayName)）
    发布路径：\(profile.markdownPath(for: draft))

    [发布记录]
    状态：\(entry.status.displayName)
    类型：\(entry.record.kind.displayName)
    标题：\(entry.record.title)
    摘要：\(entry.statusMessage)
    分支：\(entry.record.branchName?.nilIfEmpty ?? "未记录")
    目标分支：\(entry.record.targetBranch?.nilIfEmpty ?? "未记录")
    Commit：\(entry.record.shortCommitSHA ?? "未记录")
    远端链接：\(package.remoteURL?.nilIfEmpty ?? entry.record.reviewURL?.nilIfEmpty ?? "未记录")

    [恢复包]
    标题：\(package.title)
    摘要：\(package.summary)
    回滚 PR/MR：\(package.rollbackReviewURL?.nilIfEmpty ?? "未生成")

    变更文件：
    \(changedPaths)

    下一步：
    \(nextActions)

    恢复命令：
    \(commandLines)

    [恢复包原文]
    \(package.clipboardMarkdown)

    [正文节选]
    \(body.isEmpty ? "正文为空。" : body)

    要求：
    1. 先判断当前状态属于待部署、部署中、失败、离线待重试、远端恢复待确认还是已上线后回滚预案。
    2. 给出建议路径：继续等待/手动刷新部署、重试发布、修正文稿或执行回滚，并说明选择理由。
    3. 如果需要回滚，整理应复核的变更文件、命令和 PR/MR 草稿风险。
    4. 列出人工必须确认的远端事实，不要编造 Actions、Pipeline、Pages、Netlify、Vercel 或 Cloudflare 的结果。
    5. 输出一份可复制的处理清单，适合贴回发布记录或外部验收证据。
    """
  }

  public static func seoSocialPreviewPrompt(
    snapshot: SEOSocialPreviewSnapshot,
    draft: ArticleDraft,
    profile: SiteProfile,
    relatedSuggestions: [SiteRelationSuggestion] = [],
    maxBodyLength: Int = 2_500
  ) -> String {
    let body = truncated(draft.bodyMarkdown.trimmedForPublishing, maxLength: maxBodyLength)
    let readiness = snapshot.platformReadiness.map { item in
      let warnings = item.warningMessages.isEmpty
        ? ""
        : "\n  警告：\(item.warningMessages.joined(separator: "；"))"
      let missing = item.missingRequiredProperties.isEmpty
        ? ""
        : "\n  缺少：\(item.missingRequiredProperties.joined(separator: "、"))"
      return "- \(item.kind.displayName)：\(item.status.displayName)；\(item.message)\(missing)\(warnings)"
    }.joined(separator: "\n")
    let cards = snapshot.cards.map { card in
      """
      - \(card.kind.displayName)
        标题：\(card.title)（\(card.titleBudgetText)）
        描述：\(card.description)（\(card.descriptionBudgetText)）
        URL：\(card.urlText)
        图片：\(card.imagePath?.nilIfEmpty ?? "未设置")
        Alt：\(card.imageAltText?.nilIfEmpty ?? "未设置")
      """
    }.joined(separator: "\n")
    let shareCopy = snapshot.socialShareCopyItems.map { item in
      """
      - \(item.kind.displayName)
        标题：\(item.title)
        正文：\(item.body)
        Hashtags：\(item.hashtagText.nilIfEmpty ?? "未设置")
      """
    }.joined(separator: "\n")
    let related = relatedSuggestions.isEmpty
      ? "没有找到可用的已发布关联文章建议。"
      : relatedSuggestions.map { suggestion in
        "- \(suggestion.sourceTitle) -> \(suggestion.targetTitle)：\(suggestion.targetPath)；\(suggestion.reason)"
      }.joined(separator: "\n")
    let findings = snapshot.findings.isEmpty
      ? "没有 SEO/Social 发现项。"
      : snapshot.findings.map { finding in
        "- \(finding.severity.displayName)：\(finding.title)；\(finding.message)"
      }.joined(separator: "\n")

    return """
    请基于下面的 SEO / Social 预览快照，帮我优化这篇文章的搜索标题、摘要、Open Graph、Twitter/X 分享表现和关联文章内链。不要声称已经修改文章、刷新缓存或完成线上平台校验。

    [当前文章]
    标题：\(draft.title.nilIfEmpty ?? "未命名文章")
    Slug：\(draft.slug.nilIfEmpty ?? "未设置")
    当前 Profile：\(profile.name)（\(profile.siteKind.displayName)）
    发布路径：\(snapshot.markdownPath)
    Canonical URL：\(snapshot.canonicalURLText)
    Tags：\(draft.tags.isEmpty ? "未设置" : draft.tags.joined(separator: "、"))
    Categories：\(draft.categories.isEmpty ? "未设置" : draft.categories.joined(separator: "、"))

    [平台就绪度]
    \(readiness)

    [卡片预览]
    \(cards)

    [分享文案]
    \(shareCopy)

    [SEO / Social 发现项]
    \(findings)

    [关联文章建议]
    \(related)

    [Meta HTML]
    \(snapshot.metaTags.htmlBlock.nilIfEmpty ?? "未生成 Meta HTML。")

    [正文节选]
    \(body.isEmpty ? "正文为空。" : body)

    要求：
    1. 先判断搜索、Open Graph、Twitter/X 三类预览中最影响发布质量的问题。
    2. 给出可直接应用的标题、摘要、Tags 和社交分享文案建议，标注适合的平台和字数风险。
    3. 如果需要内链，基于关联文章建议给出自然插入句，不要编造未提供的目标文章。
    4. 列出发布前需要人工复核的 Meta HTML、封面图、Alt、外部调试链接和缓存刷新事项。
    5. 输出一份可复制的 SEO / Social 修改清单，适合回填到文章元数据或发布记录。
    """
  }

  public static func generalDraftReusePlanPrompt(
    for plan: GeneralDraftReusePlan,
    draft: ArticleDraft,
    profile: SiteProfile,
    maxBodyLength: Int = 2_500
  ) -> String {
    let body = truncated(draft.bodyMarkdown.trimmedForPublishing, maxLength: maxBodyLength)
    let riskItems = plan.riskItems.isEmpty
      ? "未发现明显跨站复用风险。"
      : plan.riskItems.map { "- \($0)" }.joined(separator: "\n")
    let checklistItems = plan.checklistItems.isEmpty
      ? "未提供发布前检查项。"
      : plan.checklistItems.map { "- \($0)" }.joined(separator: "\n")
    let sourceFieldDiffs = plan.sourceFieldDiffs.isEmpty
      ? "- 未检测到与来源草稿的关键字段差异。"
      : plan.sourceFieldDiffs.map { "- \($0)" }.joined(separator: "\n")

    return """
    请基于下面的跨站点复用计划，帮我把通用素材整理成适合目标站点发布的可应用内容。不要声称已经修改文章，不要编造正文没有提供的事实。

    [目标草稿]
    标题：\(draft.title.nilIfEmpty ?? "未命名文章")
    Slug：\(draft.slug.nilIfEmpty ?? "未设置")
    当前 Profile：\(profile.name)
    建议发布路径：\(plan.targetMarkdownPath)
    目标站点类型：\(plan.targetSiteKind.displayName)

    [复用来源]
    来源 Profile：\(plan.sourceProfileName)
    目标 Profile：\(plan.targetProfileName)
    原发布路径：\(plan.sourceRepositoryPath?.nilIfEmpty ?? "未绑定")
    附件数：\(plan.attachmentCount)
    附件待补：alt \(plan.missingAltTextCount) 个，caption \(plan.missingCaptionCount) 个
    风险等级：\(plan.riskLevel.displayName)

    [字段对比]
    \(sourceFieldDiffs)

    [复用风险]
    \(riskItems)

    [发布前检查]
    \(checklistItems)

    [正文节选]
    \(body.isEmpty ? "正文为空。" : body)

    要求：
    1. 先给出跨站复用判断：哪些内容可以保留，哪些需要按目标站点重写或删除。
    2. 输出建议的 Front Matter 调整，包括 title、slug、summary、tags、categories。
    3. 如果存在附件待补，请给出 alt/caption 建议和路径复查提醒。
    4. 给出一版可复制的 Markdown 改写建议，并列出发布前还需要人工确认的事项。
    """
  }

  public static func quotedMessagePrompt(
    for message: AIPublishingChatMessage,
    maxContentLength: Int = 2_000
  ) -> String {
    let trimmed = AIPublishingChatMessageCompositionService.displayContent(for: message).trimmedForPublishing
    guard !trimmed.isEmpty else {
      return ""
    }

    let role = switch message.role {
    case .user:
      "用户消息"
    case .assistant:
      "AI 回复"
    }
    let content = truncated(trimmed, maxLength: maxContentLength)
    let quotedContent = content
      .components(separatedBy: .newlines)
      .map { "> \($0)" }
      .joined(separator: "\n")

    return """
    请基于下面这条\(role)继续讨论：

    \(quotedContent)

    请回答我的追问，或帮我整理成可应用到文章的 Markdown。
    """
  }

  private static func truncated(_ text: String, maxLength: Int) -> String {
    guard maxLength > 0, text.count > maxLength else {
      return text
    }
    return String(text.prefix(maxLength)) + "...（已截断）"
  }
}
