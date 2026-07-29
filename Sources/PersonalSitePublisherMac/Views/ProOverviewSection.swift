import PublishingWorkbenchCore
import SwiftUI

struct ProOverviewSection: View {
  let summary: ProStatusSummary
  let latestBlockNotice: ProFeatureBlockNotice?
  let onCopyStatusSummary: () -> Void

  var body: some View {
    Section("Pro 概览") {
      HStack {
        Label(summary.title, systemImage: summary.entitlement.isUnlocked ? "crown.fill" : summary.systemImage)
          .font(.headline)
          .foregroundStyle(summaryForeground(summary))

        Spacer()

        if summary.entitlement.isUnlocked {
          HStack(spacing: 4) {
            Image(systemName: "sparkles")
              .font(.workbenchMetadata)
            Text("PRO UNLOCKED")
              .font(.workbenchMetadata.weight(.bold).monospaced())
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.orange.opacity(0.18), in: Capsule())
          .foregroundStyle(Color.orange)
        }
      }

      Text(summary.message)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)

      Text(summary.nextStep)
        .font(.workbenchSupporting)
        .foregroundStyle(summary.isActionRequired ? WorkbenchTheme.warning : Color.secondary)

      if let notice = latestBlockNotice {
        ProBlockNoticeRow(notice: notice)
      }

      HStack {
        Label("\(summary.availableRequirements.count) 项可用", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        Label("\(summary.blockedRequirements.count) 项受限", systemImage: "lock.fill")
          .foregroundStyle(summary.blockedRequirements.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(WorkbenchTheme.warning))
      }
      .font(.workbenchMetadata)

      Button {
        onCopyStatusSummary()
      } label: {
        Label("复制 Pro 状态摘要", systemImage: "doc.on.doc")
      }
    }
  }

  private func summaryForeground(_ summary: ProStatusSummary) -> AnyShapeStyle {
    if summary.entitlement.isUnlocked {
      return AnyShapeStyle(WorkbenchTheme.financeForeground)
    }
    if summary.isActionRequired {
      return AnyShapeStyle(WorkbenchTheme.warning)
    }
    return AnyShapeStyle(.secondary)
  }
}
