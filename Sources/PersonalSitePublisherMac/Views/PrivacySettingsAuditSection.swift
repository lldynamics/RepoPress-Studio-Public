import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsAuditPlainContent: View {
  let audit: PrivacyProtectionAudit
  var showsHeading = true
  let onCopyAuditReport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsHeading {
        Label("隐私体检", systemImage: "checklist.checked")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      Label(audit.title, systemImage: audit.level.systemImage)
        .font(.callout.weight(.semibold))
        .foregroundStyle(auditLevelColor(audit.level))

      Text(audit.message)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 14) {
        PrivacyAuditMetricView(title: "私密文章", value: audit.privateDraftCount)
        PrivacyAuditMetricView(title: "已遮挡", value: audit.maskedPrivateDraftCount)
        PrivacyAuditMetricView(title: "可见风险", value: audit.visiblePrivateDraftCount)
      }

      if audit.recommendations.isEmpty {
        Label("当前没有必须处理的隐私保护建议", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(audit.recommendations, id: \.self) { recommendation in
          Label(recommendation, systemImage: "checklist")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Button {
        onCopyAuditReport()
      } label: {
        Label("复制体检报告", systemImage: "doc.on.doc")
      }
    }
  }

  private func auditLevelColor(_ level: PrivacyProtectionRiskLevel) -> Color {
    switch level {
    case .protected:
      return .green
    case .watch:
      return .orange
    case .exposed:
      return .red
    }
  }
}
