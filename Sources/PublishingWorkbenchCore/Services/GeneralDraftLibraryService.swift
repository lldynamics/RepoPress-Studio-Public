import Foundation

public struct GeneralDraftLibraryReport: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var publishingProfileCount: Int
  public var items: [GeneralDraftLibraryItem]

  public init(
    generatedAt: Date,
    publishingProfileCount: Int,
    items: [GeneralDraftLibraryItem]
  ) {
    self.generatedAt = generatedAt
    self.publishingProfileCount = publishingProfileCount
    self.items = items
  }
}

public struct GeneralDraftLibraryItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var title: String
  public var profileID: UUID
  public var profileName: String
  public var updatedAt: Date

  public init(
    draftID: UUID,
    title: String,
    profileID: UUID,
    profileName: String,
    updatedAt: Date
  ) {
    self.draftID = draftID
    self.title = title
    self.profileID = profileID
    self.profileName = profileName
    self.updatedAt = updatedAt
  }
}

public enum GeneralDraftReuseRiskLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case ready
  case review
  case high

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .ready:
      return "可复用"
    case .review:
      return "需复查"
    case .high:
      return "高风险"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle"
    case .review:
      return "eye"
    case .high:
      return "exclamationmark.triangle"
    }
  }
}

public struct GeneralDraftReusePlan: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var sourceDraftID: UUID
  public var targetDraftID: UUID
  public var title: String
  public var sourceProfileName: String
  public var targetProfileName: String
  public var targetMarkdownPath: String
  public var sourceRepositoryPath: String?
  public var targetSiteKind: SiteKind
  public var attachmentCount: Int
  public var missingAltTextCount: Int
  public var missingCaptionCount: Int
  public var riskLevel: GeneralDraftReuseRiskLevel
  public var riskItems: [String]
  public var sourceFieldDiffs: [String]
  public var checklistItems: [String]
  public var generatedAt: Date

  public init(
    id: UUID = UUID(),
    sourceDraftID: UUID,
    targetDraftID: UUID,
    title: String,
    sourceProfileName: String,
    targetProfileName: String,
    targetMarkdownPath: String,
    sourceRepositoryPath: String?,
    targetSiteKind: SiteKind,
    attachmentCount: Int,
    missingAltTextCount: Int,
    missingCaptionCount: Int,
    riskLevel: GeneralDraftReuseRiskLevel = .ready,
    riskItems: [String] = [],
    sourceFieldDiffs: [String] = [],
    checklistItems: [String],
    generatedAt: Date
  ) {
    self.id = id
    self.sourceDraftID = sourceDraftID
    self.targetDraftID = targetDraftID
    self.title = title
    self.sourceProfileName = sourceProfileName
    self.targetProfileName = targetProfileName
    self.targetMarkdownPath = targetMarkdownPath
    self.sourceRepositoryPath = sourceRepositoryPath
    self.targetSiteKind = targetSiteKind
    self.attachmentCount = attachmentCount
    self.missingAltTextCount = missingAltTextCount
    self.missingCaptionCount = missingCaptionCount
    self.riskLevel = riskLevel
    self.riskItems = riskItems
    self.sourceFieldDiffs = sourceFieldDiffs
    self.checklistItems = checklistItems
    self.generatedAt = generatedAt
  }

  public var hasAttachmentWarnings: Bool {
    missingAltTextCount > 0 || missingCaptionCount > 0
  }

  public var checklistMarkdown: String {
    var lines = [
      "# 跨站点复用计划：\(title)",
      "",
      "- 来源：\(sourceProfileName)",
      "- 目标站点：\(targetProfileName)",
      "- 建议发布路径：\(targetMarkdownPath)",
      "- 目标类型：\(targetSiteKind.rawValue)",
      "- 附件数：\(attachmentCount)"
    ]
    if let sourceRepositoryPath, !sourceRepositoryPath.isEmpty {
      lines.append("- 原发布路径：\(sourceRepositoryPath)")
    }
    if hasAttachmentWarnings {
      lines.append("- 附件待补：alt \(missingAltTextCount) 个，caption \(missingCaptionCount) 个")
    }
    if !sourceFieldDiffs.isEmpty {
      lines.append("")
      lines.append("## 字段对比")
      lines.append(contentsOf: sourceFieldDiffs.map { "- \($0)" })
    }
    lines.append("- 风险等级：\(riskLevel.displayName)")
    if !riskItems.isEmpty {
      lines.append("")
      lines.append("## 复用风险")
      lines.append(contentsOf: riskItems.map { "- \($0)" })
    }

    lines.append("")
    lines.append("## 发布前检查")
    lines.append(contentsOf: checklistItems.map { "- [ ] \($0)" })
    return lines.joined(separator: "\n")
  }
}

public struct GeneralDraftLibraryService {
  public init() {}

  public func report(
    drafts: [ArticleDraft],
    profiles: [SiteProfile],
    now: Date = Date(),
    masksPrivateContent: Bool = false
  ) -> GeneralDraftLibraryReport {
    let publishingProfiles = profiles.filter { $0.purpose == .publishing }
    let profilesByID = Dictionary(uniqueKeysWithValues: publishingProfiles.map { ($0.id, $0) })
    let items = drafts.compactMap { draft -> GeneralDraftLibraryItem? in
      guard let profile = profilesByID[draft.siteProfileID] else { return nil }
      let title = masksPrivateContent && draft.isPrivate
        ? "私密文章"
        : draft.title.nilIfEmpty ?? "未命名文章"
      return GeneralDraftLibraryItem(
        draftID: draft.id,
        title: title,
        profileID: profile.id,
        profileName: profile.name,
        updatedAt: draft.updatedAt
      )
    }
    .sorted { $0.updatedAt > $1.updatedAt }

    return GeneralDraftLibraryReport(
      generatedAt: now,
      publishingProfileCount: publishingProfiles.count,
      items: items
    )
  }

  public func reusePlan(
    sourceDraft: ArticleDraft,
    copiedDraft: ArticleDraft,
    sourceProfile: SiteProfile?,
    targetProfile: SiteProfile,
    now: Date = Date()
  ) -> GeneralDraftReusePlan {
    let sourceProfileName = sourceProfile?.name ?? "未知 Profile"
    let targetMarkdownPath = targetProfile.markdownPath(for: copiedDraft)
    let imageAttachments = copiedDraft.attachments.filter { $0.mediaKind == .image }
    let missingAltTextCount = imageAttachments.filter { $0.altText.trimmedForPublishing.isEmpty }.count
    let missingCaptionCount = imageAttachments.filter { $0.caption.trimmedForPublishing.isEmpty }.count
    let riskItems = reuseRiskItems(
      sourceDraft: sourceDraft,
      copiedDraft: copiedDraft,
      sourceProfile: sourceProfile,
      targetProfile: targetProfile,
      targetMarkdownPath: targetMarkdownPath,
      missingAltTextCount: missingAltTextCount,
      missingCaptionCount: missingCaptionCount
    )
    let riskLevel = reuseRiskLevel(for: riskItems)
    var checklistItems = [
      "确认标题、slug 和摘要符合 \(targetProfile.name) 的站点语境。",
      "确认目标发布路径 `\(targetMarkdownPath)` 不会覆盖已有文章。",
      "发布前重新运行 SEO、隐私、链接和部署检查。"
    ]

    if sourceProfile?.siteKind != targetProfile.siteKind {
      let sourceKind = sourceProfile?.siteKind.rawValue ?? "unknown"
      checklistItems.insert(
        "来源站点类型为 \(sourceKind)，目标为 \(targetProfile.siteKind.rawValue)，需要重查 front matter、日期路径和分类字段。",
        at: 2
      )
    }
    if !(sourceDraft.repositoryPath?.trimmedForPublishing.isEmpty ?? true) {
      checklistItems.append("原路径只作为参考，不要直接复用到目标仓库。")
    }
    if !copiedDraft.attachments.isEmpty {
      checklistItems.append("逐个确认附件路径、alt、caption 和目标站点静态资源目录。")
    }
    if missingAltTextCount > 0 {
      checklistItems.append("补齐 \(missingAltTextCount) 个附件的 alt 文本。")
    }
    if missingCaptionCount > 0 {
      checklistItems.append("补齐 \(missingCaptionCount) 个附件的 caption。")
    }

    let sourceFieldDiffs = sourceFieldDiffs(from: sourceDraft, to: copiedDraft)

    return GeneralDraftReusePlan(
      sourceDraftID: sourceDraft.id,
      targetDraftID: copiedDraft.id,
      title: copiedDraft.title.nilIfEmpty ?? "复用草稿",
      sourceProfileName: sourceProfileName,
      targetProfileName: targetProfile.name,
      targetMarkdownPath: targetMarkdownPath,
      sourceRepositoryPath: sourceDraft.repositoryPath,
      targetSiteKind: targetProfile.siteKind,
      attachmentCount: copiedDraft.attachments.count,
      missingAltTextCount: missingAltTextCount,
      missingCaptionCount: missingCaptionCount,
      riskLevel: riskLevel,
      riskItems: riskItems,
      sourceFieldDiffs: sourceFieldDiffs,
      checklistItems: checklistItems,
      generatedAt: now
    )
  }

  public func sourceFieldDiffs(
    from sourceSnapshot: GeneralDraftReuseSourceSnapshot,
    to copiedDraft: ArticleDraft
  ) -> [String] {
    let sourceDraft = ArticleDraft(
      id: sourceSnapshot.draftID,
      siteProfileID: copiedDraft.siteProfileID,
      title: sourceSnapshot.title,
      date: sourceSnapshot.capturedAt,
      slug: sourceSnapshot.slug,
      tags: sourceSnapshot.tags,
      categories: sourceSnapshot.categories,
      draft: sourceSnapshot.draft,
      summary: sourceSnapshot.summary,
      bodyMarkdown: sourceSnapshot.bodyMarkdown,
      status: sourceSnapshot.status,
      createdAt: sourceSnapshot.capturedAt,
      updatedAt: sourceSnapshot.capturedAt,
      repositoryPath: sourceSnapshot.repositoryPath
    )
    return sourceFieldDiffs(from: sourceDraft, to: copiedDraft)
  }

  private func sourceFieldDiffs(
    from sourceDraft: ArticleDraft,
    to copiedDraft: ArticleDraft
  ) -> [String] {
    var diffs: [String] = []

    let sourceTitle = sourceDraft.title.nilIfEmpty ?? "未命名草稿"
    let targetTitle = copiedDraft.title.nilIfEmpty ?? "未命名草稿"
    if sourceTitle != targetTitle {
      diffs.append("标题：\"\(sourceTitle)\" -> \"\(targetTitle)\"")
    }

    let sourceSlug = sourceDraft.slug.nilIfEmpty ?? "未设置"
    let targetSlug = copiedDraft.slug.nilIfEmpty ?? "未设置"
    if sourceSlug != targetSlug {
      diffs.append("Slug：\"\(sourceSlug)\" -> \"\(targetSlug)\"")
    }

    let sourceSummary = sourceDraft.summary.nilIfEmpty ?? "未设置"
    let targetSummary = copiedDraft.summary.nilIfEmpty ?? "未设置"
    if sourceSummary != targetSummary {
      diffs.append("摘要：\"\(sourceSummary)\" -> \"\(targetSummary)\"")
    }

    if sourceDraft.tags.sorted() != copiedDraft.tags.sorted() {
      let from = sourceDraft.tags.filter { !$0.trimmedForPublishing.isEmpty }.joined(separator: "、")
      let to = copiedDraft.tags.filter { !$0.trimmedForPublishing.isEmpty }.joined(separator: "、")
      diffs.append("标签：\(from.isEmpty ? "未设置" : from) -> \(to.isEmpty ? "未设置" : to)")
    }

    if sourceDraft.categories.sorted() != copiedDraft.categories.sorted() {
      let from = sourceDraft.categories.filter { !$0.trimmedForPublishing.isEmpty }.joined(separator: "、")
      let to = copiedDraft.categories.filter { !$0.trimmedForPublishing.isEmpty }.joined(separator: "、")
      diffs.append("分类：\(from.isEmpty ? "未设置" : from) -> \(to.isEmpty ? "未设置" : to)")
    }

    if sourceDraft.draft != copiedDraft.draft {
      diffs.append("发布状态：\(sourceDraft.draft ? "草稿" : "已发布") -> \(copiedDraft.draft ? "草稿" : "已发布")")
    }

    if sourceDraft.bodyMarkdown.count != copiedDraft.bodyMarkdown.count {
      diffs.append("正文长度：\(sourceDraft.bodyMarkdown.count) -> \(copiedDraft.bodyMarkdown.count)")
    }

    return diffs
  }

  private func reuseRiskItems(
    sourceDraft: ArticleDraft,
    copiedDraft: ArticleDraft,
    sourceProfile: SiteProfile?,
    targetProfile: SiteProfile,
    targetMarkdownPath: String,
    missingAltTextCount: Int,
    missingCaptionCount: Int
  ) -> [String] {
    var items: [String] = []

    if sourceProfile?.siteKind != nil, sourceProfile?.siteKind != targetProfile.siteKind {
      let sourceKind = sourceProfile?.siteKind.rawValue ?? "unknown"
      items.append("站点类型从 \(sourceKind) 变为 \(targetProfile.siteKind.rawValue)，需要重查 front matter、日期路径和分类字段。")
    }
    if let sourcePath = sourceDraft.repositoryPath?.trimmedForPublishing.nilIfEmpty {
      items.append("来源草稿已绑定发布路径 \(sourcePath)，复制后不要复用原仓库路径。")
    }
    if copiedDraft.summary.trimmedForPublishing.isEmpty {
      items.append("目标草稿缺少摘要，发布前需要补齐 meta description / 社交分享摘要。")
    }
    if copiedDraft.slug.trimmedForPublishing.isEmpty {
      items.append("目标草稿缺少 slug，当前建议路径 \(targetMarkdownPath) 可能不稳定。")
    }
    if copiedDraft.tags.isEmpty && copiedDraft.categories.isEmpty {
      items.append("目标草稿没有标签或分类，跨站发布前需要补上下文归档。")
    }
    if copiedDraft.bodyMarkdown.contains("](/") {
      items.append("正文包含站内绝对链接，复制到目标站点后需要逐条确认目标路径存在。")
    }
    if copiedDraft.bodyMarkdown.localizedCaseInsensitiveContains("TODO")
      || copiedDraft.bodyMarkdown.localizedCaseInsensitiveContains("待确认") {
      items.append("正文仍有 TODO 或待确认标记，不能直接进入发布队列。")
    }
    if missingAltTextCount > 0 {
      items.append("有 \(missingAltTextCount) 个附件缺少 alt 文本。")
    }
    if missingCaptionCount > 0 {
      items.append("有 \(missingCaptionCount) 个附件缺少 caption。")
    }
    if copiedDraft.attachments.contains(where: { !$0.repositoryPath.trimmedForPublishing.isEmpty }) {
      items.append("附件带有原仓库路径，复用到目标站点前需要确认静态资源目录。")
    }

    if items.isEmpty {
      items.append("没有发现明显跨站复用风险；仍需按发布前检查确认目标站点语境。")
    }
    return items
  }

  private func reuseRiskLevel(for riskItems: [String]) -> GeneralDraftReuseRiskLevel {
    if riskItems.contains(where: { item in
      item.contains("站点类型")
        || item.contains("已绑定发布路径")
        || item.contains("站内绝对链接")
        || item.contains("TODO")
        || item.contains("待确认")
    }) {
      return .high
    }
    if riskItems.contains(where: { !$0.contains("没有发现明显跨站复用风险") }) {
      return .review
    }
    return .ready
  }
}
