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
  public var healthSummary: SiteMaintenanceHealthSummary

  public var internalLinkIssueCount: Int {
    linkAuditItems.filter { $0.severity == .warning || $0.severity == .error }.count
  }

  public var internalLinkOpportunityCount: Int {
    relationSuggestions.count
  }
}

extension SiteMaintenanceReport {
  public var maintenanceSprintPlanMarkdown: String {
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
    ]

    lines.append("")
    lines.append("## 今日优先")
    let priorityItems =
      actionItems
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
    let linkIssues =
      linkAuditItems
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

  public var maintenanceChecklistMarkdown: String {
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
      "- 下一步：\(healthSummary.nextAction)",
    ]

    appendHealthSummary(to: &lines)
    appendActionItems(to: &lines)
    appendCalendar(to: &lines)
    appendCalendarInsights(to: &lines)
    appendCalendarSchedule(to: &lines)
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
      lines.append(
        "- \(bucket.title)：\(bucket.articleCount) 篇，已发布 \(bucket.publishedCount)，待发布 \(bucket.readyCount)，公开 \(bucket.publicCount)，私密 \(bucket.privateCount)"
      )
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

  private func appendTaxonomySummary(_ summary: TaxonomyGovernanceSummary, to lines: inout [String])
  {
    lines.append("")
    lines.append("## \(summary.title)治理")
    lines.append("- 缺失：\(summary.missingCount)")
    lines.append("- 单篇\(summary.title)：\(summary.singletonCount)")
    if !summary.overloadedEntries.isEmpty {
      lines.append(
        "- 高频\(summary.title)：\(summary.overloadedEntries.prefix(5).map(\.name).joined(separator: "、"))"
      )
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

struct SiteRelationScanMetrics: Hashable, Sendable {
  var sourceDraftCount: Int
  var publishedTargetDraftCount: Int
  var indexedTargetDraftCount: Int
  var indexedLabelCount: Int
  var targetIndexEntryCount: Int
  var candidateEvaluationCount: Int
  var suggestionCount: Int
}

struct SiteRelationScanResult: Sendable {
  var suggestions: [SiteRelationSuggestion]
  var metrics: SiteRelationScanMetrics
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
  public var kind: SiteLinkAuditKind
  public var statusCode: Int?
  public var finalTarget: String?

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    draftTitle: String,
    target: String,
    anchorText: String,
    severity: SiteLinkAuditSeverity,
    message: String,
    kind: SiteLinkAuditKind = .advisory,
    statusCode: Int? = nil,
    finalTarget: String? = nil
  ) {
    self.id = id
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.target = target
    self.anchorText = anchorText
    self.severity = severity
    self.message = message
    self.kind = kind
    self.statusCode = statusCode
    self.finalTarget = finalTarget
  }
}

public enum SiteLinkAuditKind: String, Hashable, Sendable {
  case brokenInternal
  case slugRedirectReference
  case externalDead
  case externalUnverified
  case anchorText
  case advisory
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

extension MaintenanceActionItem {
  public var clipboardMarkdown: String {
    var lines = [
      "# 维护任务：\(title)",
      "",
      "- 类型：\(kind.displayName)",
      "- 优先级：\(priority.displayName)",
      "- 摘要：\(summary)",
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
