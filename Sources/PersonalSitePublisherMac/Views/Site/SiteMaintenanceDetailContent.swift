import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceSnapshotPlaceholder: View {
  let isRefreshing: Bool
  let errorMessage: String?
  let generate: () -> Void

  var body: some View {
    WorkbenchStateView(
      presentation: isRefreshing
        ? WorkbenchStatePresentation(
          kind: .loading(
            detail: String(localized: "正在扫描内容日历、标签、旧文和链接…")
          )
        )
        : (errorMessage.map {
          WorkbenchStatePresentation(kind: .failure(reason: $0))
        } ?? WorkbenchStatePresentation(kind: .empty)),
      density: .compactPane,
      detail: errorMessage == nil && !isRefreshing
        ? "点击生成后才会扫描内容日历、标签、旧文和链接，避免打开页面时自动重算。"
        : nil,
      actions: isRefreshing
        ? .none
        : WorkbenchStateActions(
          primary: WorkbenchStateAction(
            title: errorMessage == nil ? "生成维护报告" : "重新生成",
            systemImage: "arrow.clockwise",
            action: generate
          )
        )
    )
  }
}

struct SiteMaintenanceDetailContent: View {
  let snapshot: SiteMaintenanceSnapshot
  let isStale: Bool
  let isRefreshing: Bool
  let isAIChatRunning: Bool
  let refresh: () -> Void
  let copySprintPlan: (SiteMaintenanceReport) -> Void
  let copyChecklist: (SiteMaintenanceReport) -> Void
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void
  let scheduleChanges: [SiteMaintenanceScheduleChange]
  let applySuggestedSchedule: ([UUID: Date], [UUID: Date]) -> Void
  let latestRelease: ReleaseRecord?
  let deploymentSnapshot: DeploymentStatusSnapshot?
  let canCheckDeployment: Bool
  let isDeploymentChecking: Bool
  let onlineInspectionMessage: String?
  let runOnlineInspection: () -> Void
  @State private var selectedPage: SiteMaintenancePage = .overview

  private var report: SiteMaintenanceReport {
    snapshot.report
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SiteMaintenanceSnapshotHeader(
        snapshot: snapshot,
        report: report,
        isStale: isStale,
        isRefreshing: isRefreshing,
        refresh: refresh,
        copySprintPlan: {
          copySprintPlan(report)
        },
        copyChecklist: {
          copyChecklist(report)
        }
      )

      Picker("站点维护页面", selection: $selectedPage) {
        ForEach(SiteMaintenancePage.allCases) { page in
          Label(page.title, systemImage: page.systemImage).tag(page)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("站点维护页面")

      selectedPageContent
    }
  }

  @ViewBuilder
  private var selectedPageContent: some View {
    switch selectedPage {
    case .overview:
      SiteMaintenanceMetricGrid(
        report: report,
        latestRelease: latestRelease,
        deploymentSnapshot: deploymentSnapshot
      )
      OnlineSiteInspectionSection(
        report: report,
        latestRelease: latestRelease,
        deploymentSnapshot: deploymentSnapshot,
        canCheckDeployment: canCheckDeployment,
        isChecking: isDeploymentChecking,
        message: onlineInspectionMessage,
        runInspection: runOnlineInspection
      )
      SiteMaintenanceHealthSection(summary: report.healthSummary)
      SiteMaintenanceActionQueueSection(
        report: report,
        isAIChatRunning: isAIChatRunning,
        openDraft: openDraft,
        copyItem: copyItem,
        recordItem: recordItem,
        sendToAI: sendToAI,
        maximumVisibleCount: 3,
        allowsExpansion: false
      )

    case .tasks:
      SiteMaintenanceActionQueueSection(
        report: report,
        isAIChatRunning: isAIChatRunning,
        openDraft: openDraft,
        copyItem: copyItem,
        recordItem: recordItem,
        sendToAI: sendToAI
      )
      SiteMaintenanceOperationLogSection(report: report)

    case .calendar:
      SiteMaintenanceCalendarSection(
        report: report,
        scheduleChanges: scheduleChanges,
        applySuggestedSchedule: applySuggestedSchedule,
        openDraft: openDraft
      )

    case .governance:
      SiteMaintenanceTaxonomySection(title: "标签治理", summary: report.tagSummary, systemImage: "tag")
      SiteMaintenanceTaxonomySection(
        title: "分类治理", summary: report.categorySummary, systemImage: "folder")
      SiteMaintenanceStaleArticleSection(report: report, openDraft: openDraft)

    case .links:
      SiteMaintenanceRelationSuggestionSection(report: report, openDraft: openDraft)
      SiteMaintenanceLinkAuditSection(report: report, openDraft: openDraft)
    }
  }
}

private enum SiteMaintenancePage: String, CaseIterable, Identifiable {
  case overview
  case tasks
  case calendar
  case governance
  case links

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: String(localized: "总览")
    case .tasks: String(localized: "待办")
    case .calendar: String(localized: "内容日历")
    case .governance: String(localized: "分类治理")
    case .links: String(localized: "链接检查")
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .tasks: "checklist"
    case .calendar: "calendar"
    case .governance: "tag"
    case .links: "link"
    }
  }
}
