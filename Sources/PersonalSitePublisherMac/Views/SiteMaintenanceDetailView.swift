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
          .padding(20)
      }
    }
  }

  @ViewBuilder
  private var bodyContent: some View {
    if let snapshot = store.siteMaintenanceSnapshot {
      SiteMaintenanceDetailContent(
        snapshot: snapshot,
        isStale: store.isSiteMaintenanceSnapshotStale,
        isAIChatRunning: store.ai.isChatRunning,
        refresh: {
          Task {
            await store.refreshSiteMaintenanceSnapshot(force: true)
          }
        },
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
    } else {
      SiteMaintenanceSnapshotPlaceholder {
        Task {
          await store.refreshSiteMaintenanceSnapshot(force: true)
        }
      }
    }
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
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}
