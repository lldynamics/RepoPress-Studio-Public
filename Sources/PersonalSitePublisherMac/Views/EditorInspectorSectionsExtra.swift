import PublishingWorkbenchCore
import SwiftUI

struct EditorPreflightSection: View {
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let publicRiskSummary = store.publicRiskSummary(for: draft)

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("发布检查")
          .font(.headline)
        Spacer()
        Button {
          store.focusDraft(draft.id, section: .contentHealth)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("重新运行发布检查")
        .accessibilityLabel("重新运行发布检查")
      }

      publicRiskSummaryBlock(publicRiskSummary)

      ForEach(store.preflightIssues(for: draft).prefix(6)) { issue in
        VStack(alignment: .leading, spacing: 4) {
          SeverityBadge(severity: issue.severity)
          Text(issue.title)
            .font(.callout.weight(.medium))
          Text(issue.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
        Divider()
      }
    }
  }

  private func publicRiskSummaryBlock(_ summary: PublicRiskSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: summary.isClear ? "lock.open" : "lock.shield")
          .foregroundStyle(summary.isClear ? Color.secondary : (summary.errorCount > 0 ? Color.red : Color.orange))
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          Text(summary.statusTitle)
            .font(.callout.weight(.medium))
          Text(summary.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }

      if !summary.isClear {
        HStack(spacing: 10) {
          Label("\(summary.errorCount) 错误", systemImage: "xmark.octagon")
            .foregroundStyle(summary.errorCount > 0 ? .red : .secondary)
          Label("\(summary.warningCount) 警告", systemImage: "exclamationmark.triangle")
            .foregroundStyle(summary.warningCount > 0 ? .orange : .secondary)
        }
        .font(.caption2)

        ForEach(summary.issues.prefix(3)) { issue in
          Text("\(issue.severity.displayName) · \(issue.title)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }
}
