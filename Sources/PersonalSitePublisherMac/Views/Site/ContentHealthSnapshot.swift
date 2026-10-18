import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthSnapshot: Sendable {
  var id: UUID
  var generatedAt: Date
  var profileID: UUID
  var profileName: String
  var publicRiskDraftSummaries: [DraftPreflightSummary]
  var aiFixQueueItems: [AIPublishingFixQueueItem]
  var sitePreflightIssues: [PreflightIssue]
  var contentHealthSummaries: [DraftPreflightSummary]
  var slugChangeImpacts: [UUID: SlugChangeImpact]
  var errorCount: Int
  var warningCount: Int
  var optimizationCount: Int = 0
  var passingDraftCount: Int
  var suppressedIssues: [ContentHealthIssueOccurrence] = []
}

enum ContentHealthSeverityFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case errors
  case warnings
  case optimizations

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .errors: String(localized: "错误")
    case .warnings: String(localized: "警告")
    case .optimizations: String(localized: "优化建议")
    }
  }

  func filter(_ issues: [PreflightIssue]) -> [PreflightIssue] {
    switch self {
    case .all: issues
    case .errors: issues.filter { $0.severity == .error }
    case .warnings: issues.filter { $0.severity == .warning }
    case .optimizations: issues.filter(\.isOptionalOptimization)
    }
  }
}

enum ContentHealthSourceFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case articles
  case site
  case maintenance

  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: String(localized: "全部来源")
    case .articles: String(localized: "文章")
    case .site: String(localized: "站点")
    case .maintenance: String(localized: "维护")
    }
  }
  var includesArticles: Bool { self == .all || self == .articles }
  var includesSite: Bool { self == .all || self == .site }
  var includesMaintenance: Bool { self == .all || self == .maintenance }
}

enum ContentHealthAIFixFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case fixable
  case manual

  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: String(localized: "全部处理方式")
    case .fixable: String(localized: "AI 修复")
    case .manual: String(localized: "手动处理")
    }
  }
  func includes(canUseAI: Bool) -> Bool {
    switch self {
    case .all: true
    case .fixable: canUseAI
    case .manual: !canUseAI
    }
  }
}

struct ContentHealthFilteredEmptyState<MaintenanceContent: View>: View {
  let snapshot: ContentHealthSnapshot
  let isMaintenancePending: Bool
  let isFiltered: Bool
  let maintenanceContent: MaintenanceContent

  var body: some View {
    if isMaintenancePending {
      maintenanceContent
    } else {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
        Label(
          isFiltered
            ? "当前筛选无结果"
            : (snapshot.optimizationCount > 0 ? "检查通过，有优化建议" : "全部通过"),
          systemImage: "checkmark.seal.fill"
        )
        .font(.workbenchCardTitle)
        .foregroundStyle(WorkbenchTheme.success)
        Text("当前筛选下没有待处理的问题。")
          .font(.workbenchSupporting)
          .foregroundStyle(.workbenchSecondary)
        Text("上次扫描 \(snapshot.generatedAt.workbenchShortText)")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("content-health-all-clear")
    }
  }
}

struct ContentHealthSnapshotCancelledState: View {
  let refresh: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "pause.circle")
        .font(.system(size: WorkbenchIconSize.hero))
        .foregroundStyle(.workbenchSecondary)
        .accessibilityHidden(true)
      Text("内容健康检查已取消")
        .font(.workbenchHeadline)
      Text("尚未修改任何文章。需要时可以重新生成检查快照。")
        .foregroundStyle(.workbenchSecondary)
        .multilineTextAlignment(.center)
      Button(action: refresh) {
        Label("重新开始", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, minHeight: 360)
    .padding(WorkbenchSpacing.page)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content-health-loading-cancelled")
  }
}

struct ContentHealthSnapshotFailureState: View {
  let errorMessage: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "xmark.octagon")
        .font(.system(size: WorkbenchIconSize.hero))
        .foregroundStyle(WorkbenchTheme.risk)
        .accessibilityHidden(true)
      Text("无法生成检查快照")
        .font(.workbenchHeadline)
      AccessibleStatusMessage(message: errorMessage, severity: .error)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button(action: retry) {
        Label(String(localized: "重试"), systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, minHeight: 360)
    .padding(WorkbenchSpacing.page)
  }
}
