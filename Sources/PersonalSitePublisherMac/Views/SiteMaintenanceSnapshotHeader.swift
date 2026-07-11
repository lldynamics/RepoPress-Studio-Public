import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceSnapshotHeader: View {
  let snapshot: SiteMaintenanceSnapshot
  let report: SiteMaintenanceReport
  let isStale: Bool
  let refresh: () -> Void
  let copySprintPlan: () -> Void
  let copyChecklist: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("站点维护")
          .font(.title2.weight(.semibold))
        Text("\(snapshot.profileName) · \(snapshot.draftCount) 篇文章 · 快照 \(snapshot.generatedAt.workbenchShortText) · v\(snapshot.sourceVersion)")
          .foregroundStyle(.secondary)
      }

      Spacer()

      if isStale {
        Label("报告可能已过期", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      Button {
        refresh()
      } label: {
        Label("刷新报告", systemImage: "arrow.clockwise")
      }

      Button {
        copySprintPlan()
      } label: {
        Label("复制冲刺计划", systemImage: "checklist")
      }

      Button {
        copyChecklist()
      } label: {
        Label("复制维护清单", systemImage: "doc.on.doc")
      }

      Text(report.generatedAt.workbenchShortText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
