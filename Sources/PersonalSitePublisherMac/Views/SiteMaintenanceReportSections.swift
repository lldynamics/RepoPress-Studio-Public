import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceReportSections: View {
  let report: SiteMaintenanceReport
  let isAIChatRunning: Bool
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void
  let applySuggestedSchedule: () -> Void

  var body: some View {
    SiteMaintenancePlanningSections(
      report: report,
      isAIChatRunning: isAIChatRunning,
      openDraft: openDraft,
      copyItem: copyItem,
      recordItem: recordItem,
      sendToAI: sendToAI,
      applySuggestedSchedule: applySuggestedSchedule
    )
    SiteMaintenanceGovernanceReportSections(
      report: report,
      openDraft: openDraft
    )
  }
}
