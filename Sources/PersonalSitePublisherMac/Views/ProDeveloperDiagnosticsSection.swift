#if DEBUG
import PublishingWorkbenchCore
import SwiftUI

struct ProDeveloperDiagnosticsSection: View {
  let sandboxSummary: ProSandboxVerificationSummary
  let recentAccessEvents: [MonetizationAccessEvent]
  let requirements: [ProUpgradeRequirement]
  let onCopyAuditChecklist: () -> Void
  let onCopyEvidencePackage: () -> Void
  let onCopySandboxSummary: () -> Void
  let onCopySandboxEvidence: () -> Void
  let onCopySandboxRecordCommand: () -> Void

  var body: some View {
    Section("开发者诊断") {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            Button {
              onCopyAuditChecklist()
            } label: {
              Label("复制审核清单", systemImage: "doc.on.doc")
            }

            Button {
              onCopyEvidencePackage()
            } label: {
              Label("复制上架证据包", systemImage: "shippingbox")
            }
          }

          ProSandboxVerificationPlainContent(
            sandboxSummary: sandboxSummary,
            onCopySummary: onCopySandboxSummary,
            onCopyEvidence: onCopySandboxEvidence,
            onCopyRecordCommand: onCopySandboxRecordCommand
          )

          ProRequirementsPlainContent(requirements: requirements)

          ProRecentAccessPlainContent(events: recentAccessEvents)
        }
        .padding(.top, 8)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Label("StoreKit / Pro 验证", systemImage: "testtube.2")
            .font(.callout.weight(.semibold))
          Text("沙盒核验、上架证据、边界验证和最近访问记录，仅用于调试与审核准备。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
#endif
