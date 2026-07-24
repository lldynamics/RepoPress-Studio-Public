import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceSnapshotHeader: View {
  let snapshot: SiteMaintenanceSnapshot
  let report: SiteMaintenanceReport
  let isStale: Bool
  let isRefreshing: Bool
  let refresh: () -> Void
  let copySprintPlan: () -> Void
  let copyChecklist: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        titleBlock
        Spacer(minLength: 16)
        statusMetadata
        headerActions
      }

      VStack(alignment: .leading, spacing: 10) {
        titleBlock
        HStack(spacing: 12) {
          statusMetadata
          Spacer(minLength: 8)
          headerActions
        }
      }
    }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("站点维护")
        .font(.title2.weight(.semibold))
      Text("\(snapshot.profileName) · \(snapshot.draftCount) 篇文章 · 快照 \(snapshot.generatedAt.workbenchShortText) · v\(snapshot.sourceVersion)")
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private var statusMetadata: some View {
    HStack(spacing: 10) {
      if isStale {
        Label("报告可能已过期", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      Text(report.generatedAt.workbenchShortText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var headerActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        refreshButton
        copySprintPlanButton
        copyChecklistButton
      }
      VStack(alignment: .leading, spacing: 8) {
        refreshButton
        copySprintPlanButton
        copyChecklistButton
      }
    }
  }

  private var refreshButton: some View {
      Button {
        refresh()
      } label: {
        if isRefreshing {
          Label("正在刷新", systemImage: "arrow.clockwise")
        } else {
          Label("刷新报告", systemImage: "arrow.clockwise")
        }
      }
      .disabled(isRefreshing)
      .accessibilityIdentifier("site-maintenance-refresh")
  }

  private var copySprintPlanButton: some View {
    Button {
      copySprintPlan()
    } label: {
      Label("复制冲刺计划", systemImage: "checklist")
    }
    .accessibilityIdentifier("site-maintenance-copy-sprint-plan")
  }

  private var copyChecklistButton: some View {
    Button {
      copyChecklist()
    } label: {
      Label("复制维护清单", systemImage: "doc.on.doc")
    }
    .accessibilityIdentifier("site-maintenance-copy-checklist")
  }
}
