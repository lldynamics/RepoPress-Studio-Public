import Foundation

public struct SiteMaintenanceReport: Hashable, Sendable {
  public var profileID: UUID
  public var generatedAt: Date
  public var draftCount: Int
  public var publicDraftCount: Int
  public var privateDraftCount: Int
  public var readyCount: Int
  public var publishedCount: Int
  public var calendarBuckets: [ContentCalendarBucket]
  public var calendarInsights: [ContentCalendarInsight]
  public var calendarScheduleItems: [ContentCalendarScheduleItem]
  public var tagSummary: TaxonomyGovernanceSummary
  public var categorySummary: TaxonomyGovernanceSummary
  public var staleArticles: [StaleArticleCandidate]
  public var relationSuggestions: [SiteRelationSuggestion]
  public var linkAuditItems: [SiteLinkAuditItem]
  public var actionItems: [MaintenanceActionItem]
  public var operationLogEntries: [MaintenanceOperationLogEntry]
  public var contentPerformanceSummary: ContentPerformanceSummary
  public var healthSummary: SiteMaintenanceHealthSummary

  public var internalLinkIssueCount: Int {
    linkAuditItems.filter { $0.severity == .warning || $0.severity == .error }.count
  }

  public var internalLinkOpportunityCount: Int {
    relationSuggestions.count
  }
}

public struct ContentPerformanceSnapshot: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var profileID: UUID
  public var draftID: UUID?
  public var title: String
  public var markdownPath: String
  public var pageViews: Int
  public var visitors: Int
  public var sourceName: String
  public var capturedAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    draftID: UUID? = nil,
    title: String,
    markdownPath: String,
    pageViews: Int,
    visitors: Int,
    sourceName: String = "手动记录",
    capturedAt: Date = Date()
  ) {
    self.id = id
    self.profileID = profileID
    self.draftID = draftID
    self.title = title
    self.markdownPath = markdownPath
    self.pageViews = max(0, pageViews)
    self.visitors = max(0, visitors)
    self.sourceName = sourceName.trimmedForPublishing.nilIfEmpty ?? "手动记录"
    self.capturedAt = capturedAt
  }
}

public struct ContentPerformanceArticleSummary: Identifiable, Hashable, Sendable {
  public var id: String { draftID?.uuidString ?? markdownPath }
  public var draftID: UUID?
  public var title: String
  public var markdownPath: String
  public var pageViews: Int
  public var visitors: Int
  public var sourceName: String
  public var capturedAt: Date
}

public struct ContentPerformanceSummary: Hashable, Sendable {
  public var trackedArticleCount: Int
  public var totalPageViews: Int
  public var totalVisitors: Int
  public var latestCapturedAt: Date?
  public var topArticles: [ContentPerformanceArticleSummary]

  public var hasData: Bool {
    trackedArticleCount > 0
  }

  public static let empty = ContentPerformanceSummary(
    trackedArticleCount: 0,
    totalPageViews: 0,
    totalVisitors: 0,
    latestCapturedAt: nil,
    topArticles: []
  )
}

public extension SiteMaintenanceReport {
  var maintenanceSprintPlanMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 站点维护冲刺计划",
      "",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 健康状态：\(healthSummary.level.displayName)（\(healthSummary.score)/100）",
      "- 本轮目标：\(healthSummary.nextAction)",
      "- 高优先级：\(actionItems.filter { $0.priority == .high }.count)",
      "- 待发布：\(calendarScheduleItems.count)",
      "- 旧文候选：\(staleArticles.count)",
      "- 内链机会：\(relationSuggestions.count)",
      "- 链接风险：\(internalLinkIssueCount)",
      "- 表现追踪：\(contentPerformanceSummary.trackedArticleCount) 篇"
    ]

    lines.append("")
    lines.append("## 今日优先")
    let priorityItems = actionItems
      .filter { $0.priority == .high || $0.priority == .medium }
      .prefix(5)
    if priorityItems.isEmpty {
      lines.append("- [x] 当前没有高/中优先级维护任务。")
    } else {
      for item in priorityItems {
        lines.append("- [ ] [\(item.priority.displayName)] \(item.kind.displayName)：\(item.title)")
        lines.append("  - \(item.summary)")
        if let targetPath = item.targetPath?.trimmedForPublishing.nilIfEmpty {
          lines.append("  - 目标：\(targetPath)")
        }
        if item.draftID != nil {
          lines.append("  - 可操作：打开草稿，必要时交给 AI 生成修复草案。")
        }
      }
    }

    lines.append("")
    lines.append("## 本轮排期")
    if calendarScheduleItems.isEmpty {
      lines.append("- 当前没有公开待发布文章需要排期。")
    } else {
      for item in calendarScheduleItems.prefix(5) {
        lines.append("- [ ] \(formatterText(item.scheduledDate))：\(item.title)")
        lines.append("  - \(item.reason)")
        lines.append("  - \(item.markdownPath)")
      }
    }

    lines.append("")
    lines.append("## 旧文和链接")
    let staleSlice = staleArticles.prefix(4)
    if staleSlice.isEmpty {
      lines.append("- [x] 没有优先旧文整理项。")
    } else {
      for item in staleSlice {
        lines.append("- [ ] 复查旧文：\(item.title)")
        lines.append("  - \(item.markdownPath)")
        lines.append("  - \(item.reasons.joined(separator: "；"))")
      }
    }
    let linkIssues = linkAuditItems
      .filter { $0.severity == .warning || $0.severity == .error }
      .prefix(5)
    if linkIssues.isEmpty {
      lines.append("- [x] 没有高风险链接审计项。")
    } else {
      for item in linkIssues {
        lines.append("- [ ] [\(item.severity.displayName)] \(item.draftTitle)：\(item.target)")
        lines.append("  - \(item.message)")
      }
    }

    lines.append("")
    lines.append("## 内链机会")
    if relationSuggestions.isEmpty {
      lines.append("- 当前没有明显内链补充机会。")
    } else {
      for item in relationSuggestions.prefix(5) {
        lines.append("- [ ] \(item.sourceTitle) -> \(item.targetTitle)")
        lines.append("  - \(item.targetPath)")
        lines.append("  - \(item.reason)")
      }
    }

    lines.append("")
    lines.append("## 完成标准")
    lines.append("- [ ] 处理今日优先任务后，重新打开维护工作台确认健康分和行动队列变化。")
    lines.append("- [ ] 对改动过的文章重新生成 SEO / Social 快照并运行发布检查。")
    lines.append("- [ ] 发布后保留发布记录和部署校验结果，作为下次维护操作日志。")

    return lines.joined(separator: "\n")
  }

  var maintenanceChecklistMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 站点维护清单",
      "",
      "- 生成时间：\(formatter.string(from: generatedAt))",
      "- 文章：\(draftCount)",
      "- 公开：\(publicDraftCount)",
      "- 私密：\(privateDraftCount)",
      "- 待发布：\(readyCount)",
      "- 已发布：\(publishedCount)",
      "- 日历提示：\(calendarInsights.count)",
      "- 行动项：\(actionItems.count)",
      "- 链接提示：\(linkAuditItems.count)",
      "- 内链机会：\(relationSuggestions.count)",
      "- 健康分：\(healthSummary.score)/100",
      "- 健康等级：\(healthSummary.level.displayName)",
      "- 下一步：\(healthSummary.nextAction)"
    ]

    appendHealthSummary(to: &lines)
    appendActionItems(to: &lines)
    appendCalendar(to: &lines)
    appendCalendarInsights(to: &lines)
    appendCalendarSchedule(to: &lines)
    appendContentPerformance(to: &lines)
    appendTaxonomySummary(tagSummary, to: &lines)
    appendTaxonomySummary(categorySummary, to: &lines)
    appendStaleArticles(to: &lines)
    appendRelationSuggestions(to: &lines)
    appendLinkAudit(to: &lines)
    appendOperationLog(to: &lines)

    return lines.joined(separator: "\n")
  }

  private func appendHealthSummary(to lines: inout [String]) {
    lines.append("")
    lines.append("## 维护健康摘要")
    lines.append("- \(healthSummary.title)：\(healthSummary.message)")
    lines.append("- 下一步：\(healthSummary.nextAction)")
    if !healthSummary.drivers.isEmpty {
      lines.append("- 触发原因：\(healthSummary.drivers.joined(separator: "；"))")
    }
  }

  private func appendActionItems(to lines: inout [String]) {
    lines.append("")
    lines.append("## 维护行动队列")
    guard !actionItems.isEmpty else {
      lines.append("- 当前没有需要优先处理的维护事项。")
      return
    }

    for item in actionItems.prefix(12) {
      lines.append("- [\(item.priority.displayName)] \(item.kind.displayName)：\(item.title)")
      lines.append("  - \(item.summary)")
      if !item.detail.isEmpty {
        lines.append("  - \(item.detail)")
      }
    }
  }

  private func appendCalendar(to lines: inout [String]) {
    lines.append("")
    lines.append("## 内容日历")
    guard !calendarBuckets.isEmpty else {
      lines.append("- 当前 Profile 没有可统计的文章。")
      return
    }

    for bucket in calendarBuckets.prefix(12) {
      lines.append("- \(bucket.title)：\(bucket.articleCount) 篇，已发布 \(bucket.publishedCount)，待发布 \(bucket.readyCount)，公开 \(bucket.publicCount)，私密 \(bucket.privateCount)")
    }
  }

  private func appendCalendarInsights(to lines: inout [String]) {
    lines.append("")
    lines.append("## 内容节奏提示")
    guard !calendarInsights.isEmpty else {
      lines.append("- 当前内容节奏没有明显积压或断档。")
      return
    }

    for insight in calendarInsights {
      lines.append("- [\(insight.priority.displayName)] \(insight.title)：\(insight.summary)")
      if !insight.detail.isEmpty {
        lines.append("  - \(insight.detail)")
      }
    }
  }

  private func appendCalendarSchedule(to lines: inout [String]) {
    lines.append("")
    lines.append("## 待发布排期")
    guard !calendarScheduleItems.isEmpty else {
      lines.append("- 当前没有公开待发布文章需要排期。")
      return
    }

    for item in calendarScheduleItems {
      lines.append("- \(formatterText(item.scheduledDate))：\(item.title)")
      lines.append("  - \(item.reason)")
      lines.append("  - \(item.markdownPath)")
    }
  }

  private func appendContentPerformance(to lines: inout [String]) {
    lines.append("")
    lines.append("## 内容表现")
    guard contentPerformanceSummary.hasData else {
      lines.append("- 尚未接入或记录阅读量/访客数据。")
      return
    }

    lines.append("- 追踪文章：\(contentPerformanceSummary.trackedArticleCount)")
    lines.append("- 阅读量：\(contentPerformanceSummary.totalPageViews)")
    lines.append("- 访客：\(contentPerformanceSummary.totalVisitors)")
    for item in contentPerformanceSummary.topArticles.prefix(5) {
      lines.append("- \(item.title)：\(item.pageViews) 阅读 / \(item.visitors) 访客")
      lines.append("  - \(item.markdownPath)")
    }
  }

  private func appendTaxonomySummary(_ summary: TaxonomyGovernanceSummary, to lines: inout [String]) {
    lines.append("")
    lines.append("## \(summary.title)治理")
    lines.append("- 缺失：\(summary.missingCount)")
    lines.append("- 单篇\(summary.title)：\(summary.singletonCount)")
    if !summary.overloadedEntries.isEmpty {
      lines.append("- 高频\(summary.title)：\(summary.overloadedEntries.prefix(5).map(\.name).joined(separator: "、"))")
    }
    for entry in summary.entries.prefix(10) {
      lines.append("- \(entry.name)：\(entry.count) 篇")
    }
  }

  private func appendStaleArticles(to lines: inout [String]) {
    lines.append("")
    lines.append("## 旧文整理")
    guard !staleArticles.isEmpty else {
      lines.append("- 没有发现需要优先复查的旧文。")
      return
    }

    for item in staleArticles.prefix(10) {
      lines.append("- \(item.title)：\(item.markdownPath)")
      lines.append("  - \(item.reasons.joined(separator: "；"))")
    }
  }

  private func appendRelationSuggestions(to lines: inout [String]) {
    lines.append("")
    lines.append("## 文章关系 / 内链机会")
    guard !relationSuggestions.isEmpty else {
      lines.append("- 没有发现明显的内链补充机会。")
      return
    }

    for item in relationSuggestions.prefix(12) {
      lines.append("- \(item.sourceTitle) -> \(item.targetTitle)：\(item.targetPath)")
      lines.append("  - \(item.reason)")
    }
  }

  private func appendLinkAudit(to lines: inout [String]) {
    lines.append("")
    lines.append("## 链接审计")
    guard !linkAuditItems.isEmpty else {
      lines.append("- 当前文章链接没有发现明显治理项。")
      return
    }

    for item in linkAuditItems.prefix(12) {
      lines.append("- [\(item.severity.displayName)] \(item.draftTitle)：\(item.target)")
      lines.append("  - \(item.message)")
    }
  }

  private func appendOperationLog(to lines: inout [String]) {
    lines.append("")
    lines.append("## 操作日志")
    guard !operationLogEntries.isEmpty else {
      lines.append("- 还没有发布或维护操作记录。")
      return
    }

    for item in operationLogEntries.prefix(12) {
      lines.append("- \(formatterText(item.createdAt)) \(item.title)：\(item.summary)")
    }
  }

  private func formatterText(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

public struct ContentCalendarBucket: Identifiable, Hashable, Sendable {
  public var id: String { monthKey }
  public var monthKey: String
  public var title: String
  public var articleCount: Int
  public var draftCount: Int
  public var readyCount: Int
  public var publishedCount: Int
  public var publicCount: Int
  public var privateCount: Int
}

public struct ContentCalendarInsight: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var summary: String
  public var detail: String
  public var priority: MaintenanceActionPriority
  public var systemImage: String
}

public struct ContentCalendarScheduleItem: Identifiable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var title: String
  public var markdownPath: String
  public var scheduledDate: Date
  public var reason: String
  public var systemImage: String
}

public struct TaxonomyGovernanceSummary: Hashable, Sendable {
  public var title: String
  public var entries: [TaxonomyGovernanceEntry]
  public var missingCount: Int
  public var singletonCount: Int
  public var overloadedEntries: [TaxonomyGovernanceEntry]
}

public struct TaxonomyGovernanceEntry: Identifiable, Hashable, Sendable {
  public var id: String { normalizedName }
  public var name: String
  public var normalizedName: String
  public var count: Int
  public var draftTitles: [String]
}

public struct StaleArticleCandidate: Identifiable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var title: String
  public var markdownPath: String
  public var daysSinceArticleDate: Int
  public var daysSinceUpdate: Int
  public var reasons: [String]
}

public struct SiteRelationSuggestion: Identifiable, Hashable, Sendable {
  public var id: String { "\(sourceDraftID.uuidString)-\(targetDraftID.uuidString)" }
  public var sourceDraftID: UUID
  public var sourceTitle: String
  public var targetDraftID: UUID
  public var targetTitle: String
  public var targetPath: String
  public var sharedLabels: [String]
  public var reason: String
}

public enum SiteLinkAuditSeverity: String, Hashable, Sendable {
  case info
  case warning
  case error

  public var displayName: String {
    switch self {
    case .info:
      return "提示"
    case .warning:
      return "警告"
    case .error:
      return "错误"
    }
  }

  public var systemImage: String {
    switch self {
    case .info:
      return "info.circle"
    case .warning:
      return "exclamationmark.triangle"
    case .error:
      return "xmark.octagon"
    }
  }

}

public struct SiteLinkAuditItem: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var draftTitle: String
  public var target: String
  public var anchorText: String
  public var severity: SiteLinkAuditSeverity
  public var message: String

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    draftTitle: String,
    target: String,
    anchorText: String,
    severity: SiteLinkAuditSeverity,
    message: String
  ) {
    self.id = id
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.target = target
    self.anchorText = anchorText
    self.severity = severity
    self.message = message
  }
}

public struct MaintenanceOperationLogEntry: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var title: String
  public var summary: String
  public var createdAt: Date
  public var systemImage: String
}

public struct MaintenanceOperationRecord: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var profileID: UUID
  public var actionKind: MaintenanceActionKind
  public var actionTitle: String
  public var summary: String
  public var draftID: UUID?
  public var targetPath: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    actionKind: MaintenanceActionKind,
    actionTitle: String,
    summary: String,
    draftID: UUID? = nil,
    targetPath: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.profileID = profileID
    self.actionKind = actionKind
    self.actionTitle = actionTitle
    self.summary = summary
    self.draftID = draftID
    self.targetPath = targetPath
    self.createdAt = createdAt
  }
}

public enum SiteMaintenanceHealthLevel: String, CaseIterable, Hashable, Sendable {
  case stable
  case watch
  case needsWork
  case urgent

  public var displayName: String {
    switch self {
    case .stable:
      return "稳定"
    case .watch:
      return "关注"
    case .needsWork:
      return "需整理"
    case .urgent:
      return "需优先处理"
    }
  }

  public var systemImage: String {
    switch self {
    case .stable:
      return "checkmark.seal"
    case .watch:
      return "eye"
    case .needsWork:
      return "wrench.and.screwdriver"
    case .urgent:
      return "exclamationmark.triangle"
    }
  }

}

public struct SiteMaintenanceHealthSummary: Hashable, Sendable {
  public var level: SiteMaintenanceHealthLevel
  public var score: Int
  public var title: String
  public var message: String
  public var nextAction: String
  public var drivers: [String]
}

public enum MaintenanceActionPriority: Int, CaseIterable, Hashable, Sendable {
  case high
  case medium
  case low

  public var displayName: String {
    switch self {
    case .high:
      return "高"
    case .medium:
      return "中"
    case .low:
      return "低"
    }
  }
}

public enum MaintenanceActionKind: String, Codable, Hashable, Sendable {
  case staleArticle
  case linkAudit
  case taxonomy
  case relationSuggestion

  public var displayName: String {
    switch self {
    case .staleArticle:
      return "旧文整理"
    case .linkAudit:
      return "链接审计"
    case .taxonomy:
      return "分类治理"
    case .relationSuggestion:
      return "内链建议"
    }
  }

  public var systemImage: String {
    switch self {
    case .staleArticle:
      return "clock.badge.exclamationmark"
    case .linkAudit:
      return "link.badge.plus"
    case .taxonomy:
      return "tag"
    case .relationSuggestion:
      return "point.3.connected.trianglepath.dotted"
    }
  }
}

public struct MaintenanceActionItem: Identifiable, Hashable, Sendable {
  public var id: String
  public var kind: MaintenanceActionKind
  public var priority: MaintenanceActionPriority
  public var title: String
  public var summary: String
  public var detail: String
  public var draftID: UUID?
  public var targetPath: String?
  public var systemImage: String
}

public extension MaintenanceActionItem {
  var clipboardMarkdown: String {
    var lines = [
      "# 维护任务：\(title)",
      "",
      "- 类型：\(kind.displayName)",
      "- 优先级：\(priority.displayName)",
      "- 摘要：\(summary)"
    ]

    if !detail.trimmedForPublishing.isEmpty {
      lines.append("- 详情：\(detail)")
    }
    if let targetPath = targetPath?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 目标路径：\(targetPath)")
    }

    lines.append("")
    lines.append("## 处理清单")
    switch kind {
    case .staleArticle:
      lines.append("- [ ] 复查正文中过期、待确认或 TODO 内容。")
      lines.append("- [ ] 补充必要证据、截图、链接或版本信息。")
      lines.append("- [ ] 更新摘要、标签、分类和发布前检查。")
    case .linkAudit:
      lines.append("- [ ] 确认链接目标是否仍然有效。")
      lines.append("- [ ] 修正空链接、错误内链或缺少上下文的外链锚文本。")
      lines.append("- [ ] 重新运行发布检查或维护清单。")
    case .taxonomy:
      lines.append("- [ ] 检查缺失、过宽或孤立的标签/分类。")
      lines.append("- [ ] 优先修正待发布和公开文章。")
      lines.append("- [ ] 保持标签/分类短、稳定、可复用。")
    case .relationSuggestion:
      lines.append("- [ ] 在来源文章中选择自然位置补充内链。")
      lines.append("- [ ] 使用目标文章路径，避免编造不存在的页面。")
      lines.append("- [ ] 确认锚文本能说明读者为什么要继续阅读。")
    }

    return lines.joined(separator: "\n")
  }
}

public struct SiteMaintenanceService {
  private let calendar: Calendar

  public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
    self.calendar = calendar
  }

  public func report(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    contentPerformanceSnapshots: [ContentPerformanceSnapshot] = [],
    now: Date = Date()
  ) -> SiteMaintenanceReport {
    let calendarBuckets = calendarBuckets(drafts: drafts)
    let calendarInsights = calendarInsights(drafts: drafts, buckets: calendarBuckets, now: now)
    let calendarScheduleItems = calendarScheduleItems(drafts: drafts, profile: profile, now: now)
    let tagSummary = taxonomySummary(title: "标签", drafts: drafts, values: \.tags)
    let categorySummary = taxonomySummary(title: "分类", drafts: drafts, values: \.categories)
    let staleArticles = staleArticles(drafts: drafts, profile: profile, now: now)
    let relationSuggestions = relationSuggestions(drafts: drafts, profile: profile)
    let linkAuditItems = linkAuditItems(drafts: drafts, profile: profile)
    let operationLogEntries = operationEntries(
      releaseRecords: releaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      profileID: profile.id
    )
    let contentPerformanceSummary = contentPerformanceSummary(
      drafts: drafts,
      profile: profile,
      snapshots: contentPerformanceSnapshots
    )
    let actionItems = maintenanceActionItems(
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      relationSuggestions: relationSuggestions,
      linkAuditItems: linkAuditItems
    )
    let healthSummary = healthSummary(
      draftCount: drafts.count,
      publishedCount: drafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
      calendarInsights: calendarInsights,
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      linkAuditItems: linkAuditItems,
      actionItems: actionItems,
      operationLogEntries: operationLogEntries
    )

    return SiteMaintenanceReport(
      profileID: profile.id,
      generatedAt: now,
      draftCount: drafts.count,
      publicDraftCount: drafts.filter { !$0.isPrivate }.count,
      privateDraftCount: drafts.filter(\.isPrivate).count,
      readyCount: drafts.filter { $0.status == .ready }.count,
      publishedCount: drafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
      calendarBuckets: calendarBuckets,
      calendarInsights: calendarInsights,
      calendarScheduleItems: calendarScheduleItems,
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      relationSuggestions: relationSuggestions,
      linkAuditItems: linkAuditItems,
      actionItems: actionItems,
      operationLogEntries: operationLogEntries,
      contentPerformanceSummary: contentPerformanceSummary,
      healthSummary: healthSummary
    )
  }

  private func contentPerformanceSummary(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    snapshots: [ContentPerformanceSnapshot]
  ) -> ContentPerformanceSummary {
    let visibleDraftIDs = Set(drafts.map(\.id))
    let visibleMarkdownPaths = Set(drafts.map { profile.markdownPath(for: $0) })
    let scopedSnapshots = snapshots.filter { snapshot in
      snapshot.profileID == profile.id
        && (snapshot.draftID.map { visibleDraftIDs.contains($0) } == true
          || visibleMarkdownPaths.contains(snapshot.markdownPath))
    }
    guard !scopedSnapshots.isEmpty else {
      return .empty
    }

    let latestByArticle = Dictionary(grouping: scopedSnapshots) { snapshot in
      snapshot.draftID?.uuidString ?? snapshot.markdownPath
    }
    .compactMap { _, snapshots in
      snapshots.sorted { $0.capturedAt > $1.capturedAt }.first
    }

    let articles = latestByArticle.map { snapshot in
      ContentPerformanceArticleSummary(
        draftID: snapshot.draftID,
        title: snapshot.title,
        markdownPath: snapshot.markdownPath,
        pageViews: snapshot.pageViews,
        visitors: snapshot.visitors,
        sourceName: snapshot.sourceName,
        capturedAt: snapshot.capturedAt
      )
    }
    .sorted {
      if $0.pageViews == $1.pageViews {
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      return $0.pageViews > $1.pageViews
    }

    return ContentPerformanceSummary(
      trackedArticleCount: articles.count,
      totalPageViews: articles.reduce(0) { $0 + $1.pageViews },
      totalVisitors: articles.reduce(0) { $0 + $1.visitors },
      latestCapturedAt: scopedSnapshots.map(\.capturedAt).max(),
      topArticles: articles
    )
  }

  private func healthSummary(
    draftCount: Int,
    publishedCount: Int,
    calendarInsights: [ContentCalendarInsight],
    tagSummary: TaxonomyGovernanceSummary,
    categorySummary: TaxonomyGovernanceSummary,
    staleArticles: [StaleArticleCandidate],
    linkAuditItems: [SiteLinkAuditItem],
    actionItems: [MaintenanceActionItem],
    operationLogEntries: [MaintenanceOperationLogEntry]
  ) -> SiteMaintenanceHealthSummary {
    let highActionCount = actionItems.filter { $0.priority == .high }.count
    let mediumActionCount = actionItems.filter { $0.priority == .medium }.count
    let lowActionCount = actionItems.filter { $0.priority == .low }.count
    let linkErrorCount = linkAuditItems.filter { $0.severity == .error }.count
    let linkWarningCount = linkAuditItems.filter { $0.severity == .warning }.count
    let missingTaxonomyCount = tagSummary.missingCount + categorySummary.missingCount
    let hasPublishedContentWithoutLog = publishedCount > 0 && operationLogEntries.isEmpty

    let rawScore = 100
      - highActionCount * 18
      - mediumActionCount * 10
      - lowActionCount * 4
      - linkErrorCount * 18
      - linkWarningCount * 8
      - staleArticles.count * 8
      - missingTaxonomyCount * 3
      - calendarInsights.count * 5
      - (hasPublishedContentWithoutLog ? 6 : 0)
    let score = min(100, max(0, rawScore))

    let level: SiteMaintenanceHealthLevel
    if score < 45 || linkErrorCount > 0 || highActionCount >= 2 {
      level = .urgent
    } else if score < 70 || highActionCount > 0 || mediumActionCount >= 3 {
      level = .needsWork
    } else if score < 88 || !calendarInsights.isEmpty || !actionItems.isEmpty {
      level = .watch
    } else {
      level = .stable
    }

    var drivers: [String] = []
    if highActionCount > 0 {
      drivers.append("\(highActionCount) 个高优先级维护项")
    }
    if linkErrorCount > 0 || linkWarningCount > 0 {
      drivers.append("\(linkErrorCount + linkWarningCount) 个链接风险")
    }
    if !staleArticles.isEmpty {
      drivers.append("\(staleArticles.count) 篇旧文候选")
    }
    if missingTaxonomyCount > 0 {
      drivers.append("\(missingTaxonomyCount) 篇缺少标签或分类")
    }
    if !calendarInsights.isEmpty {
      drivers.append("\(calendarInsights.count) 条内容节奏提示")
    }
    if hasPublishedContentWithoutLog {
      drivers.append("已发布内容缺少操作日志")
    }
    if drivers.isEmpty && draftCount > 0 {
      drivers.append("内容日历、分类和链接审计未发现阻断项")
    }
    if draftCount == 0 {
      drivers.append("当前 Profile 还没有文章")
    }

    let nextAction: String
    if let firstHigh = actionItems.first(where: { $0.priority == .high }) {
      nextAction = "\(firstHigh.kind.displayName)：\(firstHigh.title)"
    } else if let firstMedium = actionItems.first(where: { $0.priority == .medium }) {
      nextAction = "\(firstMedium.kind.displayName)：\(firstMedium.title)"
    } else if let insight = calendarInsights.first {
      nextAction = insight.summary
    } else if draftCount == 0 {
      nextAction = "先创建或导入文章，再生成维护清单。"
    } else {
      nextAction = "保持当前维护节奏，发布后继续记录操作日志。"
    }

    let title: String
    let message: String
    switch level {
    case .stable:
      title = "站点维护状态稳定"
      message = "主要维护入口没有发现需要立即处理的阻断项。"
    case .watch:
      title = "站点维护需要关注"
      message = "有轻量维护项或内容节奏提示，适合排入下一次整理。"
    case .needsWork:
      title = "站点维护需要整理"
      message = "存在旧文、分类或链接风险，建议先处理行动队列前几项。"
    case .urgent:
      title = "站点维护需要优先处理"
      message = "存在高优先级维护项或链接错误，发布前应先处理。"
    }

    return SiteMaintenanceHealthSummary(
      level: level,
      score: score,
      title: title,
      message: message,
      nextAction: nextAction,
      drivers: drivers
    )
  }

  private func maintenanceActionItems(
    tagSummary: TaxonomyGovernanceSummary,
    categorySummary: TaxonomyGovernanceSummary,
    staleArticles: [StaleArticleCandidate],
    relationSuggestions: [SiteRelationSuggestion],
    linkAuditItems: [SiteLinkAuditItem]
  ) -> [MaintenanceActionItem] {
    var items: [MaintenanceActionItem] = []

    for item in linkAuditItems where item.severity == .warning || item.severity == .error {
      let priority: MaintenanceActionPriority = item.severity == .error ? .high : .medium
      items.append(
        MaintenanceActionItem(
          id: "link-\(item.id.uuidString)",
          kind: .linkAudit,
          priority: priority,
          title: item.severity == .error ? "修复空链接：\(item.draftTitle)" : "确认内链路径：\(item.draftTitle)",
          summary: item.message,
          detail: item.target,
          draftID: item.draftID,
          targetPath: item.target,
          systemImage: item.severity.systemImage
        )
      )
    }

    for item in staleArticles {
      let priority: MaintenanceActionPriority = item.reasons.count >= 2 || item.daysSinceUpdate >= 180 ? .high : .medium
      items.append(
        MaintenanceActionItem(
          id: "stale-\(item.draftID.uuidString)",
          kind: .staleArticle,
          priority: priority,
          title: "复查旧文：\(item.title)",
          summary: item.reasons.joined(separator: "；"),
          detail: item.markdownPath,
          draftID: item.draftID,
          targetPath: item.markdownPath,
          systemImage: "clock.badge.exclamationmark"
        )
      )
    }

    appendTaxonomyActions(
      summary: tagSummary,
      missingSystemImage: "tag",
      into: &items
    )
    appendTaxonomyActions(
      summary: categorySummary,
      missingSystemImage: "folder",
      into: &items
    )

    for item in relationSuggestions.prefix(6) {
      let priority: MaintenanceActionPriority = item.sharedLabels.count >= 2 ? .medium : .low
      items.append(
        MaintenanceActionItem(
          id: "relation-\(item.id)",
          kind: .relationSuggestion,
          priority: priority,
          title: "补内链：\(item.sourceTitle) -> \(item.targetTitle)",
          summary: item.reason,
          detail: item.targetPath,
          draftID: item.sourceDraftID,
          targetPath: item.targetPath,
          systemImage: "point.3.connected.trianglepath.dotted"
        )
      )
    }

    return items.sorted {
      if $0.priority.rawValue == $1.priority.rawValue {
        if $0.kind.rawValue == $1.kind.rawValue {
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return $0.kind.rawValue < $1.kind.rawValue
      }
      return $0.priority.rawValue < $1.priority.rawValue
    }
    .prefix(14)
    .map { $0 }
  }

  private func appendTaxonomyActions(
    summary: TaxonomyGovernanceSummary,
    missingSystemImage: String,
    into items: inout [MaintenanceActionItem]
  ) {
    if summary.missingCount > 0 {
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-missing",
          kind: .taxonomy,
          priority: .medium,
          title: "补齐缺失\(summary.title)",
          summary: "\(summary.missingCount) 篇文章还没有\(summary.title)，影响归档、相关推荐和站内导航。",
          detail: "优先处理待发布和公开文章。",
          draftID: nil,
          targetPath: nil,
          systemImage: missingSystemImage
        )
      )
    }

    if !summary.overloadedEntries.isEmpty {
      let names = summary.overloadedEntries.prefix(3).map(\.name).joined(separator: "、")
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-overloaded",
          kind: .taxonomy,
          priority: .medium,
          title: "拆分高频\(summary.title)",
          summary: "\(names) 覆盖文章过多，建议拆成更具体的专题。",
          detail: "高频\(summary.title)会削弱读者筛选和相关文章推荐。",
          draftID: nil,
          targetPath: nil,
          systemImage: "rectangle.3.group"
        )
      )
    }

    if summary.singletonCount > 0 {
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-singleton",
          kind: .taxonomy,
          priority: .low,
          title: "合并孤立\(summary.title)",
          summary: "\(summary.singletonCount) 个\(summary.title)只关联 1 篇文章。",
          detail: "可以合并到已有\(summary.title)，或补充同主题文章形成系列。",
          draftID: nil,
          targetPath: nil,
          systemImage: "square.stack.3d.up"
        )
      )
    }
  }

  private func calendarBuckets(drafts: [ArticleDraft]) -> [ContentCalendarBucket] {
    let grouped = Dictionary(grouping: drafts) { draft in
      monthKey(for: draft.date)
    }

    return grouped.keys.sorted(by: >).map { key in
      let bucketDrafts = grouped[key, default: []]
      return ContentCalendarBucket(
        monthKey: key,
        title: monthTitle(for: bucketDrafts.first?.date ?? Date()),
        articleCount: bucketDrafts.count,
        draftCount: bucketDrafts.filter { $0.status == .draft || $0.draft }.count,
        readyCount: bucketDrafts.filter { $0.status == .ready }.count,
        publishedCount: bucketDrafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
        publicCount: bucketDrafts.filter { !$0.isPrivate }.count,
        privateCount: bucketDrafts.filter(\.isPrivate).count
      )
    }
  }

  private func calendarInsights(
    drafts: [ArticleDraft],
    buckets: [ContentCalendarBucket],
    now: Date
  ) -> [ContentCalendarInsight] {
    guard !drafts.isEmpty else {
      return []
    }

    let publicDrafts = drafts.filter { !$0.isPrivate }
    let readyPublicDrafts = publicDrafts.filter { $0.status == .ready }
    let currentMonthKey = monthKey(for: now)
    let currentMonthBucket = buckets.first { $0.monthKey == currentMonthKey }
    var insights: [ContentCalendarInsight] = []

    if readyPublicDrafts.count >= 2 {
      insights.append(
        ContentCalendarInsight(
          id: "ready-backlog",
          title: "待发布积压",
          summary: "\(readyPublicDrafts.count) 篇公开文章已经标记待发布。",
          detail: "建议先选 1 到 2 篇完成链接、SEO 和发布检查，避免内容长期停在待发布队列。",
          priority: readyPublicDrafts.count >= 5 ? .high : .medium,
          systemImage: "tray.full"
        )
      )
    }

    if let currentMonthBucket,
       currentMonthBucket.draftCount >= 3,
       currentMonthBucket.draftCount > currentMonthBucket.readyCount + currentMonthBucket.publishedCount {
      insights.append(
        ContentCalendarInsight(
          id: "current-month-draft-heavy",
          title: "本月草稿偏多",
          summary: "\(currentMonthBucket.title) 有 \(currentMonthBucket.draftCount) 篇草稿，高于待发布和已发布合计。",
          detail: "适合从当月草稿里挑选可以收尾的文章，先补摘要、标签、分类和首屏结构。",
          priority: .medium,
          systemImage: "square.and.pencil"
        )
      )
    }

    if (currentMonthBucket?.publishedCount ?? 0) == 0,
       !readyPublicDrafts.isEmpty {
      insights.append(
        ContentCalendarInsight(
          id: "current-month-no-published",
          title: "本月还没有公开发布",
          summary: "当前月份暂无公开发布记录，但已有 \(readyPublicDrafts.count) 篇待发布文章。",
          detail: "可以把待发布队列作为本月内容节奏的优先来源。",
          priority: .medium,
          systemImage: "calendar.badge.exclamationmark"
        )
      )
    }

    let latestPublishedDate = publicDrafts
      .filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }
      .map(\.date)
      .max()
    if let latestPublishedDate {
      let inactiveMonths = monthsBetween(latestPublishedDate, and: now)
      if inactiveMonths >= 2 {
        insights.append(
          ContentCalendarInsight(
            id: "publish-gap",
            title: "公开发布断档",
            summary: "最近一次公开发布距今约 \(inactiveMonths) 个月。",
            detail: "建议复查是否有可快速更新的旧文或待发布文章，先恢复稳定更新节奏。",
            priority: inactiveMonths >= 4 ? .high : .medium,
            systemImage: "calendar.badge.clock"
          )
        )
      }
    }

    return insights.sorted {
      if $0.priority.rawValue == $1.priority.rawValue {
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      return $0.priority.rawValue < $1.priority.rawValue
    }
  }

  private func calendarScheduleItems(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    now: Date
  ) -> [ContentCalendarScheduleItem] {
    let startOfToday = calendar.startOfDay(for: now)
    let readyPublicDrafts = drafts
      .filter { !$0.isPrivate && $0.status == .ready }
      .sorted {
        if $0.date == $1.date {
          return $0.updatedAt < $1.updatedAt
        }
        return $0.date < $1.date
      }

    var nextOverflowSlot = startOfToday
    return readyPublicDrafts.enumerated().map { index, draft in
      let draftDay = calendar.startOfDay(for: draft.date)
      let scheduledDate: Date
      let reason: String
      let systemImage: String
      if draftDay >= startOfToday {
        scheduledDate = draftDay
        reason = "沿用文章日期作为发布槽位。"
        systemImage = "calendar"
      } else {
        scheduledDate = nextOverflowSlot
        reason = "文章日期已过，建议从当前维护节奏中重新排期。"
        systemImage = "calendar.badge.clock"
      }
      if scheduledDate >= nextOverflowSlot {
        nextOverflowSlot = calendar.date(byAdding: .day, value: 3, to: scheduledDate) ?? nextOverflowSlot
      }
      return ContentCalendarScheduleItem(
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名文章",
        markdownPath: profile.markdownPath(for: draft),
        scheduledDate: scheduledDate,
        reason: reason,
        systemImage: systemImage
      )
    }
  }

  private func relationSuggestions(drafts: [ArticleDraft], profile: SiteProfile) -> [SiteRelationSuggestion] {
    let sourceDrafts = drafts.filter { !$0.isPrivate && !$0.draft }
    let targetDrafts = drafts.filter { !$0.isPrivate && !$0.draft && $0.status == .published }
    var suggestions: [SiteRelationSuggestion] = []

    for source in sourceDrafts {
      let sourceLabels = taxonomyLabels(for: source)
      guard !sourceLabels.isEmpty else {
        continue
      }
      let sourceBody = source.bodyMarkdown.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

      for target in targetDrafts where target.id != source.id {
        let targetLabels = taxonomyLabels(for: target)
        let shared = sharedTaxonomyLabels(sourceLabels, targetLabels)
        guard !shared.isEmpty else {
          continue
        }

        let targetPath = canonicalWebPath(from: profile.markdownPath(for: target))
        let slugPath = "/" + (target.slug.nilIfEmpty ?? SlugService.fallbackSlug(date: target.date)) + "/"
        guard !sourceBody.contains(targetPath.lowercased()),
              !sourceBody.contains(slugPath.lowercased()) else {
          continue
        }

        suggestions.append(
          SiteRelationSuggestion(
            sourceDraftID: source.id,
            sourceTitle: source.title.nilIfEmpty ?? "未命名文章",
            targetDraftID: target.id,
            targetTitle: target.title.nilIfEmpty ?? "未命名文章",
            targetPath: targetPath,
            sharedLabels: shared.map(\.displayName),
            reason: "共享 \(shared.map(\.displayName).joined(separator: "、"))，但正文还没有链接到目标文章。"
          )
        )
      }
    }

    return suggestions.sorted {
      if $0.sharedLabels.count == $1.sharedLabels.count {
        return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
      }
      return $0.sharedLabels.count > $1.sharedLabels.count
    }
  }

  private func taxonomySummary(
    title: String,
    drafts: [ArticleDraft],
    values: KeyPath<ArticleDraft, [String]>
  ) -> TaxonomyGovernanceSummary {
    var entriesByName: [String: (name: String, titles: [String])] = [:]
    var missingCount = 0

    for draft in drafts {
      let names = draft[keyPath: values]
        .map { $0.trimmedForPublishing }
        .filter { !$0.isEmpty }

      if names.isEmpty {
        missingCount += 1
      }

      for name in names {
        let key = normalizedTaxonomyName(name)
        var bucket = entriesByName[key] ?? (name: name, titles: [])
        bucket.titles.append(draft.title.nilIfEmpty ?? "未命名文章")
        entriesByName[key] = bucket
      }
    }

    let entries = entriesByName.values.map { bucket in
      TaxonomyGovernanceEntry(
        name: bucket.name,
        normalizedName: normalizedTaxonomyName(bucket.name),
        count: bucket.titles.count,
        draftTitles: bucket.titles.sorted()
      )
    }
    .sorted {
      if $0.count == $1.count {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.count > $1.count
    }

    return TaxonomyGovernanceSummary(
      title: title,
      entries: entries,
      missingCount: missingCount,
      singletonCount: entries.filter { $0.count == 1 }.count,
      overloadedEntries: entries.filter { $0.count >= 8 }
    )
  }

  private func staleArticles(drafts: [ArticleDraft], profile: SiteProfile, now: Date) -> [StaleArticleCandidate] {
    drafts.compactMap { draft in
      guard !draft.isPrivate, !draft.draft || draft.status == .published else {
        return nil
      }

      let articleDays = days(from: draft.date, to: now)
      let updateDays = days(from: draft.updatedAt, to: now)
      var reasons: [String] = []
      if articleDays >= 180 {
        reasons.append("文章日期已超过 \(articleDays) 天")
      }
      if updateDays >= 90 {
        reasons.append("最近更新已超过 \(updateDays) 天")
      }
      if draft.bodyMarkdown.localizedCaseInsensitiveContains("TODO")
        || draft.bodyMarkdown.localizedCaseInsensitiveContains("待确认") {
        reasons.append("正文仍有待确认标记")
      }

      guard !reasons.isEmpty else {
        return nil
      }

      return StaleArticleCandidate(
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名文章",
        markdownPath: profile.markdownPath(for: draft),
        daysSinceArticleDate: articleDays,
        daysSinceUpdate: updateDays,
        reasons: reasons
      )
    }
    .sorted {
      if $0.reasons.count == $1.reasons.count {
        return $0.daysSinceUpdate > $1.daysSinceUpdate
      }
      return $0.reasons.count > $1.reasons.count
    }
  }

  private func linkAuditItems(drafts: [ArticleDraft], profile: SiteProfile) -> [SiteLinkAuditItem] {
    let knownInternalPaths = Set(drafts.flatMap { draft in
      [
        canonicalWebPath(from: profile.markdownPath(for: draft)),
        "/" + (draft.slug.nilIfEmpty ?? SlugService.fallbackSlug(date: draft.date)) + "/",
      ]
    })

    return drafts.flatMap { draft in
      markdownLinks(in: draft.bodyMarkdown).compactMap { link in
        let target = normalizedLinkTarget(link.target)
        guard !target.isEmpty else {
          return SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .error,
            message: "链接目标为空。"
          )
        }

        if target.hasPrefix("http://") || target.hasPrefix("https://") {
          return externalLinkAuditItem(draft: draft, link: link, target: target)
        }

        guard target.hasPrefix("/") else {
          return SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .info,
            message: "相对链接需要发布前确认路径基准。"
          )
        }

        let pathOnly = pathWithoutQueryOrFragment(target)
        guard !isAssetPath(pathOnly) else {
          return nil
        }
        guard knownInternalPaths.contains(pathOnly) else {
          return SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .warning,
            message: "没有匹配到当前 Profile 的文章路径。"
          )
        }
        return nil
      }
    }
  }

  private func externalLinkAuditItem(
    draft: ArticleDraft,
    link: MarkdownLink,
    target: String
  ) -> SiteLinkAuditItem? {
    guard link.anchor.trimmedForPublishing.count <= 4 || link.anchor == target else {
      return nil
    }
    return SiteLinkAuditItem(
      draftID: draft.id,
      draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
      target: target,
      anchorText: link.anchor,
      severity: .info,
      message: "外部链接锚文本过短或直接裸露 URL，建议补充上下文。"
    )
  }

  private func operationEntries(
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord],
    profileID: UUID
  ) -> [MaintenanceOperationLogEntry] {
    let releaseEntries = releaseRecords
      .filter { record in
        record.siteProfileID == nil || record.siteProfileID == profileID
      }
      .map { record in
        MaintenanceOperationLogEntry(
          id: record.id,
          title: record.title,
          summary: record.summary,
          createdAt: record.createdAt,
          systemImage: record.kind.systemImage
        )
      }

    let maintenanceEntries = maintenanceOperationRecords
      .filter { $0.profileID == profileID }
      .map { record in
        MaintenanceOperationLogEntry(
          id: record.id,
          title: "维护处理：\(record.actionTitle)",
          summary: record.summary,
          createdAt: record.createdAt,
          systemImage: record.actionKind.systemImage
        )
      }

    return (releaseEntries + maintenanceEntries)
      .sorted { lhs, rhs in
        lhs.createdAt > rhs.createdAt
      }
      .prefix(12)
      .map { $0 }
  }

  private func markdownLinks(in markdown: String) -> [MarkdownLink] {
    let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return regex.matches(in: markdown, range: range).compactMap { match in
      guard let anchorRange = Range(match.range(at: 1), in: markdown),
            let targetRange = Range(match.range(at: 2), in: markdown) else {
        return nil
      }
      return MarkdownLink(anchor: String(markdown[anchorRange]), target: String(markdown[targetRange]))
    }
  }

  private func monthKey(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
  }

  private func monthTitle(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month], from: date)
    return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
  }

  private func days(from start: Date, to end: Date) -> Int {
    max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
  }

  private func monthsBetween(_ start: Date, and end: Date) -> Int {
    let startComponents = calendar.dateComponents([.year, .month], from: start)
    let endComponents = calendar.dateComponents([.year, .month], from: end)
    let startMonth = (startComponents.year ?? 0) * 12 + (startComponents.month ?? 0)
    let endMonth = (endComponents.year ?? 0) * 12 + (endComponents.month ?? 0)
    return max(0, endMonth - startMonth)
  }

  private func normalizedTaxonomyName(_ name: String) -> String {
    name.trimmedForPublishing.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private func taxonomyLabels(for draft: ArticleDraft) -> [TaxonomyLabel] {
    (draft.tags + draft.categories)
      .map { name in
        let displayName = name.trimmedForPublishing
        return TaxonomyLabel(displayName: displayName, normalizedName: normalizedTaxonomyName(displayName))
      }
      .filter { !$0.normalizedName.isEmpty }
  }

  private func sharedTaxonomyLabels(_ lhs: [TaxonomyLabel], _ rhs: [TaxonomyLabel]) -> [TaxonomyLabel] {
    let rhsKeys = Set(rhs.map(\.normalizedName))
    var seen: Set<String> = []
    return lhs.filter { label in
      guard rhsKeys.contains(label.normalizedName), !seen.contains(label.normalizedName) else {
        return false
      }
      seen.insert(label.normalizedName)
      return true
    }
  }

  private func canonicalWebPath(from markdownPath: String) -> String {
    var path = markdownPath.normalizedRelativePath()
    for prefix in ["content/posts/", "content/", "src/content/blog/", "source/_posts/", "_posts/"] where path.hasPrefix(prefix) {
      path = String(path.dropFirst(prefix.count))
      break
    }
    for suffix in [".mdx", ".markdown", ".md"] where path.hasSuffix(suffix) {
      path = String(path.dropLast(suffix.count))
      break
    }
    return "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
  }

  private func normalizedLinkTarget(_ target: String) -> String {
    target.trimmedForPublishing.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private func pathWithoutQueryOrFragment(_ target: String) -> String {
    let trimmed = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
    let path = trimmed.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
    if path.hasSuffix("/") {
      return path
    }
    guard !path.contains(".") else {
      return path
    }
    return path + "/"
  }

  private func isAssetPath(_ path: String) -> Bool {
    ["/images/", "/assets/", "/static/"].contains { path.hasPrefix($0) }
  }
}

private struct MarkdownLink {
  var anchor: String
  var target: String
}

private struct TaxonomyLabel: Hashable {
  var displayName: String
  var normalizedName: String
}
