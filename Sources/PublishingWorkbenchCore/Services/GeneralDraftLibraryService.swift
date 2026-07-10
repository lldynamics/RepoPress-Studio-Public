import Foundation

public struct GeneralDraftLibraryReport: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var totalDraftCount: Int
  public var generalDraftCount: Int
  public var crossSiteCandidateCount: Int
  public var attachmentCount: Int
  public var generalProfileCount: Int
  public var publishingProfileCount: Int
  public var tagSummaries: [GeneralDraftLabelSummary]
  public var categorySummaries: [GeneralDraftLabelSummary]
  public var items: [GeneralDraftLibraryItem]
  public var assets: [CrossSiteAssetItem]

  public init(
    generatedAt: Date,
    totalDraftCount: Int,
    generalDraftCount: Int,
    crossSiteCandidateCount: Int,
    attachmentCount: Int,
    generalProfileCount: Int,
    publishingProfileCount: Int,
    tagSummaries: [GeneralDraftLabelSummary],
    categorySummaries: [GeneralDraftLabelSummary],
    items: [GeneralDraftLibraryItem],
    assets: [CrossSiteAssetItem]
  ) {
    self.generatedAt = generatedAt
    self.totalDraftCount = totalDraftCount
    self.generalDraftCount = generalDraftCount
    self.crossSiteCandidateCount = crossSiteCandidateCount
    self.attachmentCount = attachmentCount
    self.generalProfileCount = generalProfileCount
    self.publishingProfileCount = publishingProfileCount
    self.tagSummaries = tagSummaries
    self.categorySummaries = categorySummaries
    self.items = items
    self.assets = assets
  }
}

public extension GeneralDraftLibraryReport {
  var distributionChecklistMarkdown: String {
    let formatter = ISO8601DateFormatter()
    let reusableCandidates = items.filter { $0.reuseStatus == .reusableCandidate }
    let libraryDrafts = items.filter { $0.reuseStatus == .libraryDraft }
    let siteSpecificDrafts = items.filter { $0.reuseStatus == .siteSpecific }
    var lines: [String] = [
      "# 素材分发清单",
      "",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 通用素材：\(generalDraftCount)",
      "- 待收进素材库候选：\(crossSiteCandidateCount)",
      "- 附件素材：\(attachmentCount)",
      "- 发布站点：\(publishingProfileCount)",
      "- 标签维度：\(tagSummaries.map { "\($0.label)（\($0.draftCount)）" }.joined(separator: "、"))",
      "- 分类维度：\(categorySummaries.map { "\($0.label)（\($0.draftCount)）" }.joined(separator: "、"))",
      ""
    ]

    lines.append("## 优先分发候选")
    if reusableCandidates.isEmpty {
      lines.append("")
      lines.append("当前没有从发布站点识别出的未发布复用候选。")
    } else {
      lines.append("")
      for item in reusableCandidates.prefix(10) {
        appendDistributionItem(item, action: "先收进素材库，再复制到目标站点", to: &lines)
      }
    }

    lines.append("")
    lines.append("## 素材库")
    if libraryDrafts.isEmpty {
      lines.append("")
      lines.append("素材库还没有可直接分发的草稿。")
    } else {
      lines.append("")
      for item in libraryDrafts.prefix(10) {
        appendDistributionItem(item, action: "复制到目标站点后重查站点语境", to: &lines)
      }
    }

    if !siteSpecificDrafts.isEmpty {
      lines.append("")
      lines.append("## 暂缓复用")
      lines.append("")
      for item in siteSpecificDrafts.prefix(6) {
        appendDistributionItem(item, action: "仅在确认跨站点边界后复制为新草稿", to: &lines)
      }
    }

    lines.append("")
    lines.append("## 附件分发")
    if assets.isEmpty {
      lines.append("")
      lines.append("当前没有附件素材需要跨站点处理。")
    } else {
      lines.append("")
      for asset in assets.prefix(10) {
        lines.append("- \(asset.originalFilename)")
        lines.append("  - 来源：\(asset.profileName) / \(asset.draftTitle)")
        lines.append("  - 路径：\(asset.repositoryPath.trimmedForPublishing.nilIfEmpty ?? asset.relativePublishPath)")
        var followUps: [String] = []
        if asset.isMissingAltText {
          followUps.append("补 alt")
        }
        if asset.isMissingCaption {
          followUps.append("补 caption")
        }
        lines.append("  - 处理：\(followUps.isEmpty ? "确认目标站点静态资源路径" : followUps.joined(separator: "、"))")
      }
    }

    lines.append("")
    lines.append("## 发布前执行")
    lines.append("- [ ] 把发布站点里的可复用候选收进素材库，保留来源草稿不动。")
    lines.append("- [ ] 从素材库复制到目标站点，并生成跨站点复用计划。")
    lines.append("- [ ] 如需改写，把复用计划发送到 AI 对话页，带上目标站点语境。")
    lines.append("- [ ] 重查 front matter、slug、分类、内链、图片路径、alt 和 caption。")
    lines.append("- [ ] 发布前运行 SEO、隐私、链接、图片和部署检查。")
    lines.append("- [ ] 备份素材库。")

    return lines.joined(separator: "\n")
  }

  var crossSiteMaterialPackageMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 跨站点素材包",
      "",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 全部草稿：\(totalDraftCount)",
      "- 通用素材：\(generalDraftCount)",
      "- 复用候选：\(crossSiteCandidateCount)",
      "- 附件素材：\(attachmentCount)",
      "- 发布站点：\(publishingProfileCount)",
      "- 标签维度：\(tagSummaries.map { "\($0.label)（\($0.draftCount)）" }.joined(separator: "、"))",
      "- 分类维度：\(categorySummaries.map { "\($0.label)（\($0.draftCount)）" }.joined(separator: "、"))",
      ""
    ]

    lines.append("## 复用队列")
    if items.isEmpty {
      lines.append("")
      lines.append("当前没有可复用素材。")
    } else {
      lines.append("")
      for item in items.prefix(20) {
        lines.append("- [\(item.reuseStatus.displayName)] \(item.title)")
        lines.append("  - Profile：\(item.profileName)")
        lines.append("  - Slug：\(item.slug.trimmedForPublishing.nilIfEmpty ?? "未设置")")
        lines.append("  - 摘要：\(item.summary.trimmedForPublishing.nilIfEmpty ?? item.reuseReason)")
        if !item.tags.isEmpty {
          lines.append("  - 标签：\(item.tags.joined(separator: "、"))")
        }
        if !item.categories.isEmpty {
          lines.append("  - 分类：\(item.categories.joined(separator: "、"))")
        }
        lines.append("  - 检查：\(item.reuseReason)")
      }
    }

    lines.append("")
    lines.append("## 附件素材")
    if assets.isEmpty {
      lines.append("")
      lines.append("当前没有附件素材。")
    } else {
      lines.append("")
      for asset in assets.prefix(20) {
        lines.append("- \(asset.originalFilename)")
        lines.append("  - 来源：\(asset.profileName) / \(asset.draftTitle)")
        lines.append("  - 路径：\(asset.repositoryPath.trimmedForPublishing.nilIfEmpty ?? asset.relativePublishPath)")
        lines.append("  - 大小：\(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))")
        if asset.isMissingAltText || asset.isMissingCaption {
          var missing: [String] = []
          if asset.isMissingAltText {
            missing.append("alt")
          }
          if asset.isMissingCaption {
            missing.append("caption")
          }
          lines.append("  - 待补：\(missing.joined(separator: "、"))")
        }
      }
    }

    lines.append("")
    lines.append("## 工作流")
    lines.append("- [ ] 把可复用候选先收进素材库，保留原站点草稿。")
    lines.append("- [ ] 复制到目标站点后重查 front matter、slug、分类、内链和图片路径。")
    lines.append("- [ ] 发布前运行 SEO、隐私、链接、图片和部署检查。")
    lines.append("- [ ] 备份素材库并提交到备份仓库。")

    return lines.joined(separator: "\n")
  }

  private func appendDistributionItem(
    _ item: GeneralDraftLibraryItem,
    action: String,
    to lines: inout [String]
  ) {
    lines.append("- [\(item.reuseStatus.displayName)] \(item.title)")
    lines.append("  - 来源：\(item.profileName)")
    lines.append("  - Slug：\(item.slug.trimmedForPublishing.nilIfEmpty ?? "未设置")")
    lines.append("  - 动作：\(action)")
    lines.append("  - 检查：\(item.reuseReason)")
    if !item.summary.trimmedForPublishing.isEmpty {
      lines.append("  - 摘要：\(item.summary)")
    }
    if !item.tags.isEmpty {
      lines.append("  - 标签：\(item.tags.joined(separator: "、"))")
    }
    if !item.categories.isEmpty {
      lines.append("  - 分类：\(item.categories.joined(separator: "、"))")
    }
    if item.attachmentCount > 0 {
      lines.append("  - 附件：\(item.attachmentCount) 个，分发前重查路径、alt 和 caption")
    }
  }
}

public struct GeneralDraftLibraryItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var profileID: UUID
  public var profileName: String
  public var profilePurpose: SiteProfilePurpose
  public var title: String
  public var slug: String
  public var summary: String
  public var tags: [String]
  public var categories: [String]
  public var updatedAt: Date
  public var bodyCharacterCount: Int
  public var attachmentCount: Int
  public var reuseStatus: GeneralDraftReuseStatus
  public var sourceDraftID: UUID?
  public var sourceProfileName: String?
  public var reuseReason: String

  public init(
    id: UUID,
    draftID: UUID,
    profileID: UUID,
    profileName: String,
    profilePurpose: SiteProfilePurpose,
    title: String,
    slug: String,
    summary: String,
    tags: [String],
    categories: [String],
    updatedAt: Date,
    bodyCharacterCount: Int,
    attachmentCount: Int,
    reuseStatus: GeneralDraftReuseStatus,
    sourceDraftID: UUID? = nil,
    sourceProfileName: String? = nil,
    reuseReason: String
  ) {
    self.id = id
    self.draftID = draftID
    self.profileID = profileID
    self.profileName = profileName
    self.profilePurpose = profilePurpose
    self.title = title
    self.slug = slug
    self.summary = summary
    self.tags = tags
    self.categories = categories
    self.updatedAt = updatedAt
    self.bodyCharacterCount = bodyCharacterCount
    self.attachmentCount = attachmentCount
    self.reuseStatus = reuseStatus
    self.sourceDraftID = sourceDraftID
    self.sourceProfileName = sourceProfileName
    self.reuseReason = reuseReason
  }
}

public struct GeneralDraftLabelSummary: Codable, Hashable, Sendable {
  public var label: String
  public var draftCount: Int

  public init(label: String, draftCount: Int) {
    self.label = label
    self.draftCount = draftCount
  }
}

public extension GeneralDraftLibraryItem {
  var reuseChecklistMarkdown: String {
    var lines = [
      "# 素材复用清单：\(title)",
      "",
      "- 来源 Profile：\(profileName)",
      "- 状态：\(reuseStatus.displayName)",
      "- Slug：\(slug.trimmedForPublishing.nilIfEmpty ?? "未设置")",
      "- 正文字数：\(bodyCharacterCount)",
      "- 附件数：\(attachmentCount)"
    ]

    if !summary.trimmedForPublishing.isEmpty {
      lines.append("- 摘要：\(summary)")
    }
    if !tags.isEmpty {
      lines.append("- 标签：\(tags.joined(separator: "、"))")
    }
    if !categories.isEmpty {
      lines.append("- 分类：\(categories.joined(separator: "、"))")
    }

    lines.append("")
    lines.append("## 复用前检查")
    switch reuseStatus {
    case .libraryDraft:
      lines.append("- [ ] 复制到目标站点后，按目标站点语境重查标题、slug、标签和分类。")
      lines.append("- [ ] 确认正文里的内链、图片路径和发布口吻适合目标站点。")
    case .reusableCandidate:
      lines.append("- [ ] 先收进素材库，保留原站点草稿不动。")
      lines.append("- [ ] 清理只属于原站点的路径、分类、附件引用和上下文。")
    case .siteSpecific:
      lines.append("- [ ] 先判断是否真的适合跨站点复用，避免把已发布路径直接搬到其他站点。")
      lines.append("- [ ] 如果复用，复制为新草稿后重设 repository path、slug 和发布状态。")
    }

    lines.append("- [ ] 发布前重新运行 SEO、隐私、链接和部署检查。")

    if attachmentCount > 0 {
      lines.append("")
      lines.append("## 附件处理")
      lines.append("- [ ] 确认附件是否允许跨站点复用。")
      lines.append("- [ ] 重新检查 alt、caption、相对路径和目标站点静态资源目录。")
    }

    return lines.joined(separator: "\n")
  }
}

public enum GeneralDraftReuseStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case libraryDraft
  case reusableCandidate
  case siteSpecific

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .libraryDraft:
      return "通用素材"
    case .reusableCandidate:
      return "可复用候选"
    case .siteSpecific:
      return "站点专用"
    }
  }

  public var systemImage: String {
    switch self {
    case .libraryDraft:
      return "tray.full"
    case .reusableCandidate:
      return "arrow.triangle.branch"
    case .siteSpecific:
      return "globe"
    }
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

public struct CrossSiteAssetItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var draftTitle: String
  public var profileID: UUID
  public var profileName: String
  public var originalFilename: String
  public var relativePublishPath: String
  public var repositoryPath: String
  public var byteSize: Int64
  public var isMissingAltText: Bool
  public var isMissingCaption: Bool

  public init(
    id: UUID,
    draftID: UUID,
    draftTitle: String,
    profileID: UUID,
    profileName: String,
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    byteSize: Int64,
    isMissingAltText: Bool,
    isMissingCaption: Bool
  ) {
    self.id = id
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.profileID = profileID
    self.profileName = profileName
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.byteSize = byteSize
    self.isMissingAltText = isMissingAltText
    self.isMissingCaption = isMissingCaption
  }
}

public struct GeneralDraftLibraryPackageEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var relativePath: String
  public var markdown: String

  public init(id: UUID, relativePath: String, markdown: String) {
    self.id = id
    self.relativePath = relativePath
    self.markdown = markdown
  }
}

public struct GeneralDraftLibraryPackagePlan: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var profileID: UUID?
  public var profileName: String
  public var files: [GeneralDraftBackupFile]
  public var manifestMarkdown: String
  public var statusMessage: String

  public init(
    generatedAt: Date,
    profileID: UUID?,
    profileName: String,
    files: [GeneralDraftBackupFile],
    manifestMarkdown: String,
    statusMessage: String
  ) {
    self.generatedAt = generatedAt
    self.profileID = profileID
    self.profileName = profileName
    self.files = files
    self.manifestMarkdown = manifestMarkdown
    self.statusMessage = statusMessage
  }

  public var isReady: Bool {
    !files.isEmpty
  }

  public var packageText: String {
    var sections: [String] = [manifestMarkdown]
    for file in files {
      sections.append(
        """
        <!-- path: \(file.relativePath) -->
        \(file.markdown)
        """
      )
    }
    return sections.joined(separator: "\n\n")
  }
}

public struct GeneralDraftBackupFile: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var title: String
  public var relativePath: String
  public var markdown: String
  public var byteCount: Int

  public init(
    id: UUID,
    draftID: UUID,
    title: String,
    relativePath: String,
    markdown: String,
    byteCount: Int
  ) {
    self.id = id
    self.draftID = draftID
    self.title = title
    self.relativePath = relativePath
    self.markdown = markdown
    self.byteCount = byteCount
  }
}

public struct GeneralDraftBackupPlan: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var profileID: UUID?
  public var profileName: String
  public var repositoryRootPath: String
  public var branch: String
  public var files: [GeneralDraftBackupFile]
  public var manifestMarkdown: String
  public var commandLines: [String]
  public var statusMessage: String

  public init(
    generatedAt: Date,
    profileID: UUID?,
    profileName: String,
    repositoryRootPath: String,
    branch: String,
    files: [GeneralDraftBackupFile],
    manifestMarkdown: String,
    commandLines: [String],
    statusMessage: String
  ) {
    self.generatedAt = generatedAt
    self.profileID = profileID
    self.profileName = profileName
    self.repositoryRootPath = repositoryRootPath
    self.branch = branch
    self.files = files
    self.manifestMarkdown = manifestMarkdown
    self.commandLines = commandLines
    self.statusMessage = statusMessage
  }

  public var isRepositoryConfigured: Bool {
    !repositoryRootPath.trimmedForPublishing.isEmpty
  }

  public var isReady: Bool {
    isRepositoryConfigured && !files.isEmpty
  }

  public var commandText: String {
    commandLines.joined(separator: "\n")
  }

  public var packageText: String {
    var sections: [String] = [manifestMarkdown]
    for file in files {
      sections.append(
        """
        <!-- path: \(file.relativePath) -->
        \(file.markdown)
        """
      )
    }
    return sections.joined(separator: "\n\n")
  }
}

public struct GeneralDraftBackupWriteResult: Codable, Hashable, Sendable {
  public var rootPath: String
  public var manifestPath: String
  public var writtenPaths: [String]
  public var deletedStalePaths: [String]

  public init(
    rootPath: String,
    manifestPath: String,
    writtenPaths: [String],
    deletedStalePaths: [String] = []
  ) {
    self.rootPath = rootPath
    self.manifestPath = manifestPath
    self.writtenPaths = writtenPaths
    self.deletedStalePaths = deletedStalePaths
  }

  public var totalWrittenFileCount: Int {
    writtenPaths.count + 1
  }

  public var statusMessage: String {
    if deletedStalePaths.isEmpty {
      return "已写入 \(writtenPaths.count) 篇通用素材和备份清单。"
    }
    return "已写入 \(writtenPaths.count) 篇通用素材和备份清单，并清理 \(deletedStalePaths.count) 个过期备份。"
  }
}

  public enum GeneralDraftBackupWriteError: LocalizedError, Equatable {
    case repositoryNotConfigured
    case emptyBackupPlan
    case invalidRelativePath(String)

  public var errorDescription: String? {
    switch self {
    case .repositoryNotConfigured:
      return "请先选择素材备份仓库。"
    case .emptyBackupPlan:
      return "素材库还没有可写入的备份文件。"
    case .invalidRelativePath(let path):
      return "备份路径无效：\(path)"
    }
  }
}

public struct GeneralDraftLibraryService {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func report(
    drafts: [ArticleDraft],
    profiles: [SiteProfile],
    now: Date = Date(),
    masksPrivateContent: Bool = false
  ) -> GeneralDraftLibraryReport {
    let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    let items = drafts.map { draft in
      item(
        for: draft,
        profile: profilesByID[draft.siteProfileID],
        masksPrivateContent: masksPrivateContent
      )
    }
    .sorted { left, right in
      if left.reuseStatus == right.reuseStatus {
        return left.updatedAt > right.updatedAt
      }
      return left.reuseStatus.sortRank < right.reuseStatus.sortRank
    }

    let assets = drafts.flatMap { draft in
      assetItems(
        for: draft,
        profile: profilesByID[draft.siteProfileID],
        masksPrivateContent: masksPrivateContent
      )
    }
    .sorted {
      if $0.profileName == $1.profileName {
        return $0.originalFilename.localizedCaseInsensitiveCompare($1.originalFilename) == .orderedAscending
      }
      return $0.profileName.localizedCaseInsensitiveCompare($1.profileName) == .orderedAscending
    }

    return GeneralDraftLibraryReport(
      generatedAt: now,
      totalDraftCount: drafts.count,
      generalDraftCount: items.filter { $0.reuseStatus == .libraryDraft }.count,
      crossSiteCandidateCount: items.filter { $0.reuseStatus == .reusableCandidate }.count,
      attachmentCount: assets.count,
      generalProfileCount: profiles.filter { $0.purpose == .generalDraftBackup }.count,
      publishingProfileCount: profiles.filter { $0.purpose == .publishing }.count,
      tagSummaries: labelSummaries(items.flatMap(\.tags)),
      categorySummaries: labelSummaries(items.flatMap(\.categories)),
      items: items,
      assets: assets
    )
  }

  private func labelSummaries(_ labels: [String]) -> [GeneralDraftLabelSummary] {
    let counts = labels.reduce(into: [String: Int]()) { result, label in
      guard let normalized = label.trimmedForPublishing.nilIfEmpty else {
        return
      }
      result[normalized, default: 0] += 1
    }
    return counts
      .map { GeneralDraftLabelSummary(label: $0.key, draftCount: $0.value) }
      .sorted {
        if $0.draftCount == $1.draftCount {
          return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        return $0.draftCount > $1.draftCount
      }
  }

  public func backupPlan(
    drafts: [ArticleDraft],
    profile: SiteProfile?,
    now: Date = Date()
  ) -> GeneralDraftBackupPlan {
    guard let profile, profile.purpose == .generalDraftBackup else {
      return GeneralDraftBackupPlan(
        generatedAt: now,
        profileID: profile?.id,
        profileName: profile?.name ?? "素材库",
        repositoryRootPath: profile?.localRepositoryRootPath ?? "",
        branch: profile?.branch.nilIfEmpty ?? "main",
        files: [],
        manifestMarkdown: "# 素材备份\n\n还没有素材库 Profile。\n",
        commandLines: [],
        statusMessage: "先创建素材库 Profile。"
      )
    }

    let libraryDrafts = drafts
      .filter { $0.siteProfileID == profile.id }
      .sorted {
        if $0.updatedAt == $1.updatedAt {
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return $0.updatedAt > $1.updatedAt
      }

    var usedPaths: Set<String> = []
    let renderer = FrontMatterRenderer()
    let files = libraryDrafts.map { draft in
      let relativePath = uniqueBackupPath(for: draft, usedPaths: &usedPaths)
      let markdown = renderer.renderDocument(draft: draft, profile: profile)
      return GeneralDraftBackupFile(
        id: draft.id,
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名草稿",
        relativePath: relativePath,
        markdown: markdown,
        byteCount: markdown.utf8.count
      )
    }

    let rootPath = profile.localRepositoryRootPath.trimmedForPublishing
    let branch = profile.branch.nilIfEmpty ?? "main"
    let manifest = manifestMarkdown(
      generatedAt: now,
      profile: profile,
      files: files
    )
    let commandLines = backupCommandLines(
      rootPath: rootPath,
      branch: branch,
      files: files
    )
    let statusMessage: String
    if files.isEmpty {
      statusMessage = "素材库还没有可备份的草稿。"
    } else if rootPath.isEmpty {
      statusMessage = "选择备份仓库后，可把 \(files.count) 篇通用素材写入仓库。"
    } else {
      statusMessage = "已准备 \(files.count) 篇通用素材的备份文件。"
    }

    return GeneralDraftBackupPlan(
      generatedAt: now,
      profileID: profile.id,
      profileName: profile.name,
      repositoryRootPath: rootPath,
      branch: branch,
      files: files,
      manifestMarkdown: manifest,
      commandLines: commandLines,
      statusMessage: statusMessage
    )
  }

  public func packagePlan(
    drafts: [ArticleDraft],
    profile: SiteProfile?,
    now: Date = Date()
  ) -> GeneralDraftLibraryPackagePlan {
    guard let profile, profile.purpose == .generalDraftBackup else {
      return GeneralDraftLibraryPackagePlan(
        generatedAt: now,
        profileID: profile?.id,
        profileName: profile?.name ?? "素材库",
        files: [],
        manifestMarkdown: "# 素材包\n\n请先创建素材库 Profile。\n",
        statusMessage: "先创建素材库 Profile。"
      )
    }

    let libraryDrafts = drafts
      .filter { $0.siteProfileID == profile.id }
      .sorted {
        if $0.updatedAt == $1.updatedAt {
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return $0.updatedAt > $1.updatedAt
      }

    var usedPaths: Set<String> = []
    let renderer = FrontMatterRenderer()
    let files = libraryDrafts.map { draft in
      let relativePath = uniqueBackupPath(for: draft, usedPaths: &usedPaths)
      let markdown = renderer.renderDocument(draft: draft, profile: profile)
      return GeneralDraftBackupFile(
        id: draft.id,
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名草稿",
        relativePath: relativePath,
        markdown: markdown,
        byteCount: markdown.utf8.count
      )
    }

    let manifest = packageManifestMarkdown(
      generatedAt: now,
      profile: profile,
      files: files
    )

    let statusMessage = files.isEmpty
      ? "素材库中没有可导出的草稿。"
      : "已生成 \(files.count) 篇素材导出包。"

    return GeneralDraftLibraryPackagePlan(
      generatedAt: now,
      profileID: profile.id,
      profileName: profile.name,
      files: files,
      manifestMarkdown: manifest,
      statusMessage: statusMessage
    )
  }

  public func parsePackageEntries(from packageText: String) -> [GeneralDraftLibraryPackageEntry] {
    let lines = packageText.components(separatedBy: .newlines)
    var entries: [GeneralDraftLibraryPackageEntry] = []
    var currentPath: String?
    var currentMarkdown: [String] = []

    func flushEntry() {
      guard let path = currentPath else {
        return
      }
      let markdown = currentMarkdown.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !markdown.isEmpty {
        entries.append(
          GeneralDraftLibraryPackageEntry(
            id: UUID(),
            relativePath: path,
            markdown: markdown
          )
        )
      }
    }

    for line in lines {
      if let path = parsePackagePathLine(line), let normalizedPath = safePackagePath(path) {
        flushEntry()
        currentPath = normalizedPath
        currentMarkdown = []
        continue
      }
      if currentPath != nil {
        currentMarkdown.append(line)
      }
    }

    flushEntry()
    return entries
  }

  public func draft(
    from packageEntry: GeneralDraftLibraryPackageEntry,
    profile: SiteProfile,
    now: Date = Date()
  ) -> ArticleDraft {
    let parsed = parseFrontMatter(packageEntry.markdown)
    let values = parsed.values
    let date = parsedDate(values["date"]?.first, profile: profile)
      ?? dateFromPath(packageEntry.relativePath)
      ?? now

    return ArticleDraft(
      siteProfileID: profile.id,
      title: values["title"]?.first?.nilIfEmpty ?? humanizedTitle(from: packageEntry.relativePath),
      date: date,
      slug: values["slug"]?.first?.nilIfEmpty ?? slugFromPath(packageEntry.relativePath),
      tags: values["tags"] ?? [],
      categories: values["categories"] ?? [],
      authors: values["authors"] ?? values["author"] ?? profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? [],
      draft: parsedBool(values["draft"]?.first) ?? true,
      summary: values["description"]?.first?.nilIfEmpty
        ?? values["summary"]?.first?.nilIfEmpty
        ?? values["excerpt"]?.first?.nilIfEmpty
        ?? "",
      bodyMarkdown: parsed.body,
      status: parsedBool(values["draft"]?.first) == false ? .published : .draft,
      createdAt: date,
      updatedAt: now,
      repositoryPath: packageEntry.relativePath,
      repositorySHA: nil
    )
  }

  private func packageManifestMarkdown(
    generatedAt: Date,
    profile: SiteProfile,
    files: [GeneralDraftBackupFile]
  ) -> String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 素材包",
      "",
      "- Profile：\(profile.name)",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 文件数：\(files.count)",
      ""
    ]

    if files.isEmpty {
      lines.append("当前没有可导出的通用素材。")
    } else {
      lines.append("## 文件")
      lines.append("")
      for file in files {
        lines.append("- `\(file.relativePath)`：\(file.title)（\(file.byteCount) bytes）")
      }
    }

    return lines.joined(separator: "\n") + "\n"
  }

  private func parsePackagePathLine(_ line: String) -> String? {
    let trimmed = line.trimmedForPublishing
    guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else {
      return nil
    }
    let marker = trimmed
      .dropFirst(4)
      .dropLast(3)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard marker.lowercased().hasPrefix("path:") else {
      return nil
    }
    return String(marker.dropFirst(5)).trimmedForPublishing.nilIfEmpty
  }

  private func safePackagePath(_ path: String) -> String? {
    let normalized = path.normalizedRelativePath()
    guard !normalized.isEmpty,
          !normalized.split(separator: "/").contains(".."),
          normalized.hasPrefix("general-drafts/"),
          normalized.hasSuffix(".md") else {
      return nil
    }
    return normalized
  }

  private func parseFrontMatter(_ markdown: String) -> (values: [String: [String]], body: String) {
    let lines = markdown.components(separatedBy: .newlines)
    guard let firstLine = lines.first else {
      return ([:], "")
    }
    let frontMatterDelimiter = firstLine.trimmedForPublishing

    if frontMatterDelimiter == "---" {
      return parseDelimitedFrontMatter(lines: lines, delimiter: "---", style: .yaml)
    }

    if frontMatterDelimiter == "+++" {
      return parseDelimitedFrontMatter(lines: lines, delimiter: "+++", style: .toml)
    }

    return ([:], markdown.trimmedForPublishing)
  }

  private enum GeneralDraftFrontMatterStyle {
    case yaml
    case toml
  }

  private func parseDelimitedFrontMatter(
    lines: [String],
    delimiter: String,
    style: GeneralDraftFrontMatterStyle
  ) -> (values: [String: [String]], body: String) {
    guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmedForPublishing == delimiter }) else {
      return ([:], lines.joined(separator: "\n").trimmedForPublishing)
    }

    let frontMatter = Array(lines[1..<closingIndex])
    let body = lines.dropFirst(closingIndex + 1).joined(separator: "\n").trimmedForPublishing
    let values: [String: [String]]

    switch style {
    case .yaml:
      values = parseYAMLFrontMatter(frontMatter)
    case .toml:
      values = parseTOMLFrontMatter(frontMatter)
    }

    return (values, body)
  }

  private func parseYAMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        index += 1
        continue
      }

      guard let separator = trimmed.firstIndex(of: ":") else {
        index += 1
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing

      if rawValue.isEmpty {
        var listValues: [String] = []
        var lookahead = index + 1
        while lookahead < lines.count {
          let item = lines[lookahead].trimmedForPublishing
          guard item.hasPrefix("- ") else {
            break
          }
          listValues.append(cleanScalar(String(item.dropFirst(2))))
          lookahead += 1
        }
        if !listValues.isEmpty {
          values[key] = listValues
          index = lookahead
          continue
        }
      } else {
        values[key] = parseScalarOrArray(rawValue)
      }

      index += 1
    }

    return values
  }

  private func parseTOMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]

    for line in lines {
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing
      values[key] = parseScalarOrArray(rawValue)
    }

    return values
  }

  private func parseScalarOrArray(_ rawValue: String) -> [String] {
    let value = rawValue.trimmedForPublishing
    if value.hasPrefix("[") && value.hasSuffix("]") {
      let inner = value.dropFirst().dropLast()
      return inner
        .split(separator: ",")
        .map { cleanScalar(String($0)) }
        .filter { !$0.isEmpty }
    }
    return [cleanScalar(value)].filter { !$0.isEmpty }
  }

  private func cleanScalar(_ value: String) -> String {
    value
      .trimmedForPublishing
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      .trimmedForPublishing
  }

  private func parsedDate(_ value: String?, profile: SiteProfile) -> Date? {
    guard let value = value?.nilIfEmpty else {
      return nil
    }
    if let date = ISO8601DateFormatter().date(from: value) {
      return date
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }
    return nil
  }

  private func dateFromPath(_ path: String) -> Date? {
    let components = path.split(separator: "/").map(String.init)
    let joined = components.joined(separator: "-")
    let pattern = #"(\d{4})[-/](\d{2})[-/](\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
          match.numberOfRanges == 4,
          let yearRange = Range(match.range(at: 1), in: joined),
          let monthRange = Range(match.range(at: 2), in: joined),
          let dayRange = Range(match.range(at: 3), in: joined) else {
      return nil
    }
    var componentsDate = DateComponents()
    componentsDate.calendar = Calendar(identifier: .gregorian)
    componentsDate.timeZone = TimeZone(secondsFromGMT: 0)
    componentsDate.year = Int(joined[yearRange])
    componentsDate.month = Int(joined[monthRange])
    componentsDate.day = Int(joined[dayRange])
    return componentsDate.date
  }

  private func humanizedTitle(from path: String) -> String {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let withoutDate = stem.replacingOccurrences(
      of: #"^\d{4}-\d{2}-\d{2}-"#,
      with: "",
      options: .regularExpression
    )
    return withoutDate
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmedForPublishing
      .nilIfEmpty ?? "通用素材"
  }

  private func slugFromPath(_ path: String) -> String {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let slug = stem.replacingOccurrences(
      of: #"^\d{4}-\d{2}-\d{2}-"#,
      with: "",
      options: .regularExpression
    )
    return slug.nilIfEmpty ?? SlugService.fallbackSlug()
  }

  private func parsedBool(_ value: String?) -> Bool? {
    switch value?.trimmedForPublishing.lowercased() {
    case "true", "yes", "1":
      return true
    case "false", "no", "0":
      return false
    default:
      return nil
    }
  }

  public func writeBackup(_ plan: GeneralDraftBackupPlan) throws -> GeneralDraftBackupWriteResult {
    let rootPath = plan.repositoryRootPath.trimmedForPublishing
    guard !rootPath.isEmpty else {
      throw GeneralDraftBackupWriteError.repositoryNotConfigured
    }
    guard !plan.files.isEmpty else {
      throw GeneralDraftBackupWriteError.emptyBackupPlan
    }

    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let manifestRelativePath = "general-drafts/MANIFEST.md"
    try write(plan.manifestMarkdown, relativePath: manifestRelativePath, rootURL: rootURL)

    var writtenPaths: [String] = []
    for file in plan.files {
      try write(file.markdown, relativePath: file.relativePath, rootURL: rootURL)
      writtenPaths.append(file.relativePath)
    }
    let deletedStalePaths = try deleteStaleBackupFiles(
      rootURL: rootURL,
      expectedPaths: Set(writtenPaths + [manifestRelativePath])
    )

    return GeneralDraftBackupWriteResult(
      rootPath: rootPath,
      manifestPath: manifestRelativePath,
      writtenPaths: writtenPaths,
      deletedStalePaths: deletedStalePaths
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
    let missingAltTextCount = copiedDraft.attachments.filter { $0.altText.trimmedForPublishing.isEmpty }.count
    let missingCaptionCount = copiedDraft.attachments.filter { $0.caption.trimmedForPublishing.isEmpty }.count
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

  private func item(
    for draft: ArticleDraft,
    profile: SiteProfile?,
    masksPrivateContent: Bool
  ) -> GeneralDraftLibraryItem {
    let profilePurpose = profile?.purpose ?? .publishing
    let reuseStatus = reuseStatus(for: draft, profilePurpose: profilePurpose)
    let shouldMask = masksPrivateContent && draft.isPrivate
    return GeneralDraftLibraryItem(
      id: draft.id,
      draftID: draft.id,
      profileID: draft.siteProfileID,
      profileName: profile?.name ?? "未知 Profile",
      profilePurpose: profilePurpose,
      title: shouldMask ? "私密文章" : draft.title.nilIfEmpty ?? "未命名草稿",
      slug: shouldMask ? "" : draft.slug,
      summary: shouldMask ? "内容已遮挡，打开文章或关闭私密遮挡后查看。" : draft.summary,
      tags: shouldMask ? [] : draft.tags,
      categories: shouldMask ? [] : draft.categories,
      updatedAt: draft.updatedAt,
      bodyCharacterCount: shouldMask ? 0 : draft.bodyMarkdown.count,
      attachmentCount: draft.attachments.count,
      reuseStatus: reuseStatus,
      sourceDraftID: draft.reusedFromSourceSnapshot?.draftID,
      sourceProfileName: draft.reusedFromSourceSnapshot?.sourceProfileName,
      reuseReason: shouldMask
        ? "私密内容遮挡已开启，跨站点复用前需先解锁或关闭遮挡后人工确认。"
        : reuseReason(for: draft, status: reuseStatus)
    )
  }

  private func reuseStatus(for draft: ArticleDraft, profilePurpose: SiteProfilePurpose) -> GeneralDraftReuseStatus {
    if profilePurpose == .generalDraftBackup {
      return .libraryDraft
    }
    if draft.status == .draft || draft.draft || draft.repositoryPath == nil {
      return .reusableCandidate
    }
    return .siteSpecific
  }

  private func reuseReason(for draft: ArticleDraft, status: GeneralDraftReuseStatus) -> String {
    switch status {
    case .libraryDraft:
      return "保存在素材库 Profile，可复制到任意站点继续发布。"
    case .reusableCandidate:
      if draft.repositoryPath == nil {
        return "还没有绑定仓库路径，适合先沉淀为跨站点素材。"
      }
      return "仍处于草稿状态，复制到其他站点前建议检查标题、slug 和图片路径。"
    case .siteSpecific:
      return "已经绑定站点发布路径，复用前需要确认站点上下文。"
    }
  }

  private func assetItems(
    for draft: ArticleDraft,
    profile: SiteProfile?,
    masksPrivateContent: Bool
  ) -> [CrossSiteAssetItem] {
    let shouldMask = masksPrivateContent && draft.isPrivate
    return draft.attachments.map { attachment in
      CrossSiteAssetItem(
        id: attachment.id,
        draftID: draft.id,
        draftTitle: shouldMask ? "私密文章" : draft.title.nilIfEmpty ?? "未命名草稿",
        profileID: draft.siteProfileID,
        profileName: profile?.name ?? "未知 Profile",
        originalFilename: shouldMask ? "私密附件" : attachment.originalFilename,
        relativePublishPath: shouldMask ? "内容已遮挡" : attachment.relativePublishPath,
        repositoryPath: shouldMask ? "内容已遮挡" : attachment.repositoryPath,
        byteSize: attachment.byteSize,
        isMissingAltText: attachment.altText.trimmedForPublishing.isEmpty,
        isMissingCaption: attachment.caption.trimmedForPublishing.isEmpty
      )
    }
  }

  private func uniqueBackupPath(for draft: ArticleDraft, usedPaths: inout Set<String>) -> String {
    let rawSlug = draft.slug.nilIfEmpty ?? SlugService.slug(from: draft.title.nilIfEmpty ?? "general-draft")
    let base = rawSlug
      .normalizedRelativePath()
      .replacingOccurrences(of: "/", with: "-")
      .nilIfEmpty ?? SlugService.fallbackSlug(date: draft.date)

    var candidate = "general-drafts/\(base).md"
    var suffix = 2
    while usedPaths.contains(candidate) {
      candidate = "general-drafts/\(base)-\(suffix).md"
      suffix += 1
    }
    usedPaths.insert(candidate)
    return candidate
  }

  private func manifestMarkdown(
    generatedAt: Date,
    profile: SiteProfile,
    files: [GeneralDraftBackupFile]
  ) -> String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 素材备份",
      "",
      "- Profile：\(profile.name)",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 文件数：\(files.count)",
      ""
    ]

    if files.isEmpty {
      lines.append("当前没有可备份的通用素材。")
    } else {
      lines.append("## 文件")
      lines.append("")
      for file in files {
        lines.append("- `\(file.relativePath)`：\(file.title)（\(file.byteCount) bytes）")
      }
    }

    return lines.joined(separator: "\n") + "\n"
  }

  private func backupCommandLines(
    rootPath: String,
    branch: String,
    files: [GeneralDraftBackupFile]
  ) -> [String] {
    guard !rootPath.isEmpty, !files.isEmpty else {
      return []
    }

    return [
      "cd \(posixShellQuote(rootPath))",
      "mkdir -p general-drafts",
      "# 将备份计划里的 Markdown 文件写入对应路径后执行：",
      "git status --short",
      "git add general-drafts",
      "git commit -m \(posixShellQuote("Back up general drafts"))",
      "git push origin \(posixShellQuote(branch))"
    ]
  }

  private func write(_ text: String, relativePath: String, rootURL: URL) throws {
    let safePath = try safeBackupRelativePath(relativePath)
    let url = rootURL.appendingPathComponent(safePath, isDirectory: false)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func deleteStaleBackupFiles(rootURL: URL, expectedPaths: Set<String>) throws -> [String] {
    let draftsURL = rootURL.appendingPathComponent("general-drafts", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: draftsURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return []
    }

    let urls = try fileManager.contentsOfDirectory(
      at: draftsURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var deletedPaths: [String] = []
    for url in urls {
      let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard resourceValues.isRegularFile == true,
            url.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame else {
        continue
      }

      let relativePath = "general-drafts/\(url.lastPathComponent)"
      guard relativePath != "general-drafts/MANIFEST.md",
            !expectedPaths.contains(relativePath) else {
        continue
      }

      try fileManager.removeItem(at: url)
      deletedPaths.append(relativePath)
    }
    return deletedPaths.sorted()
  }

  private func safeBackupRelativePath(_ path: String) throws -> String {
    let rawPath = path.trimmedForPublishing
    let components = rawPath.split(separator: "/").map(String.init)
    let normalized = rawPath.normalizedRelativePath()
    guard !rawPath.hasPrefix("/"),
          !components.contains(".."),
          !normalized.isEmpty,
          normalized.hasPrefix("general-drafts/") else {
      throw GeneralDraftBackupWriteError.invalidRelativePath(path)
    }
    return normalized
  }
}

private extension GeneralDraftReuseStatus {
  var sortRank: Int {
    switch self {
    case .libraryDraft:
      return 0
    case .reusableCandidate:
      return 1
    case .siteSpecific:
      return 2
    }
  }
}
