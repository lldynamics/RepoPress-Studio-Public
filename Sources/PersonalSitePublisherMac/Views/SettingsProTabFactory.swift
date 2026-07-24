import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsProTabFactory {
  static func make(context: SettingsContext) -> some View {
    let currentFreeUsage = context.store.currentFreePlanUsage
    return ProSettingsView(
      state: ProSettingsState(
        upgrade: context.store.proUpgradePresentation,
        summary: context.store.proStatusSummary,
        latestBlockNotice: context.store.latestProFeatureBlockNotice,
        isUnlocked: context.store.monetizationState.entitlement.isUnlocked,
        productDisplayPrice: context.storeKitProEntitlementCoordinator.productDisplayPrice,
        purchaseTypeDisplayName: context.storeKitProEntitlementCoordinator.purchaseTypeDisplayName,
        aiUsed: currentFreeUsage.aiRequestCount,
        aiRemaining: context.store.remainingFreeUses(for: .aiRequest),
        publishingUsed: currentFreeUsage.onlinePublishAttemptCount,
        publishingRemaining: context.store.remainingFreeUses(for: .onlinePublishing),
        batchUsed: currentFreeUsage.batchPublishCount,
        batchRemaining: context.store.remainingFreeUses(for: .batchPublishing),
        isPurchaseRestoreBusy: context.storeKitProEntitlementCoordinator.isBusy,
        monetizationMessage: context.store.monetizationMessage
      ),
      actions: ProSettingsActions(
        purchase: {
          await context.actions.purchasePro()
        },
        restore: {
          await context.actions.restorePro()
        },
        copyStatusSummary: {
          context.actions.copyProStatusSummary()
        }
      )
    )
  }
}
