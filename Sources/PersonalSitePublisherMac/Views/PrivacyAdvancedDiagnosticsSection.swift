#if DEBUG
import PublishingWorkbenchCore
import SwiftUI

struct PrivacyAdvancedDiagnosticsSection: View {
  let audit: PrivacyProtectionAudit
  let events: [PrivacyProtectionEvent]
  let onCopyChecklist: () -> Void
  let onCopyAuditReport: () -> Void
  let onCopyEvidence: () -> Void

  var body: some View {
    Section("高级隐私诊断") {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            Button {
              onCopyChecklist()
            } label: {
              Label("复制隐私清单", systemImage: "doc.on.doc")
            }

            Button {
              onCopyEvidence()
            } label: {
              Label("复制证据包", systemImage: "shippingbox")
            }
          }

          PrivacySettingsAuditPlainContent(
            audit: audit,
            onCopyAuditReport: onCopyAuditReport
          )

          PrivacySettingsRecentEventsPlainContent(events: events)
        }
        .padding(.top, 8)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Label("体检、证据与事件记录", systemImage: "checklist.checked")
            .font(.callout.weight(.semibold))
          Text("用于上架材料、隐私审计和调试；日常只需要上方快速隐藏和内容遮挡。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
#endif
