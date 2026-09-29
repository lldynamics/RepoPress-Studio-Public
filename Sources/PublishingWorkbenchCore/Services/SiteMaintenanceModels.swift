import Foundation

public struct SiteMaintenanceReport: Hashable, Sendable {
  public var profileID: UUID
  public var generatedAt: Date
  public var draftCount: Int
  public var publicDraftCount: Int
  public var privateDraftCount: Int
  public var readyCount: Int
  public var publishedCount: Int
  public var tagSummary: TaxonomyGovernanceSummary
  public var categorySummary: TaxonomyGovernanceSummary
  public var staleArticles: [StaleArticleCandidate]
  public var relationSuggestions: [SiteRelationSuggestion]
  public var linkAuditItems: [SiteLinkAuditItem]
  public var actionItems: [MaintenanceActionItem]
  public var operationLogEntries: [MaintenanceOperationLogEntry]
  public var healthSummary: SiteMaintenanceHealthSummary
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
