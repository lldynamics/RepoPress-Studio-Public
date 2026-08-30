import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceDetailView: View {
  let store: WorkbenchStore
  @ObservedObject private var maintenanceState: WorkbenchSiteMaintenanceFeatureFacade
  var isEmbedded: Bool = false
  @State private var onlineInspectionMessage: String?

  init(store: WorkbenchStore, isEmbedded: Bool = false) {
    self.store = store
    _maintenanceState = ObservedObject(wrappedValue: store.siteMaintenance)
    self.isEmbedded = isEmbedded
  }

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
    if let snapshot = maintenanceState.snapshot {
      let scheduleChanges = SiteMaintenanceScheduleChange.proposedChanges(
        report: snapshot.report,
        drafts: store.drafts
      )
      VStack(alignment: .leading, spacing: 12) {
        if let errorMessage = maintenanceState.errorMessage {
          maintenanceRefreshFailure(errorMessage)
        }
        SiteMaintenanceDetailContent(
          snapshot: snapshot,
          isStale: maintenanceState.isStale,
          isRefreshing: maintenanceState.isRefreshing,
          isAIChatRunning: maintenanceState.isAIChatRunning,
          refresh: refreshMaintenanceSnapshot,
          copySprintPlan: copySprintPlan,
          copyChecklist: copyChecklist,
          openDraft: openDraft,
          copyItem: copyItem,
          recordItem: recordItem,
          sendToAI: sendToAI,
          scheduleChanges: scheduleChanges,
          applySuggestedSchedule: { approvedSuggestedDates, expectedOriginalDates in
            Task {
              await store.applySuggestedMaintenanceSchedule(
                approvedSuggestedDates: approvedSuggestedDates,
                expectedOriginalDates: expectedOriginalDates
              )
            }
          },
          latestRelease: maintenanceState.latestRelease,
          deploymentSnapshot: maintenanceState.latestRelease.flatMap(
            maintenanceState.deploymentStatusSnapshot),
          canCheckDeployment: maintenanceState.latestRelease.map(
            maintenanceState.canCheckDeploymentStatus) ?? false,
          isDeploymentChecking: maintenanceState.isDeploymentStatusChecking,
          onlineInspectionMessage: onlineInspectionMessage,
          runOnlineInspection: runOnlineInspection
        )
      }
    } else {
      SiteMaintenanceSnapshotPlaceholder(
        isRefreshing: maintenanceState.isRefreshing,
        errorMessage: maintenanceState.errorMessage,
        generate: refreshMaintenanceSnapshot
      )
    }
  }

  private func refreshMaintenanceSnapshot() {
    guard !maintenanceState.isRefreshing else { return }
    Task {
      await store.refreshSiteMaintenanceSnapshot(force: true)
    }
  }

  private func maintenanceRefreshFailure(_ message: String) -> some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(kind: .failure(reason: message)),
      density: .inline,
      actions: WorkbenchStateActions(
        primary: WorkbenchStateAction(
          title: "重试",
          systemImage: "arrow.clockwise",
          isEnabled: !maintenanceState.isRefreshing,
          action: refreshMaintenanceSnapshot
        )
      )
    )
    .padding(10)
    .background(
      WorkbenchTheme.risk.opacity(WorkbenchOpacity.warningBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
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
    guard let release = maintenanceState.latestRelease else {
      onlineInspectionMessage = "尚无发布记录。"
      return
    }
    guard maintenanceState.canCheckDeploymentStatus(for: release) else {
      onlineInspectionMessage = maintenanceState.deploymentStatusReadiness(for: release).nextStep
      return
    }

    Task {
      await store.refreshSiteMaintenanceSnapshot(force: true)
      if let snapshot = await store.refreshDeploymentStatus(for: release) {
        onlineInspectionMessage =
          "巡检完成：\(snapshot.provider.localizedDisplayName) \(snapshot.level.localizedDisplayName)。"
      } else {
        onlineInspectionMessage = maintenanceState.deploymentStatusMessage ?? "线上巡检未获得结果。"
      }
    }
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
  }
}
