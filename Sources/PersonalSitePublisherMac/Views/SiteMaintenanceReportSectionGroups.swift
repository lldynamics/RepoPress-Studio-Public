import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenancePlanningSections: View {
  let report: SiteMaintenanceReport
  let isAIChatRunning: Bool
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void
  let applySuggestedSchedule: () -> Void

  var body: some View {
    SiteMaintenanceMetricGrid(report: report)
    SiteMaintenanceHealthSection(summary: report.healthSummary)
    SiteMaintenanceActionQueueSection(
      report: report,
      isAIChatRunning: isAIChatRunning,
      openDraft: openDraft,
      copyItem: copyItem,
      recordItem: recordItem,
      sendToAI: sendToAI
    )
    SiteMaintenanceCalendarSection(
      report: report,
      applySuggestedSchedule: applySuggestedSchedule,
      openDraft: openDraft
    )
  }
}

struct SiteMaintenanceGovernanceReportSections: View {
  let report: SiteMaintenanceReport
  let openDraft: (UUID) -> Void

  var body: some View {
    SiteMaintenanceTaxonomySection(title: "标签治理", summary: report.tagSummary, systemImage: "tag")
    SiteMaintenanceTaxonomySection(title: "分类治理", summary: report.categorySummary, systemImage: "folder")
    SiteMaintenanceStaleArticleSection(report: report, openDraft: openDraft)
    SiteMaintenanceRelationSuggestionSection(report: report, openDraft: openDraft)
    SiteMaintenanceLinkAuditSection(report: report, openDraft: openDraft)
    SiteMaintenanceOperationLogSection(report: report)
  }
}
