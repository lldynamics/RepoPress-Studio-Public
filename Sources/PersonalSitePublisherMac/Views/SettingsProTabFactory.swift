import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsProTabFactory {
  static func make(context: SettingsContext) -> some View {
    ProSettingsView(
      state: ProSettingsState(
        upgrade: context.store.proUpgradePresentation,
        summary: context.store.proStatusSummary,
        latestBlockNotice: context.store.latestProFeatureBlockNotice,
        isUnlocked: context.store.monetizationState.entitlement.isUnlocked,
        productDisplayPrice: context.storeKitProEntitlementCoordinator.productDisplayPrice,
        purchaseTypeDisplayName: context.storeKitProEntitlementCoordinator.purchaseTypeDisplayName,
        aiUsed: context.store.monetizationState.freeUsage.aiRequestCount,
        aiRemaining: context.store.remainingFreeUses(for: .aiRequest),
        publishingUsed: context.store.monetizationState.freeUsage.onlinePublishAttemptCount,
        publishingRemaining: context.store.remainingFreeUses(for: .onlinePublishing),
        batchUsed: context.store.monetizationState.freeUsage.batchPublishCount,
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
