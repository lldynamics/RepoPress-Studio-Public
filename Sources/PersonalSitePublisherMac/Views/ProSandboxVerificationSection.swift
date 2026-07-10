import PublishingWorkbenchCore
import SwiftUI

struct ProSandboxVerificationSection: View {
  let sandboxSummary: ProSandboxVerificationSummary
  let onCopySummary: () -> Void
  let onCopyEvidence: () -> Void
  let onCopyRecordCommand: () -> Void

  var body: some View {
    Section("StoreKit 沙盒核验") {
      ProSandboxVerificationPlainContent(
        sandboxSummary: sandboxSummary,
        showsHeading: false,
        onCopySummary: onCopySummary,
        onCopyEvidence: onCopyEvidence,
        onCopyRecordCommand: onCopyRecordCommand
      )
    }
  }
}

struct ProSandboxVerificationPlainContent: View {
  let sandboxSummary: ProSandboxVerificationSummary
  var showsHeading = true
  let onCopySummary: () -> Void
  let onCopyEvidence: () -> Void
  let onCopyRecordCommand: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsHeading {
        Label("StoreKit 沙盒核验", systemImage: "testtube.2")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      Label(sandboxSummary.title, systemImage: sandboxSummary.level.systemImage)
        .font(.callout.weight(.semibold))
        .foregroundStyle(foreground(sandboxSummary.level))

      Text(sandboxSummary.message)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Label("\(sandboxSummary.verifiedItems.count) 项已有证据", systemImage: "checkmark.circle")
          .foregroundStyle(.green)
        Label("\(sandboxSummary.remainingItems.count) 项待核验", systemImage: sandboxSummary.remainingItems.isEmpty ? "checkmark.seal" : "testtube.2")
          .foregroundStyle(sandboxSummary.remainingItems.isEmpty ? Color.green : Color.orange)
      }
      .font(.caption)

      ProBoundaryEvidenceRow(summary: sandboxSummary.boundaryEvidence)

      ForEach(sandboxSummary.remainingItems.prefix(3), id: \.self) { item in
        Label(item, systemImage: "checklist")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        Button {
          onCopySummary()
        } label: {
          Label("复制沙盒核验摘要", systemImage: "doc.on.doc")
        }

        Button {
          onCopyEvidence()
        } label: {
          Label("复制外部验证字段", systemImage: "checklist.checked")
        }

        Button {
          onCopyRecordCommand()
        } label: {
          Label("复制记录命令", systemImage: "terminal")
        }
      }
    }
  }

  private func foreground(_ level: ProSandboxVerificationLevel) -> Color {
    switch level {
    case .verified:
      return .green
    case .readyToVerify:
      return .orange
    case .needsAttention:
      return .red
    }
  }
}
