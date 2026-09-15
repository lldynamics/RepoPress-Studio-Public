import Foundation

public enum AIPublishingChatPromptTemplateService {

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

  private static func truncated(_ text: String, maxLength: Int) -> String {
    guard maxLength > 0, text.count > maxLength else {
      return text
    }
    return String(text.prefix(maxLength)) + "...（已截断）"
  }
}
