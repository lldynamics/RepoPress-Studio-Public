import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceDetailView: View {
  @ObservedObject var store: WorkbenchStore
  var isEmbedded: Bool = false
  @State private var performancePageViews = ""
  @State private var performanceVisitors = ""
  @State private var performanceSourceName = "手动记录"

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
        recordPerformanceSnapshot: recordPerformanceSnapshot
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

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}
