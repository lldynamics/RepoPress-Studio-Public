import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceActionQueueSection: View {
  let report: SiteMaintenanceReport
  let isAIChatRunning: Bool
  let openDraft: (UUID) -> Void
  let copyItem: (MaintenanceActionItem) -> Void
  let recordItem: (MaintenanceActionItem) -> Void
  let sendToAI: (MaintenanceActionItem) -> Void
  var maximumVisibleCount = 8
  var allowsExpansion = true
  @State private var showsAllActions = false

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
      HStack {
        Label("维护行动队列", systemImage: "checklist")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text("\(report.actionItems.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      if report.actionItems.isEmpty {
        Label("当前没有需要优先处理的维护事项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        let visibleActions =
          showsAllActions
          ? report.actionItems
          : Array(report.actionItems.prefix(maximumVisibleCount))
        ForEach(Array(visibleActions.enumerated()), id: \.element.id) { index, item in
          actionQueueRow(item)
          if index < visibleActions.count - 1 {
            Divider()
          }
        }
        if allowsExpansion, report.actionItems.count > maximumVisibleCount {
          Divider()
          WorkbenchListDisclosureFooter(
            visibleCount: visibleActions.count,
            totalCount: report.actionItems.count,
            showsAll: $showsAllActions
          )
        }
      }
    }
  }

  @ViewBuilder
  private func actionQueueRow(_ item: MaintenanceActionItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      actionQueueRowContent(item)

      HStack(spacing: 8) {
        if let draftID = item.draftID {
          Button {
            openDraft(draftID)
          } label: {
            Label("打开草稿", systemImage: "arrow.right.circle")
          }
        }

        Button {
          recordItem(item)
        } label: {
          Label("记录处理", systemImage: "checkmark.circle")
        }

        Button {
          copyItem(item)
        } label: {
          Label("复制任务", systemImage: "doc.on.doc")
        }

        Button {
          sendToAI(item)
        } label: {
          Label("AI 修复", systemImage: "sparkles")
        }
        .disabled(item.draftID == nil || isAIChatRunning)

        Spacer(minLength: 0)
      }
      .controlSize(.small)
    }
    .padding(.vertical, WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
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
            .workbenchTruncatedIdentity(item.title)
          Text(item.kind.localizedDisplayName)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(
            String.localizedStringWithFormat(
              String(localized: "优先级：%@"),
              item.priority.localizedDisplayName
            )
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(siteMaintenanceActionPriorityForeground(item.priority))
        }

        Text(item.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        if !item.detail.isEmpty {
          Text(item.detail)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(item.detail)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
