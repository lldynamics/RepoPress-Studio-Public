import PublishingWorkbenchCore
import SwiftUI

struct ProBoundaryEvidenceRow: View {
  let summary: ProBoundaryEvidenceSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(summary.title, systemImage: summary.hasUpgradePromptEvidence && summary.hasProNoQuotaEvidence ? "checkmark.seal" : "testtube.2")
        .font(.caption.weight(.semibold))
        .foregroundStyle(summary.hasUpgradePromptEvidence && summary.hasProNoQuotaEvidence ? .green : .orange)

      Text(summary.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      if let blocked = summary.latestBlockedUse {
        Label("阻断：\(blocked.feature.localizedDisplayName) · \(blocked.quotaSummary)", systemImage: blocked.outcome.systemImage)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if let pro = summary.latestProUse {
        Label("Pro：\(pro.feature.localizedDisplayName) · \(pro.quotaSummary)", systemImage: pro.outcome.systemImage)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
