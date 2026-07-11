import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceDetailView: View {
  @ObservedObject var store: WorkbenchStore
  var isEmbedded: Bool = false
  @State private var performancePageViews = ""
  @State private var performanceVisitors = ""
  @State private var performanceSourceName = "手动记录"
  @State private var contentPerformanceImportNotice: ContentPerformanceImportNotice?
  @State private var isImportingContentPerformance = false
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
        selectedDraft: store.selectedDraft,
        performancePageViews: $performancePageViews,
        performanceVisitors: $performanceVisitors,
        performanceSourceName: $performanceSourceName,
        refresh: {
          store.refreshSiteMaintenanceSnapshot()
        },
        copySprintPlan: copySprintPlan,
        copyChecklist: copyChecklist,
        openDraft: openDraft,
        copyItem: copyItem,
        recordItem: recordItem,
        sendToAI: sendToAI,
        applySuggestedSchedule: {
          store.applySuggestedMaintenanceSchedule()
        },
        recordPerformanceSnapshot: recordPerformanceSnapshot,
        importCSV: importContentPerformanceCSV,
        importNotice: contentPerformanceImportNotice,
        latestRelease: store.activeProfileReleaseRecords.first,
        deploymentSnapshot: store.activeProfileReleaseRecords.first.flatMap(store.deploymentStatusSnapshot),
        canCheckDeployment: store.activeProfileReleaseRecords.first.map(store.canCheckDeploymentStatus) ?? false,
        isDeploymentChecking: store.isDeploymentStatusChecking,
        onlineInspectionMessage: onlineInspectionMessage,
        runOnlineInspection: runOnlineInspection
      )
    } else {
      SiteMaintenanceSnapshotPlaceholder {
        store.refreshSiteMaintenanceSnapshot()
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

  private func recordPerformanceSnapshot(for draft: ArticleDraft) {
    guard let pageViews = Int(performancePageViews.trimmedForPublishing),
          let visitors = Int(performanceVisitors.trimmedForPublishing)
    else {
      return
    }

    store.recordContentPerformanceSnapshot(
      for: draft,
      pageViews: pageViews,
      visitors: visitors,
      sourceName: performanceSourceName
    )
    performancePageViews = ""
    performanceVisitors = ""
  }

  private func importContentPerformanceCSV() {
    guard let url = ContentPerformanceCSVSelectionPanel.chooseCSV() else { return }
    guard !isImportingContentPerformance else { return }
    isImportingContentPerformance = true
    contentPerformanceImportNotice = .importing
    Task {
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
        isImportingContentPerformance = false
      }
      do {
        let report = try await store.importContentPerformanceCSV(from: url, sourceName: "CSV 导入")
        contentPerformanceImportNotice = .imported(
          sourceName: report.sourceName,
          imported: report.importedSnapshots.count,
          skipped: report.skippedRowCount,
          unmatched: report.unmatchedRows.count
        )
        store.refreshSiteMaintenanceSnapshot()
      } catch {
        contentPerformanceImportNotice = contentPerformanceImportErrorNotice(error)
      }
    }
  }

  private func contentPerformanceImportErrorNotice(_ error: Error) -> ContentPerformanceImportNotice {
    guard let importError = error as? ContentPerformanceCSVImportError else {
      return .failure(error.localizedDescription)
    }
    switch importError {
    case .unsupportedEncoding:
      return .unsupportedEncoding
    case .missingHeader:
      return .missingHeader
    case .missingMetrics:
      return .missingMetrics
    case .profileChanged:
      return .profileChanged
    case .fileTooLarge:
      return .fileTooLarge
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
      store.refreshSiteMaintenanceSnapshot()
      if let snapshot = await store.refreshDeploymentStatus(for: release) {
        onlineInspectionMessage = "巡检完成：\(snapshot.provider.displayName) \(snapshot.level.displayName)。"
      } else {
        onlineInspectionMessage = store.deploymentStatusMessage ?? "线上巡检未获得结果。"
      }
    }
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}
