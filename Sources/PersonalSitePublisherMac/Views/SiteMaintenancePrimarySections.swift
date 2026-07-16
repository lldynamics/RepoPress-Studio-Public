import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceMetricGrid: View {
  let report: SiteMaintenanceReport

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 138, maximum: 220))],
      spacing: 12
    ) {
      MetricTile(title: "文章", value: "\(report.draftCount)", semantic: .neutral)
      MetricTile(title: "待发布", value: "\(report.readyCount)", semantic: .progress)
      MetricTile(
        title: "行动项",
        value: "\(report.actionItems.count)",
        semantic: report.actionItems.isEmpty ? .passed : .warning
      )
      MetricTile(
        title: "旧文候选",
        value: "\(report.staleArticles.count)",
        semantic: report.staleArticles.isEmpty ? .passed : .warning
      )
      MetricTile(title: "内链机会", value: "\(report.internalLinkOpportunityCount)", semantic: .progress)
      MetricTile(
        title: "链接提示",
        value: "\(report.linkAuditItems.count)",
        semantic: report.linkAuditItems.isEmpty ? .passed : .warning
      )
    }
  }
}

struct SiteMaintenanceHealthSection: View {
  let summary: SiteMaintenanceHealthSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(summary.title, systemImage: summary.level.systemImage)
          .font(.headline)
          .foregroundStyle(siteMaintenanceHealthForeground(summary.level))
        Spacer()
        Text("\(summary.score)/100")
          .font(.title3.weight(.semibold))
          .foregroundStyle(siteMaintenanceHealthForeground(summary.level))
        Text(summary.level.localizedDisplayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(siteMaintenanceHealthForeground(summary.level))
      }

      Text(summary.message)
        .font(.callout)
        .foregroundStyle(.secondary)

      Label(summary.nextAction, systemImage: "arrow.forward.circle")
        .font(.caption.weight(.medium))
        .foregroundStyle(siteMaintenanceHealthForeground(summary.level))

      if !summary.drivers.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(summary.drivers, id: \.self) { driver in
            Label(driver, systemImage: "smallcircle.filled.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct SiteMaintenanceActionQueueSection: View {
  let report: SiteMaintenanceReport
  let isAIChatRunning: Bool
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("维护行动队列", systemImage: "checklist")
          .font(.headline)
        Spacer()
        Text("\(report.actionItems.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.actionItems.isEmpty {
        Label("当前没有需要优先处理的维护事项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(report.actionItems.prefix(8)) { item in
          actionQueueRow(item)
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  @ViewBuilder
  private func actionQueueRow(_ item: MaintenanceActionItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      actionQueueRowContent(item)

      HStack {
        if let draftID = item.draftID {
          Button {
            openDraft(draftID)
          } label: {
            Label("打开草稿", systemImage: "arrow.right.circle")
          }
        }

        Button {
          copyItem(item)
        } label: {
          Label("复制任务", systemImage: "doc.on.doc")
        }

        Button {
          recordItem(item)
        } label: {
          Label("记录处理", systemImage: "checkmark.circle")
        }

        Button {
          sendToAI(item)
        } label: {
          Label("交给 AI", systemImage: "sparkles")
        }
        .disabled(item.draftID == nil || isAIChatRunning)
        .accessibilityLabel("把维护动作交给 AI")
        .accessibilityValue(item.title)
      }
      .controlSize(.small)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func actionQueueRowContent(_ item: MaintenanceActionItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: item.systemImage)
        .foregroundStyle(siteMaintenanceActionPriorityForeground(item.priority))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Text(item.kind.localizedDisplayName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkbenchBackgroundStyle.badge, in: Capsule())
          Spacer()
          Text(item.priority.localizedDisplayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(siteMaintenanceActionPriorityForeground(item.priority))
        }

        Text(item.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        if !item.detail.isEmpty {
          Text(item.detail)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private func siteMaintenanceHealthForeground(_ level: SiteMaintenanceHealthLevel) -> AnyShapeStyle {
  switch level {
  case .stable:
    return AnyShapeStyle(WorkbenchTheme.success)
  case .watch:
    return AnyShapeStyle(WorkbenchTheme.primary)
  case .needsWork:
    return AnyShapeStyle(WorkbenchTheme.warning)
  case .urgent:
    return AnyShapeStyle(WorkbenchTheme.risk)
  }
}

private func siteMaintenanceActionPriorityForeground(_ priority: MaintenanceActionPriority) -> AnyShapeStyle {
  switch priority {
  case .high:
    return AnyShapeStyle(WorkbenchTheme.risk)
  case .medium:
    return AnyShapeStyle(WorkbenchTheme.warning)
  case .low:
    return AnyShapeStyle(.secondary)
  }
}
