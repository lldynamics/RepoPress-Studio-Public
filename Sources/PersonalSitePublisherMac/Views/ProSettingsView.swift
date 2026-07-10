import PublishingWorkbenchCore
import SwiftUI

struct ProSettingsState {
  let upgrade: ProUpgradePresentation
  let summary: ProStatusSummary
  let sandboxSummary: ProSandboxVerificationSummary
  let latestBlockNotice: ProFeatureBlockNotice?
  let isUnlocked: Bool
  let productID: String?
  let aiUsed: Int
  let aiRemaining: Int
  let publishingUsed: Int
  let publishingRemaining: Int
  let batchUsed: Int
  let batchRemaining: Int
  let isPurchaseRestoreBusy: Bool
  let monetizationMessage: String?
  let recentAccessEvents: [MonetizationAccessEvent]
  let requirements: [ProUpgradeRequirement]
}

struct ProSettingsActions {
  let purchase: () async -> Void
  let restore: () async -> Void
  let copyStatusSummary: () -> Void
  let copyAuditChecklist: () -> Void
  let copyEvidencePackage: () -> Void
  let copySandboxSummary: () -> Void
  let copySandboxEvidence: () -> Void
  let copySandboxRecordCommand: () -> Void
}

struct ProSettingsView: View {
  let state: ProSettingsState
  let actions: ProSettingsActions

  var body: some View {
    Form {
      ProOverviewSection(
        summary: state.summary,
        latestBlockNotice: state.latestBlockNotice,
        onCopyStatusSummary: {
          actions.copyStatusSummary()
        }
      )

      ProSubscriptionSection(
        isUnlocked: state.isUnlocked,
        productID: state.productID,
        upgradeMessage: state.upgrade.message
      )

      ProBenefitsSection()

      ProQuotaSection(
        aiUsed: state.aiUsed,
        aiRemaining: state.aiRemaining,
        publishingUsed: state.publishingUsed,
        publishingRemaining: state.publishingRemaining,
        batchUsed: state.batchUsed,
        batchRemaining: state.batchRemaining
      )

      ProPurchaseRestoreSection(
        isBusy: state.isPurchaseRestoreBusy,
        isUnlocked: state.isUnlocked,
        onPurchase: {
          await actions.purchase()
        },
        onRestore: {
          await actions.restore()
        },
        message: state.monetizationMessage
      )

      ProDeveloperDiagnosticsSection(
        sandboxSummary: state.sandboxSummary,
        recentAccessEvents: state.recentAccessEvents,
        requirements: state.requirements,
        onCopyAuditChecklist: {
          actions.copyAuditChecklist()
        },
        onCopyEvidencePackage: {
          actions.copyEvidencePackage()
        },
        onCopySandboxSummary: {
          actions.copySandboxSummary()
        },
        onCopySandboxEvidence: {
          actions.copySandboxEvidence()
        },
        onCopySandboxRecordCommand: {
          actions.copySandboxRecordCommand()
        }
      )
    }
    .formStyle(.grouped)
    .padding()
  }
}
