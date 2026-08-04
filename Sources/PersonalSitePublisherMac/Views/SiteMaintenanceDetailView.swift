import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceDetailView: View {
  @ObservedObject var store: WorkbenchStore
  var isEmbedded: Bool = false
  @State private var onlineInspectionMessage: String?

  var body: some View {
    if isEmbedded {
      bodyContent
    } else {
      ScrollView {
        bodyContent
          .workbenchPageLayout()
      }
    }
  }

  @ViewBuilder
  private var bodyContent: some View {
    if let snapshot = store.siteMaintenanceSnapshot {
      VStack(alignment: .leading, spacing: 12) {
        if let errorMessage = store.siteMaintenanceSnapshotErrorMessage {
          maintenanceRefreshFailure(errorMessage)
        }
        SiteMaintenanceDetailContent(
          snapshot: snapshot,
          isStale: store.isSiteMaintenanceSnapshotStale,
          isRefreshing: store.isSiteMaintenanceSnapshotRefreshing,
          isAIChatRunning: store.ai.isChatRunning,
          refresh: refreshMaintenanceSnapshot,
          copySprintPlan: copySprintPlan,
          copyChecklist: copyChecklist,
          openDraft: openDraft,
          copyItem: copyItem,
          recordItem: recordItem,
          sendToAI: sendToAI,
          applySuggestedSchedule: {
            Task {
              await store.applySuggestedMaintenanceSchedule()
            }
          },
          latestRelease: store.activeProfileReleaseRecords.first,
          deploymentSnapshot: store.activeProfileReleaseRecords.first.flatMap(store.deploymentStatusSnapshot),
          canCheckDeployment: store.activeProfileReleaseRecords.first.map(store.canCheckDeploymentStatus) ?? false,
          isDeploymentChecking: store.isDeploymentStatusChecking,
          onlineInspectionMessage: onlineInspectionMessage,
          runOnlineInspection: runOnlineInspection
        )
      }
    } else {
      SiteMaintenanceSnapshotPlaceholder(
        isRefreshing: store.isSiteMaintenanceSnapshotRefreshing,
        errorMessage: store.siteMaintenanceSnapshotErrorMessage,
        generate: refreshMaintenanceSnapshot
      )
    }
  }

  private func refreshMaintenanceSnapshot() {
    guard !store.isSiteMaintenanceSnapshotRefreshing else { return }
    Task {
      await store.refreshSiteMaintenanceSnapshot(force: true)
    }
  }

  private func maintenanceRefreshFailure(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(WorkbenchTheme.risk)
      VStack(alignment: .leading, spacing: 3) {
        Text("维护报告刷新失败")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("重试", action: refreshMaintenanceSnapshot)
        .disabled(store.isSiteMaintenanceSnapshotRefreshing)
    }
    .padding(10)
    .background(WorkbenchTheme.risk.opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func copySprintPlan(_ report: SiteMaintenanceReport) {
    copy(report.maintenanceSprintPlanMarkdown, message: "已复制站点维护冲刺计划。")
  }

  private func copyChecklist(_ report: SiteMaintenanceReport) {
    copy(report.maintenanceChecklistMarkdown, message: "已复制站点维护清单。")
  }

  private func openDraft(_ draftID: UUID) {
    store.selectDraft(draftID)
    store.selectSection(.writing)
  }

  private func copyItem(_ item: MaintenanceActionItem) {
    copy(item.clipboardMarkdown, message: "已复制维护任务。")
  }

  private func recordItem(_ item: MaintenanceActionItem) {
    store.recordMaintenanceOperation(for: item)
  }

  private func sendToAI(_ item: MaintenanceActionItem) {
    Task {
      await store.sendMaintenanceActionToAI(item)
    }
  }

  private func runOnlineInspection() {
    guard let release = store.activeProfileReleaseRecords.first else {
      onlineInspectionMessage = "尚无发布记录。"
      return
    }
    guard store.canCheckDeploymentStatus(for: release) else {
      onlineInspectionMessage = store.deploymentStatusReadiness(for: release).nextStep
      return
    }

    Task {
      await store.refreshSiteMaintenanceSnapshot(force: true)
      if let snapshot = await store.refreshDeploymentStatus(for: release) {
        onlineInspectionMessage = "巡检完成：\(snapshot.provider.localizedDisplayName) \(snapshot.level.localizedDisplayName)。"
      } else {
        onlineInspectionMessage = store.deploymentStatusMessage ?? "线上巡检未获得结果。"
      }
    }
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
  }
}
