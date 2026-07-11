import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceSnapshotPlaceholder: View {
  let generate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("维护报告尚未生成", systemImage: "wrench.and.screwdriver")
        .font(.headline)
      Text("点击生成后才会扫描内容日历、标签、旧文和链接，避免打开页面时自动重算。")
        .foregroundStyle(.secondary)
      Button {
        generate()
      } label: {
        Label("生成维护报告", systemImage: "arrow.clockwise")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SiteMaintenanceDetailContent: View {
  let snapshot: SiteMaintenanceSnapshot
  let isStale: Bool
  let isAIChatRunning: Bool
  let selectedDraft: ArticleDraft?
  @Binding var performancePageViews: String
  @Binding var performanceVisitors: String
  @Binding var performanceSourceName: String
  let refresh: () -> Void
  let copySprintPlan: (SiteMaintenanceReport) -> Void
  let copyChecklist: (SiteMaintenanceReport) -> Void
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void
  let applySuggestedSchedule: () -> Void
  let recordPerformanceSnapshot: (ArticleDraft) -> Void
  let importCSV: () -> Void
  let importNotice: ContentPerformanceImportNotice?
  let latestRelease: ReleaseRecord?
  let deploymentSnapshot: DeploymentStatusSnapshot?
  let canCheckDeployment: Bool
  let isDeploymentChecking: Bool
  let onlineInspectionMessage: String?
  let runOnlineInspection: () -> Void

  private var report: SiteMaintenanceReport {
    snapshot.report
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SiteMaintenanceSnapshotHeader(
        snapshot: snapshot,
        report: report,
        isStale: isStale,
        refresh: refresh,
        copySprintPlan: {
          copySprintPlan(report)
        },
        copyChecklist: {
          copyChecklist(report)
        }
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
      SiteMaintenanceReportSections(
        report: report,
        isAIChatRunning: isAIChatRunning,
        selectedDraft: selectedDraft,
        performancePageViews: $performancePageViews,
        performanceVisitors: $performanceVisitors,
        performanceSourceName: $performanceSourceName,
        openDraft: openDraft,
        copyItem: copyItem,
        recordItem: recordItem,
        sendToAI: sendToAI,
        applySuggestedSchedule: applySuggestedSchedule,
        recordPerformanceSnapshot: recordPerformanceSnapshot,
        importCSV: importCSV,
        importNotice: importNotice
      )
    }
  }
}
