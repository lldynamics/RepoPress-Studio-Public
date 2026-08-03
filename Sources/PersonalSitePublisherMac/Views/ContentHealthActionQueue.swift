import Foundation
import PublishingWorkbenchCore

enum ContentHealthArticleGrouping: String, CaseIterable, Identifiable, Sendable {
  case actionQueue
  case automaticFix
  case site
  case file

  var id: String { rawValue }

  static var visibleCases: [Self] {
    allCases.filter {
      DistributionFeaturePolicy.allowsExternalAIProviders || $0 != .automaticFix
    }
  }

  var title: String {
    switch self {
    case .actionQueue: String(localized: "行动队列")
    case .automaticFix: String(localized: "按处理方式")
    case .site: String(localized: "按站点")
    case .file: String(localized: "按文件")
    }
  }

  var systemImage: String {
    switch self {
    case .actionQueue: "list.bullet.clipboard"
    case .automaticFix: "wand.and.stars"
    case .site: "globe"
    case .file: "doc.text"
    }
  }

  func groups(
    rows: [ContentHealthArticleRowModel],
    profileName: String,
    duplicateMarkdownPaths: Set<String>
  ) -> [ContentHealthArticleGroup] {
    switch self {
    case .actionQueue:
      return ContentHealthActionQueue(
        rows: rows,
        duplicateMarkdownPaths: duplicateMarkdownPaths
      ).groups
    case .automaticFix:
      let automaticRows = rows.filter { $0.aiFixItem != nil }
      let manualRows = rows.filter { $0.aiFixItem == nil }
      return [
        ContentHealthArticleGroup(
          id: "automatic",
          title: String(localized: "可用 AI 修复"),
          systemImage: "sparkles",
          rows: automaticRows
        ),
        ContentHealthArticleGroup(
          id: "manual",
          title: String(localized: "需要手动处理"),
          systemImage: "hand.raised",
          rows: manualRows
        ),
      ].filter { !$0.rows.isEmpty }
    case .site:
      return [ContentHealthArticleGroup(
        id: "site",
        title: profileName,
        systemImage: "globe",
        rows: rows
      )]
    case .file:
      return rows.map { row in
        ContentHealthArticleGroup(
          id: row.draftID.uuidString,
          title: row.markdownPath,
          systemImage: "doc.text",
          rows: [row]
        )
      }
    }
  }
}

enum ContentHealthArticleGroupKind: Equatable, Sendable {
  case standard
  case blocking
  case highestRisk
  case automaticFix
  case suggestion

  var isActionQueue: Bool { self != .standard }
}

struct ContentHealthArticleGroup: Identifiable, Sendable {
  let id: String
  let title: String
  let systemImage: String
  let rows: [ContentHealthArticleRowModel]
  let kind: ContentHealthArticleGroupKind
  let detail: String?
  let totalCount: Int
  let prioritizedCount: Int

  init(
    id: String,
    title: String,
    systemImage: String,
    rows: [ContentHealthArticleRowModel],
    kind: ContentHealthArticleGroupKind = .standard,
    detail: String? = nil,
    totalCount: Int? = nil,
    prioritizedCount: Int = 0
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.rows = rows
    self.kind = kind
    self.detail = detail
    self.totalCount = totalCount ?? rows.count
    self.prioritizedCount = prioritizedCount
  }
}

struct ContentHealthArticleRowModel: Identifiable, Sendable {
  let draftID: UUID
  let draftTitle: String
  let markdownPath: String
  let issues: [PreflightIssue]
  let errorCount: Int
  let warningCount: Int
  let aiFixItem: AIPublishingFixQueueItem?

  var id: UUID { draftID }
  var normalizedMarkdownPath: String { markdownPath.normalizedRelativePath() }
  var publicRiskIssueCount: Int { issues.filter(\.isPublicRiskIssue).count }

  init(
    summary: DraftPreflightSummary,
    issues: [PreflightIssue],
    aiFixItem: AIPublishingFixQueueItem?
  ) {
    var errorCount = 0
    var warningCount = 0
    for issue in issues {
      switch issue.severity {
      case .error:
        errorCount += 1
      case .warning:
        warningCount += 1
      case .info:
        break
      }
    }

    draftID = summary.draftID
    draftTitle = summary.draftTitle
    markdownPath = summary.markdownPath
    self.issues = issues
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.aiFixItem = aiFixItem
  }
}

struct ContentHealthActionQueue: Sendable {
  static let highestRiskLimit = 10

  let blockingRows: [ContentHealthArticleRowModel]
  let highestRiskRows: [ContentHealthArticleRowModel]
  let automaticFixRows: [ContentHealthArticleRowModel]
  let suggestionRows: [ContentHealthArticleRowModel]
  let automaticFixTotalCount: Int
  let prioritizedAutomaticFixCount: Int

  init(
    rows: [ContentHealthArticleRowModel],
    duplicateMarkdownPaths: Set<String>
  ) {
    let sortedRows = rows.sorted {
      Self.isHigherRisk(
        $0,
        than: $1,
        duplicateMarkdownPaths: duplicateMarkdownPaths
      )
    }
    let blockingRows = sortedRows.filter { $0.errorCount > 0 }
    let nonBlockingRows = sortedRows.filter { $0.errorCount == 0 }
    let highestRiskRows = Array(nonBlockingRows.prefix(Self.highestRiskLimit))
    let prioritizedIDs = Set((blockingRows + highestRiskRows).map(\.draftID))
    let remainingRows = nonBlockingRows.filter { !prioritizedIDs.contains($0.draftID) }
    let automaticFixRows = remainingRows
      .filter { $0.aiFixItem != nil }
      .sorted(by: Self.isHigherAIFixPriority)
    let automaticFixIDs = Set(automaticFixRows.map(\.draftID))
    let suggestionRows = remainingRows.filter { !automaticFixIDs.contains($0.draftID) }
    let automaticFixTotalCount = rows.filter { $0.aiFixItem != nil }.count

    self.blockingRows = blockingRows
    self.highestRiskRows = highestRiskRows
    self.automaticFixRows = automaticFixRows
    self.suggestionRows = suggestionRows
    self.automaticFixTotalCount = automaticFixTotalCount
    prioritizedAutomaticFixCount = automaticFixTotalCount - automaticFixRows.count
  }

  var groups: [ContentHealthArticleGroup] {
    [
      ContentHealthArticleGroup(
        id: "action-blocking",
        title: String(localized: "阻止发布的问题"),
        systemImage: "xmark.octagon.fill",
        rows: blockingRows,
        kind: .blocking,
        detail: String(localized: "先处理错误；这些文章当前不能安全发布。")
      ),
      ContentHealthArticleGroup(
        id: "action-highest-risk",
        title: String(localized: "风险最高的 10 项"),
        systemImage: "exclamationmark.triangle.fill",
        rows: highestRiskRows,
        kind: .highestRisk,
        detail: String(localized: "按公开风险、路径冲突和问题数量排序。")
      ),
      ContentHealthArticleGroup(
        id: "action-automatic-fix",
        title: String(localized: "可批量自动修复项"),
        systemImage: "sparkles.rectangle.stack",
        rows: automaticFixRows,
        kind: .automaticFix,
        detail: String(localized: "可由 AI 协助补全摘要、标签与 Front Matter，结果仍需逐项预览。"),
        totalCount: automaticFixTotalCount,
        prioritizedCount: prioritizedAutomaticFixCount
      ),
      ContentHealthArticleGroup(
        id: "action-suggestions",
        title: String(localized: "普通内容建议"),
        systemImage: "lightbulb",
        rows: suggestionRows,
        kind: .suggestion,
        detail: String(localized: "不阻止发布，可在高优先级问题清空后处理。")
      ),
    ].filter { group in
      !group.rows.isEmpty || group.totalCount > 0
    }
  }

  private static func isHigherRisk(
    _ lhs: ContentHealthArticleRowModel,
    than rhs: ContentHealthArticleRowModel,
    duplicateMarkdownPaths: Set<String>
  ) -> Bool {
    if lhs.errorCount != rhs.errorCount {
      return lhs.errorCount > rhs.errorCount
    }
    if lhs.publicRiskIssueCount != rhs.publicRiskIssueCount {
      return lhs.publicRiskIssueCount > rhs.publicRiskIssueCount
    }
    let lhsHasDuplicatePath = duplicateMarkdownPaths.contains(lhs.normalizedMarkdownPath)
    let rhsHasDuplicatePath = duplicateMarkdownPaths.contains(rhs.normalizedMarkdownPath)
    if lhsHasDuplicatePath != rhsHasDuplicatePath {
      return lhsHasDuplicatePath
    }
    if lhs.warningCount != rhs.warningCount {
      return lhs.warningCount > rhs.warningCount
    }
    let titleComparison = lhs.draftTitle.localizedStandardCompare(rhs.draftTitle)
    if titleComparison != .orderedSame {
      return titleComparison == .orderedAscending
    }
    return lhs.draftID.uuidString < rhs.draftID.uuidString
  }

  private static func isHigherAIFixPriority(
    _ lhs: ContentHealthArticleRowModel,
    than rhs: ContentHealthArticleRowModel
  ) -> Bool {
    guard let lhsItem = lhs.aiFixItem, let rhsItem = rhs.aiFixItem else {
      return lhs.aiFixItem != nil
    }
    if lhsItem.priority != rhsItem.priority {
      return lhsItem.priority < rhsItem.priority
    }
    if lhsItem.frontMatterIssueCount != rhsItem.frontMatterIssueCount {
      return lhsItem.frontMatterIssueCount > rhsItem.frontMatterIssueCount
    }
    return lhs.draftTitle.localizedStandardCompare(rhs.draftTitle) == .orderedAscending
  }
}

enum ContentHealthLayoutMetrics {
  static let regularHeaderMinimumPrimaryWidth: CGFloat = 1_040

  static func usesCompactHeader(
    availableWidth: CGFloat,
    usesSplitLayout: Bool
  ) -> Bool {
    let pageWidth = max(
      0,
      availableWidth - WorkbenchPageMetrics.horizontalPadding * 2
    )
    let primaryWidth = usesSplitLayout
      ? max(
          0,
          pageWidth - WorkbenchPageMetrics.operationalContextWidth - 16
        )
      : pageWidth
    return primaryWidth < regularHeaderMinimumPrimaryWidth
  }
}
