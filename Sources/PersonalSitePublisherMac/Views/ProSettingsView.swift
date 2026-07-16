import PublishingWorkbenchCore
import SwiftUI

struct ProSettingsState {
  let upgrade: ProUpgradePresentation
  let summary: ProStatusSummary
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
}

struct ProSettingsActions {
  let purchase: () async -> Void
  let restore: () async -> Void
  let copyStatusSummary: () -> Void
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
    }
    .formStyle(.grouped)
    .padding()
  }
}
